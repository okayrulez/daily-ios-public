import Foundation

public enum ResponsesStreamError: Error, Equatable, Sendable {
    case malformedEvent, oversizedEvent, incomplete, emptyOutput, providerFailed, refusal, unsupportedOutput
    case providerIncomplete(String)
    case providerCode(String)
    public var code: String {
        switch self {
        case .providerCode(let code): return code
        case .providerIncomplete(let reason): return "response_incomplete_" + reason
        case .malformedEvent: return "malformed_event"
        case .oversizedEvent: return "oversized_event"
        case .incomplete: return "stream_ended_before_completion"
        case .emptyOutput: return "completed_without_text"
        case .providerFailed: return "provider_failed"
        case .refusal: return "refusal"
        case .unsupportedOutput: return "unsupported_output"
        }
    }
    public var diagnostic: String { "RESPONSES_STREAM · " + code }
}

/// Incremental UTF-8 SSE reader. Finished output items are buffered until response.completed.
public struct ResponsesStream {
    public private(set) var usage: ResponseUsage?
    private let allowWebSearch: Bool
    public private(set) var citations: [ResponseCitation] = []
    public private(set) var webSearchCalls = 0
    private var line = Data()
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var totalBytes = 0
    private var completedText: String?
    private var failure: ResponsesStreamError?
    private var previousWasCR = false
    private var firstLine = true
    private var eventCount = 0
    private var lastEvent = "none"
    private var sawDone = false
    private var finishedItems: [Int: JSONValue] = [:]
    private var textDeltaCount = 0
    private var textDoneCount = 0
    private var terminalItemCount = 0
    public private(set) var errorType: String?
    public private(set) var errorParameter: String?
    private static let limit = 2_000_000
    /// Protocol metadata only: never include generated text, prompts or server messages.
    public var diagnostic: String {
        "bytes=\(totalBytes) · events=\(eventCount) · last=\(lastEvent) · done=\(sawDone)" +
        " · item_done=\(finishedItems.count) · text_delta=\(textDeltaCount) · text_done=\(textDoneCount) · terminal_items=\(terminalItemCount)"
    }

    public init(allowWebSearch: Bool = false) { self.allowWebSearch = allowWebSearch }

    public mutating func append(_ byte: UInt8) throws {
        do { try consumeByte(byte) }
        catch {
            failure = (error as? ResponsesStreamError) ?? .malformedEvent
            throw error
        }
    }

    private mutating func consumeByte(_ byte: UInt8) throws {
        if let failure { throw failure }
        totalBytes += 1
        guard totalBytes <= Self.limit * 8 else { throw ResponsesStreamError.oversizedEvent }
        if byte == 10 && previousWasCR { previousWasCR = false; return }
        previousWasCR = byte == 13
        if byte == 10 || byte == 13 { try consumeLine() }
        else {
            line.append(byte)
            guard line.count <= Self.limit else { throw ResponsesStreamError.oversizedEvent }
        }
    }

    public mutating func append(_ bytes: Data) throws { for byte in bytes { try append(byte) } }

    public mutating func finish() throws -> String {
        if let failure { throw failure }
        do {
            if !line.isEmpty { try consumeLine() }
            if !dataLines.isEmpty { try dispatch() }
            guard let completedText else { throw ResponsesStreamError.incomplete }
            return completedText
        } catch {
            failure = (error as? ResponsesStreamError) ?? .malformedEvent
            throw error
        }
    }

    private mutating func consumeLine() throws {
        if firstLine {
            firstLine = false
            if line.starts(with: [0xef, 0xbb, 0xbf]) { line.removeFirst(3) }
        }
        guard let value = String(data: line, encoding: .utf8) else { throw ResponsesStreamError.malformedEvent }
        line.removeAll(keepingCapacity: true)
        if value.isEmpty { try dispatch(); return }
        if value.hasPrefix("data:") {
            let data = String(value.dropFirst(5))
            let part = data.hasPrefix(" ") ? String(data.dropFirst()) : data
            eventBytes += part.utf8.count
            guard eventBytes <= Self.limit else { throw ResponsesStreamError.oversizedEvent }
            dataLines.append(part)
        }
    }

    private mutating func dispatch() throws {
        guard !dataLines.isEmpty else { return }
        let data = dataLines.joined(separator: "\n")
        dataLines = []; eventBytes = 0
        if data == "[DONE]" { sawDone = true; return }
        guard let event = try? JSONValue.parse(data).object,
              let type = event["type"]?.string else { throw ResponsesStreamError.malformedEvent }
        if ["response.completed", "response.failed", "response.incomplete"].contains(type),
           let reported = ResponseUsage(json:event["response"]?.object?["usage"]) { usage = reported }
        eventCount += 1
        switch type {
        case "response.created", "response.queued", "response.in_progress",
             "response.output_item.added", "response.output_item.done",
             "response.content_part.added", "response.content_part.done",
             "response.output_text.delta", "response.output_text.done",
             "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done",
             "response.completed", "response.failed", "response.incomplete", "error":
            lastEvent = type
        default: lastEvent = "other"
        }
        if type == "error" || type == "response.failed" || type == "response.incomplete" {
            let providerError = event["response"]?.object?["error"]?.object ?? event["error"]?.object
            errorType = ChatGPTServiceFailure.safe(providerError?["type"]?.string)
            errorParameter = ChatGPTServiceFailure.safe(providerError?["param"]?.string ?? event["param"]?.string)
            if let code = ChatGPTServiceFailure.safe(event["response"]?.object?["error"]?.object?["code"]?.string
                ?? event["error"]?.object?["code"]?.string ?? event["code"]?.string) {
                throw ResponsesStreamError.providerCode(code)
            }
            if type == "response.incomplete" {
                let reason = event["response"]?.object?["incomplete_details"]?.object?["reason"]?.string ?? "unknown"
                // Unknown reasons may contain arbitrary data; do not display them.
                throw ResponsesStreamError.providerIncomplete(
                    reason == "max_output_tokens" || reason == "content_filter" ? reason : "unknown")
            }
            failure = .providerFailed; throw ResponsesStreamError.providerFailed
        }
        guard completedText == nil else { throw ResponsesStreamError.malformedEvent }
        if type == "response.refusal.delta" || type == "response.refusal.done" {
            failure = .refusal; throw ResponsesStreamError.refusal
        }
        if type == "response.output_text.delta" { textDeltaCount += 1 }
        if type == "response.output_text.done" { textDoneCount += 1 }
        if type == "response.output_item.done" {
            guard let number = event["output_index"]?.number, number.isFinite,
                  number >= 0, number <= 10_000, number.rounded(.towardZero) == number,
                  let item = event["item"] else { throw ResponsesStreamError.malformedEvent }
            // A done event may also describe an interrupted item. Never use that as output.
            _ = try Self.assistantText(from: [item], requireCompleted: true, allowWebSearch: allowWebSearch)
            let index = Int(number)
            if let previous = finishedItems[index], previous != item { throw ResponsesStreamError.malformedEvent }
            finishedItems[index] = item
            return
        }
        guard type == "response.completed" else { return }
        guard let response = event["response"]?.object,
              response["status"]?.string == "completed", response["error"] == nil || response["error"] == .null,
              let output = response["output"]?.array else { throw ResponsesStreamError.malformedEvent }
        terminalItemCount = output.count
        let terminalText = try Self.assistantText(from: output, allowWebSearch: allowWebSearch)
        // Some streams deliver the finished assistant message on output_item.done and
        // use the terminal response only as a completion acknowledgement. Preserve it.
        // Full terminal output remains authoritative and must never be concatenated twice.
        let text: String
        if !terminalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = terminalText
        } else {
            text = try Self.assistantText(from: finishedItems.keys.sorted().compactMap { finishedItems[$0] }, requireCompleted: true, allowWebSearch: allowWebSearch)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ResponsesStreamError.emptyOutput }
        completedText = text
        if allowWebSearch {
            let all = output + finishedItems.keys.sorted().compactMap { finishedItems[$0] }
            var searches = Set<String>()
            var urls = Set<String>()
            for item in all {
                if item.object?["type"]?.string == "web_search_call",
                   item.object?["status"]?.string == "completed" {
                    let identity = try item.object?["id"]?.string ?? item.canonical()
                    searches.insert(identity)
                }
                for part in item.object?["content"]?.array ?? [] {
                    for value in part.object?["annotations"]?.array ?? [] {
                        guard value.object?["type"]?.string == "url_citation",
                              let raw = value.object?["url"]?.string,
                              let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                              url.host != nil, url.user == nil, url.password == nil,
                              raw.utf8.count <= 3000, urls.insert(raw).inserted else { continue }
                        let candidate = value.object?["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let title = candidate.isEmpty ? (url.host ?? "Kaynak") : candidate
                        citations.append(ResponseCitation(url: raw, title: String(title.prefix(500))))
                        guard citations.count <= 100 else { throw ResponsesStreamError.oversizedEvent }
                    }
                }
            }
            webSearchCalls = searches.count
        }
    }

    private static func assistantText(from output: [JSONValue], requireCompleted: Bool = false, allowWebSearch: Bool = false) throws -> String {
        var texts: [String] = []
        for item in output {
            guard let object = item.object, let itemType = object["type"]?.string else { throw ResponsesStreamError.malformedEvent }
            if itemType == "reasoning" { continue }
            if itemType == "web_search_call" && allowWebSearch {
                guard object["status"]?.string == "completed" else { throw ResponsesStreamError.incomplete }
                continue
            }
            // Journal analysis requests do not expose executable tools.
            guard itemType == "message", object["role"]?.string == "assistant",
                  let content = object["content"]?.array else { throw ResponsesStreamError.unsupportedOutput }
            if requireCompleted || object["status"] != nil {
                guard object["status"]?.string == "completed" else { throw ResponsesStreamError.incomplete }
            }
            for part in content {
                if part.object?["type"]?.string == "refusal" { throw ResponsesStreamError.refusal }
                guard part.object?["type"]?.string == "output_text", let text = part.object?["text"]?.string else {
                    throw ResponsesStreamError.unsupportedOutput
                }
                texts.append(text)
            }
        }
        return texts.joined()
    }
}

public struct ResponseCitation: Codable, Sendable, Equatable {
    public let url: String
    public let title: String
}
