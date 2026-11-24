#if DEBUG
import Foundation
import DailyCore
/// Synthetic UI review fixture; excluded from every release build.
enum AtlasPreview {
    static func records(includeSecondMap: Bool = false) throws -> [WorkspaceRecord] {
        let id = String(repeating: "a", count: 32)
        let labels = ["Güne yürüyerek başlamak", "Daha iyi uyku", "Düzenli hareket", "Odaklanma", "Küçük hedefler", "Akşam rutini"]
        let nodes: [[String: Any]] = labels.enumerated().map { i, label in
            ["id":"n\(i)","label":label,"summary":i == 0 ? "Küçük ama sürdürülebilir rutinler günün akışını değiştirebilir. Bu, arayüzü göstermek için hazırlanmış örnek bir haritadır." : "Örnek düşünce bağlantısı.","status":i == 0 ? "recurring" : "candidate","updatedAt":"2026-09-29","topicPath":["Günlük ritim","Rutinler"]]
        }
        let edges: [[String: Any]] = (1..<labels.count).map { ["id":"e\($0)","source":"n0","target":"n\($0)","relation":"Birlikte düşün"] }
        func make(_ key: String, _ fields: [String: Any]) throws -> WorkspaceRecord {
            let text = String(data: try JSONSerialization.data(withJSONObject:fields), encoding:.utf8)!
            return try WorkspaceRecord.make(key:key,kind:.note,payload:.string(text))
        }
        let a = try make("note:companion/atlas/\(id)-nodes-0.md",["schemaVersion":1,"mapId":id,"kind":"nodes","items":nodes])
        let b = try make("note:companion/atlas/\(id)-edges-0.md",["schemaVersion":1,"mapId":id,"kind":"edges","items":edges])
        var pages = [a, b]
        var maps: [[String: Any]] = [["id":id,"title":"Günlük ritim · Örnek","updatedAt":"2026-09-29","nodeCount":nodes.count,"edgeCount":edges.count,"pages":[["key":a.key,"hash":a.hash],["key":b.key,"hash":b.hash]]]]
        if includeSecondMap {
            let secondID = String(repeating: "b", count: 32)
            let page = try make("note:companion/atlas/\(secondID)-nodes-0.md", ["schemaVersion":1,"mapId":secondID,"kind":"nodes","items":[[
                "id":"work-note","label":"Sunum hazırlığı","summary":"Örnek çalışma notu.","status":"candidate","updatedAt":"2026-09-29","topicPath":["Çalışma"]
            ]]])
            pages.append(page)
            maps.append(["id":secondID,"title":"Çalışma","updatedAt":"2026-09-29","nodeCount":1,"edgeCount":0,"pages":[["key":page.key,"hash":page.hash]]])
        }
        let index = try make("note:companion/atlas/index.md", ["schemaVersion":1,"maps":maps])
        return pages + [index]
    }
}
#endif
