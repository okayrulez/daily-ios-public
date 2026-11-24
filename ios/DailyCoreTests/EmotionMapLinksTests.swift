import XCTest
@testable import DailyCore

final class EmotionMapLinksTests: XCTestCase {
    func testOnlyRealNodeEvidenceWithMatchingSourceAndQuoteGetsEmotionColour() throws {
        let mapID = String(repeating: "a", count: 32)
        func record(_ key: String, _ value: JSONValue) throws -> WorkspaceRecord {
            try WorkspaceRecord.make(key: key, kind: .note, payload: .string(value.canonical()))
        }
        let node = JSONValue.object(["id": .string("actual-node"), "label": .string("Sunum"), "summary": .string("Kaynaklı not"),
            "status": .string("observation"), "updatedAt": .string("2026-11-01"), "topicPath": .array([.string("İş")])])
        let nodes = try record("note:companion/atlas/\(mapID)-nodes-0.md", .object([
            "schemaVersion": .number(1), "mapId": .string(mapID), "kind": .string("nodes"), "items": .array([node])]))
        let quote = "Sunum öncesi gerildim"
        let notes = try record("note:companion/atlas/\(mapID)-notes-0.md", .object([
            "schemaVersion": .number(1), "mapId": .string(mapID), "kind": .string("notes"),
            "items": .array([.object(["nodeId": .string("actual-node"), "kind": .string("observation"),
                "date": .string("2026-11-01"), "text": .string("Gerilim"), "quote": .string(quote), "sourceId": .string("journal-one")])])]))
        let index = try record("note:companion/atlas/index.md", .object(["schemaVersion": .number(1), "maps": .array([.object([
            "id": .string(mapID), "title": .string("İş"), "updatedAt": .string("2026-11-01"), "nodeCount": .number(1), "edgeCount": .number(0),
            "pages": .array([.object(["key": .string(nodes.key), "hash": .string(nodes.hash)])]),
            "detailPages": .array([.object(["key": .string(notes.key), "hash": .string(notes.hash)])])])])]))
        func day(_ source: String, _ text: String) -> EmotionDay {
            let observation = EmotionObservation(id: "o", key: "tension", label: "Gerilim", definition: "", intensity: nil,
                event: "Sunum", quote: text, sequence: 0)
            return EmotionDay(date: "2026-11-01", sourceID: source, reflection: "", observations: [observation], helpful: [], connections: [], userSelected: false)
        }
        let records = [index, nodes, notes]
        let fields = try EmotionMapLinks.fields(records: records, days: [day("journal-one", quote)])
        XCTAssertEqual(fields.first?.nodeEmotions["actual-node"], ["tension"])
        XCTAssertEqual(fields.first?.graph.nodes.first?.id, "actual-node")
        XCTAssertTrue(try EmotionMapLinks.fields(records: records, days: [day("another-journal", quote)]).isEmpty)
        XCTAssertTrue(try EmotionMapLinks.fields(records: records, days: [day("journal-one", "Başka alıntı")]).isEmpty)
    }
}
