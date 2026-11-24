import Foundation

public struct ChatGPTModel: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let reasoningLevels: [String]

    public static func catalog(_ json: JSONValue) throws -> [ChatGPTModel] {
        guard let rows = json.object?["models"]?.array else { throw WorkspaceError.malformedRecord }
        var seen = Set<String>()
        return rows.compactMap { item in
            guard let row = item.object, row["visibility"]?.string == "list",
                  let id = row["slug"]?.string, !id.isEmpty, seen.insert(id).inserted else { return nil }
            let levels = (row["supported_reasoning_levels"]?.array ?? []).compactMap { value in
                value.object?["effort"]?.string ?? value.string
            }.filter { !$0.isEmpty && $0.count <= 40 }
            var unique = Set<String>()
            return ChatGPTModel(id: id, name: row["display_name"]?.string ?? id,
                                reasoningLevels: levels.filter { unique.insert($0).inserted })
        }
    }
    public static func preferenceKey(scope: String, accountID: String, clientID: String) -> String {
        "dailyx-model-v2-" + WorkspaceHash.sha256(scope + "\n" + accountID + "\n" + clientID)
    }
    public static func selected(in models: [ChatGPTModel], preferred: String?) -> ChatGPTModel? {
        models.first { $0.id == preferred } ?? models.first
    }
    public func reasoning(_ preferred: String?) -> String? {
        preferred.flatMap { reasoningLevels.contains($0) ? $0 : nil }
    }
    public static func applyingReasoning(_ effort: String?, to prompt: String) throws -> String {
        guard var fields = try JSONValue.parse(prompt).object else { throw WorkspaceError.malformedRecord }
        fields.removeValue(forKey: "reasoning")
        if let effort, !effort.isEmpty { fields["reasoning"] = .object(["effort": .string(effort)]) }
        return try JSONValue.object(fields).canonical()
    }
    public static func reasoningLabel(_ value: String) -> String {
        switch value {
        case "none": return "Kapalı"
        case "minimal": return "En az"
        case "low": return "Düşük"
        case "medium": return "Orta"
        case "high": return "Yüksek"
        case "xhigh": return "Çok yüksek"
        case "max": return "Maksimum"
        case "ultra": return "Ultra"
        default: return value
        }
    }
}
