import Foundation

public struct AnalysisReplyText: Sendable {
    public let text: String
    public let fullText: String?
    public private(set) var sources: [ResponseCitation] = []

    public init(raw: String) {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            text = raw.isEmpty ? "Henüz okunabilir bir yanıt alınmadı." : raw
            fullText = nil
            return
        }
        func nonempty(_ value: Any?) -> String? {
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var sections: [String] = []
        var seen = Set<String>()
        func append(_ value: Any?, title: String? = nil) {
            guard let text = nonempty(value), seen.insert(text).inserted else { return }
            sections.append(title.map { $0 + "\n" + text } ?? text)
        }
        append(object["reflection"])
        append(object["reply"])
        if let rows = object["sources"] as? [[String: Any]] {
            sources = rows.prefix(100).compactMap { row in
                guard let raw = row["url"] as? String, let url = URL(string: raw),
                      ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                      url.host != nil, url.user == nil, url.password == nil else { return nil }
                return ResponseCitation(url: raw, title: row["title"] as? String ?? url.host ?? "Kaynak")
            }
        }
        if let memory = object["living_memory"] as? [String: Any] {
            append(memory["summary"], title: "Özet")
            append(memory["encouragement"], title: "Sana not")
            append(memory["reflection_question"], title: "Üzerine düşün")
            append(memory["next_step"], title: "Sonraki adım")
        }
        let pretty = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? raw
        text = sections.isEmpty ? pretty : sections.joined(separator: "\n\n")
        fullText = sections.isEmpty ? nil : pretty
    }
}
