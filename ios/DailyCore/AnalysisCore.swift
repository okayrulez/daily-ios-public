import Foundation
import JavaScriptCore

public enum AnalysisCoreError: Error { case unavailable, invalidInput, invalidOutput }

public struct AnalysisValidationFailure: Error, Sendable {
    public let command: String
    public let code: String
    public let issues: [String]
    public var diagnostic: String {
        (["ANALYSIS_CORE", command, code] + issues).joined(separator: " · ")
    }
}

private struct AnalysisCoreEnvelope: Decodable {
    let ok: Bool
    let value: String?
    let error: Failure?
    struct Failure: Decodable { let code: String; let issues: [String] }
}

/// Each invocation gets an isolated context. The only input/output is JSON.
public enum AnalysisCore {
    /// Repair one returned model response and apply the same validation before returning.
    public static func validateModelResponse(_ raw: String, prepared: String, command: String,
                                             reasoningEffort: String?,
                                             isolation: isolated (any Actor)? = #isolation,
                                             infer: (String) async throws -> String,
                                             onRepair: () async -> Void = {},
                                             validate: (String) throws -> String) async throws -> String {
        try Task.checkCancellation()
        do { return try validate(raw) }
        catch let failure as AnalysisValidationFailure where failure.command == command &&
            ["invalid_json", "schema_validation"].contains(failure.code) {
            guard raw.utf8.count <= 200_000 else { throw failure }
            let args = try JSONValue.object(["prepared": JSONValue.parse(prepared), "output": .string(raw),
                "errorCode": .string(failure.code)]).canonical()
            let repair = try invoke("prepareModelResponseRepair", json: args)
            await onRepair()
            try Task.checkCancellation()
            let corrected = try await infer(ChatGPTModel.applyingReasoning(reasoningEffort, to: repair))
            try Task.checkCancellation()
            guard corrected.utf8.count <= 200_000 else { throw AnalysisCoreError.invalidOutput }
            return try validate(corrected)
        }
    }

    public static func invoke(_ command: String, json: String) throws -> String {
        let validating = command.hasPrefix("validate") || command.hasPrefix("finish") ||
            command.hasPrefix("complete") || command.hasPrefix("apply") || command == "mergeJournalParts"
        let timings = validating ? AnalysisPhaseTimings.current : nil
        let start = timings.map { _ in DispatchTime.now() }
        defer { if let start { timings?.record(.validation, since: start) } }
        guard json.utf8.count <= 16_000_000 else { throw AnalysisCoreError.invalidInput }
        guard let url = Bundle(for: BundleAnchor.self).url(forResource: "dailyx-analysis", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { throw AnalysisCoreError.unavailable }
        context.evaluateScript(script)
        guard context.exception == nil,
              let bridge = context.objectForKeyedSubscript("DailyXAnalysis"), !bridge.isUndefined,
              let output = bridge.invokeMethod("invokeChecked", withArguments: [command, json]),
              context.exception == nil, output.isString, let text = output.toString() else {
            throw AnalysisCoreError.invalidOutput
        }
        guard let envelope = try? JSONDecoder().decode(AnalysisCoreEnvelope.self, from: Data(text.utf8)) else {
            throw AnalysisCoreError.invalidOutput
        }
        if !envelope.ok, let failure = envelope.error {
            // Metadata is produced by the bundled bridge, never by the model response.
            throw AnalysisValidationFailure(command: command, code: failure.code, issues: failure.issues)
        }
        guard envelope.ok, let value = envelope.value else { throw AnalysisCoreError.invalidOutput }
        return value
    }
    private final class BundleAnchor: NSObject {}
}
