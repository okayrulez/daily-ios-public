import Foundation

/// Local, bounded protocol history. Never serialize Error descriptions, userInfo or HTTP bodies.
public struct ConnectionDiagnosticEntry: Codable, Sendable {
    public let timestamp: Date
    public let fields: [String: String]

    public init(stage: String, outcome: String, model: String = "", build: String = "",
                appState: String = "", osVersion: String = "",
                error: Error? = nil, now: Date = Date(), promptBytes: Int? = nil, elapsedMilliseconds: Int? = nil) {
        timestamp = now
        var values = ["stage": ChatGPTServiceFailure.safe(stage) ?? "unknown",
                      "outcome": ChatGPTServiceFailure.safe(outcome) ?? "unknown"]
        values["model"] = ChatGPTServiceFailure.safe(model)
        values["build"] = ChatGPTServiceFailure.safe(build)
        values["app_state"] = ChatGPTServiceFailure.safe(appState)
        values["ios_version"] = ChatGPTServiceFailure.safe(osVersion)
        if let promptBytes, (0...2_000_000).contains(promptBytes) { values["prompt_bytes"] = String(promptBytes) }
        if let elapsedMilliseconds, (0...86_400_000).contains(elapsedMilliseconds) { values["elapsed_ms"] = String(elapsedMilliseconds) }
        if let failure = error as? AnalysisScopeGuardFailure {
            values["code"] = failure.reason.rawValue
            values["guard_phase"] = failure.phase.rawValue
        } else if let failure = error as? WorkspaceRequestError {
            switch failure {
            case .malformed: values["code"] = "workspace_request_malformed"
            case .sourceChanged: values["code"] = "workspace_source_changed"
            case .accountChanged: values["code"] = "workspace_account_changed"
            }
        } else if let failure = error as? ChatGPTServiceFailure {
            values["provider_stage"] = ChatGPTServiceFailure.safe(failure.stage)
            values["http_status"] = failure.status.map(String.init)
            values["code"] = failure.code
            values["error_type"] = failure.errorType
            values["parameter"] = failure.parameter
            values["request_id"] = failure.requestID
            values["body_shape"] = failure.shape
            values["content_type"] = failure.contentType
            values["retry_at"] = failure.retryAt.map { ISO8601DateFormatter().string(from: $0) }
            // Only the stream reader's fixed metadata format is accepted.
            if let progress = failure.streamDiagnostic, progress.count < 384,
               progress.range(of: #"^bytes=[0-9]+ · events=[0-9]+ · last=(none|other|response\.[a-z_.]+|error) · done=(true|false)( · item_done=[0-9]+ · text_delta=[0-9]+ · text_done=[0-9]+ · terminal_items=[0-9]+)?$"#, options: .regularExpression) != nil {
                values["stream"] = progress
            }
        } else if let failure = error as? AnalysisValidationFailure {
            values["analysis_command"] = ChatGPTServiceFailure.safe(failure.command)
            values["code"] = ChatGPTServiceFailure.safe(failure.code)
            for (index, issue) in failure.issues.prefix(8).enumerated() {
                values["validation_\(index + 1)"] = issue
            }
        } else if let failure = error as? AnalysisCoreError {
            switch failure {
            case .unavailable: values["code"] = "analysis_core_unavailable"
            case .invalidInput: values["code"] = "analysis_input_too_large"
            case .invalidOutput: values["code"] = "analysis_bridge_invalid_output"
            }
        } else if let failure = error as? ResponsesStreamError {
            values["code"] = ChatGPTServiceFailure.safe(failure.code)
        } else if let failure = error as? ChatGPTOAuthError {
            switch failure {
            case .invalidCallback: values["code"] = "oauth_invalid_callback"
            case .denied: values["code"] = "oauth_consent_denied"
            case .invalidToken: values["code"] = "oauth_invalid_token"
            case .randomFailure: values["code"] = "oauth_random_failure"
            }
        } else if error is CancellationError {
            values["code"] = "cancelled"
        } else if let error {
            let native = error as NSError
            if native.domain == NSURLErrorDomain {
                switch native.code {
                case URLError.timedOut.rawValue: values["code"] = "network_timeout"
                case URLError.cancelled.rawValue: values["code"] = "network_cancelled"
                case URLError.networkConnectionLost.rawValue: values["code"] = "network_connection_lost"
                case URLError.notConnectedToInternet.rawValue: values["code"] = "network_offline"
                default: break
                }
            }
            values["error_domain"] = ChatGPTServiceFailure.safe(native.domain)
            values["native_code"] = String(native.code)
            // Type only, never String(describing: error) which can include credentials/diary.
            values["error_type"] = ChatGPTServiceFailure.safe(String(reflecting: type(of: error)))
        }
        fields = values
    }

    public var report: String {
        ([ISO8601DateFormatter().string(from: timestamp)] +
            fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }).joined(separator: " | ")
    }
}

public struct ConnectionDiagnosticLog {
    public static let limit = 50
    private let url: URL
    public private(set) var entries: [ConnectionDiagnosticEntry]

    public init(directory: URL, scope: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var privateDirectory = directory
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try privateDirectory.setResourceValues(flags)
        url = directory.appendingPathComponent(WorkspaceHash.sha256(scope) + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 262_144 else {
                throw CocoaError(.fileReadTooLarge)
            }
            entries = Array(try JSONDecoder().decode([ConnectionDiagnosticEntry].self, from: Data(contentsOf: url)).suffix(Self.limit))
        } else { entries = [] }
    }

    public mutating func append(_ entry: ConnectionDiagnosticEntry) throws {
        entries.append(entry)
        entries = Array(entries.suffix(Self.limit))
        try JSONEncoder().encode(entries).write(to: url, options: [.atomic, .completeFileProtection])
    }

    public mutating func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        entries = []
    }

    public var report: String {
        "DailyX bağlantı hata günlüğü v1\n" + entries.map(\.report).joined(separator: "\n\n")
    }
}
