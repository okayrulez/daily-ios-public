import Foundation

/// MIME is diagnostic metadata; only a validated terminal SSE event can produce output.
public struct ResponsesBody {
    private var prefix = Data()
    private var stream: ResponsesStream?
    private var otherBody = false
    private let status: Int
    private let contentType: String?
    private let requestID: String?
    private let retryAfter: String?
    private let now: Date
    private let allowWebSearch: Bool
    public var usage: ResponseUsage? { stream?.usage }
    public var citations: [ResponseCitation] { stream?.citations ?? [] }
    public var webSearchCalls: Int { stream?.webSearchCalls ?? 0 }
    public var streamDiagnostic: String? { stream?.diagnostic }
    public var errorType: String? { stream?.errorType }
    public var errorParameter: String? { stream?.errorParameter }
    public init(status: Int, contentType: String?, requestID: String? = nil, retryAfter: String? = nil, now: Date = Date(), allowWebSearch: Bool = false) {
        self.status=status; self.contentType=contentType; self.requestID=requestID; self.retryAfter=retryAfter; self.now=now
        self.allowWebSearch=allowWebSearch
    }
    public mutating func append(_ byte: UInt8) throws {
        if stream != nil { try stream!.append(byte); return }
        prefix.append(byte)
        if prefix.count >= 8192 { throw failure() }
        if otherBody { return }
        let text = String(decoding: prefix, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        if text.hasPrefix("{") || text.hasPrefix("<") { otherBody=true; return }
        if ["data:", "event:", ":", "id:", "retry:"].contains(where: { text.hasPrefix($0) }) {
            stream=ResponsesStream(allowWebSearch: allowWebSearch); try stream!.append(prefix); prefix.removeAll()
        } else if (byte == 10 || byte == 13) && !text.isEmpty { otherBody=true }
    }
    public mutating func finish() throws -> String {
        if stream != nil { return try stream!.finish() }
        throw failure()
    }
    private func failure() -> ChatGPTServiceFailure {
        ChatGPTServiceFailure(stage: "RESPONSES", status: status, body: prefix, requestID: requestID,
            fallbackCode: "expected_event_stream", retryAfter: retryAfter, contentType: contentType, now: now)
    }
}
