import Foundation

/// Cached and reasoning counts are subsets, never additional tokens.
public struct ResponseUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let cachedTokens: Int?
    public let reasoningTokens: Int?

    public init?(json: JSONValue?) {
        guard let value = json?.object else { return nil }
        func count(_ value: JSONValue?) -> Int? {
            guard let number = value?.number, number.isFinite, number >= 0,
                  number <= 1_000_000_000, number.rounded(.towardZero) == number else { return nil }
            return Int(number)
        }
        let input = count(value["input_tokens"]), output = count(value["output_tokens"])
        inputTokens = input
        outputTokens = output
        totalTokens = count(value["total_tokens"])
        let cached = count(value["input_tokens_details"]?.object?["cached_tokens"])
        let reasoning = count(value["output_tokens_details"]?.object?["reasoning_tokens"])
        cachedTokens = (cached != nil && input != nil && cached! <= input!) ? cached : nil
        reasoningTokens = (reasoning != nil && output != nil && reasoning! <= output!) ? reasoning : nil
        if inputTokens == nil && outputTokens == nil && totalTokens == nil { return nil }
    }
}

public struct AIUsageEntry: Codable, Identifiable, Sendable {
    public let id: String
    public let date: Date
    public let stage: String
    public let model: String
    public let succeeded: Bool
    public let duration: Double
    public let requestBytes: Int
    public let usage: ResponseUsage?
    public init(id: String, date: Date, stage: String, model: String, succeeded: Bool,
                duration: Double, requestBytes: Int, usage: ResponseUsage?) {
        self.id=id; self.date=date; self.stage=stage; self.model=model; self.succeeded=succeeded
        self.duration=duration; self.requestBytes=requestBytes; self.usage=usage
    }
}

/// Device-local, account-scoped bounded metadata. No prompts, answers or credentials.
public actor AIUsageLedger {
    public static let shared = AIUsageLedger()
    private let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("DailyXUsage",isDirectory:true)
    }
    private func file(_ scope: String) -> URL { root.appendingPathComponent(WorkspaceHash.sha256(scope)+".json") }
    public func entries(scope: String) throws -> [AIUsageEntry] {
        let url=file(scope)
        guard FileManager.default.fileExists(atPath:url.path) else { return [] }
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 2_000_000 else { throw WorkspaceError.oversizedRecord }
        return try JSONDecoder().decode([AIUsageEntry].self,from:Data(contentsOf:url))
    }
    public func record(_ entry: AIUsageEntry, scope: String) throws {
        var rows=try entries(scope:scope)
        let old=rows.first { $0.id == entry.id }
        rows.removeAll { $0.id == entry.id }
        rows.append(AIUsageEntry(id:entry.id,date:entry.date,stage:entry.stage,model:entry.model,
            succeeded:entry.succeeded,duration:entry.duration,requestBytes:entry.requestBytes,usage:entry.usage ?? old?.usage))
        rows=Array(rows.sorted { $0.date < $1.date }.suffix(500))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(rows).write(to:file(scope),options:[.atomic,.completeFileProtection])
    }
    public func clear(scope: String) throws {
        let url=file(scope)
        if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
    }
}
