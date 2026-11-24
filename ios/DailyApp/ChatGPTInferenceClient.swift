import Foundation
import DailyCore

enum ChatGPTInferenceError: String, Error {
    case invalidRequest, signInRequired, permissionRequired, usageLimit, serviceUnavailable, unexpectedResponse
}

struct InferenceRequestDiagnostic: Sendable {
    let stage: String
    let model: String
    let scope: String
    let promptBytes: Int
    let elapsedMilliseconds: Int
    let error: Error?
}

/// No Codex process, browser automation, API-key fallback or Firebase intermediary.
actor ChatGPTInferenceClient {
    typealias TokenProvider = @Sendable () async throws -> String
    private let usageScope: @Sendable () async -> String
    private let token: TokenProvider
    private let session: URLSession
    private let diagnostics: @Sendable (InferenceRequestDiagnostic) async -> Void

    init(token: @escaping TokenProvider, usageScope: @escaping @Sendable () async -> String = { "unscoped" },
         diagnostics: @escaping @Sendable (InferenceRequestDiagnostic) async -> Void = { _ in }) {
        self.usageScope = usageScope
        self.token = token
        self.diagnostics = diagnostics
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    func models() async throws -> [ChatGPTModel] {
        let request = try await authorized(path: "models")
        let (data, response) = try await session.data(for: request)
        try check(response, stage: "MODEL_LIST", body: data)
        guard data.count <= 2_000_000,
              let json = (try? JSONValue.parse(String(decoding: data, as: UTF8.self)))?.object,
              let rows = json["models"]?.array else {
            throw ChatGPTServiceFailure(stage: "MODEL_LIST", status: (response as? HTTPURLResponse)?.statusCode,
                requestID: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-request-id"), fallbackCode: "invalid_catalog")
        }
        return try ChatGPTModel.catalog(.object(["models": .array(rows)]))
    }

    func infer(model: String, preparedJSON: String) async throws -> String {
        let timings = AnalysisPhaseTimings.current
        let phaseStart = DispatchTime.now()
        defer { timings?.record(.inference, since: phaseStart) }
        let scope = await usageScope(), id = UUID().uuidString, started = Date()
        let proposedStage = (try? JSONValue.parse(preparedJSON))?.object?["usageStage"]?.string ?? "connectionProbe"
        let stages = ["emotionBackfill", "journal", "journalRepair", "dayReflection", "dayReflectionRepair", "questionRepair", "crossMap", "crossMapRepair", "routeTask", "executeTask", "taskRepair", "mapQuestions", "mapLinks", "responseFormatRepair", "connectionProbe"]
        let stage = stages.contains(proposedStage) ? proposedStage : "other"
        let report: @Sendable (Error?) async -> Void = { error in
            await self.diagnostics(InferenceRequestDiagnostic(stage:stage,model:model,scope:scope,
                promptBytes:preparedJSON.utf8.count,
                elapsedMilliseconds:Int(max(0,min(86_400,Date().timeIntervalSince(started)))*1000),error:error))
        }
        let record: @Sendable (ResponseUsage?, Bool) async -> Void = { usage, succeeded in
            try? await AIUsageLedger.shared.record(AIUsageEntry(id:id,date:started,stage:stage,model:model,
                succeeded:succeeded,duration:Date().timeIntervalSince(started),requestBytes:preparedJSON.utf8.count,usage:usage),scope:scope)
        }
        do {
            let result = try await performInference(model:model,preparedJSON:preparedJSON,record:record)
            await record(nil,true)
            await report(nil)
            return result
        } catch {
            await record(nil,false)
            await report(error)
            throw error
        }
    }

    private func performInference(model: String, preparedJSON: String,
                                  record: @escaping @Sendable (ResponseUsage?, Bool) async -> Void) async throws -> String {
        guard !model.isEmpty, preparedJSON.utf8.count <= 1_000_000,
              let prepared = try JSONValue.parse(preparedJSON).object,
              let instructions = prepared["instructions"]?.string,
              let input = prepared["input"]?.array else { throw ChatGPTInferenceError.invalidRequest }
        var request = try await authorized(path: "responses")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let research = prepared["webResearch"] == .bool(true)
        var fields: [String: JSONValue] = [
            "model": .string(model), "instructions": .string(instructions),
            "input": .array(input), "store": .bool(false), "stream": .bool(true),
        ]
        if let reasoning = prepared["reasoning"] { fields["reasoning"] = reasoning }
        if research {
            fields["tools"] = .array([.object(["type": .string("web_search")])])
            fields["tool_choice"] = .string("required")
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(fields))
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count >= 8192 { break } }
            try check(response, stage: "RESPONSES", body: body)
        }
        try check(response, stage: "RESPONSES")
        let http = response as? HTTPURLResponse
        var body = ResponsesBody(status: http?.statusCode ?? 0,
            contentType: http?.value(forHTTPHeaderField: "Content-Type"),
            requestID: http?.value(forHTTPHeaderField: "x-request-id"),
            retryAfter: http?.value(forHTTPHeaderField: "Retry-After"), allowWebSearch: research)
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                try body.append(byte)
            }
            try Task.checkCancellation()
            let text = try body.finish()
            await record(body.usage,true)
            if research {
                return try JSONValue.object(["text": .string(text), "webSearchCalls": .number(Double(body.webSearchCalls)),
                    "citations": .array(body.citations.map { .object(["url": .string($0.url), "title": .string($0.title)]) })]).canonical()
            }
            return text
        } catch let error as ResponsesStreamError {
            await record(body.usage,false)
            throw ChatGPTServiceFailure(stage: "RESPONSES_STREAM", status: http?.statusCode,
                requestID: http?.value(forHTTPHeaderField: "x-request-id"), fallbackCode: error.code,
                retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                contentType: http?.value(forHTTPHeaderField: "Content-Type"), streamDiagnostic: body.streamDiagnostic,
                fallbackErrorType: body.errorType, fallbackParameter: body.errorParameter)
        } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost || error.code == .notConnectedToInternet {
            await record(body.usage,false)
            throw ChatGPTServiceFailure(stage: "RESPONSES_STREAM", status: http?.statusCode,
                requestID: http?.value(forHTTPHeaderField: "x-request-id"),
                fallbackCode: error.code == .timedOut ? "stream_timeout" : "stream_connection_lost",
                contentType: http?.value(forHTTPHeaderField: "Content-Type"), streamDiagnostic: body.streamDiagnostic)
        } catch {
            await record(body.usage,false)
            throw error
        }
    }

    private func authorized(path: String) async throws -> URLRequest {
        let accessToken = try await token()
        try Task.checkCancellation()
        guard !accessToken.isEmpty, !accessToken.contains("\r"), !accessToken.contains("\n") else {
            throw ChatGPTInferenceError.signInRequired
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/" + path)!)
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        return request
    }

    private func check(_ response: URLResponse, stage: String, body: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { throw ChatGPTServiceFailure(stage: stage, fallbackCode: "non_http") }
        guard (200..<300).contains(http.statusCode) else {
            throw ChatGPTServiceFailure(stage: stage, status: http.statusCode, body: body,
                requestID: http.value(forHTTPHeaderField: "x-request-id"),
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"), contentType: http.value(forHTTPHeaderField: "Content-Type"))
        }
    }
}

/// Never forward the bearer token through a redirected request.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
