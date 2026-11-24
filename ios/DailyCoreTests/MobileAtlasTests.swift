import XCTest
@testable import DailyCore
final class MobileAtlasTests: XCTestCase {
    private let id = String(repeating: "a", count: 32)
    private func fixtures() throws -> [WorkspaceRecord] {
        let node: [String: Any] = ["id":"n", "label":"Yürüyüş", "summary":"Hareket rutini", "status":"observation", "updatedAt":"2026-09-29", "topicPath":["Sağlık"]]
        func make(_ key: String, _ object: [String: Any]) throws -> WorkspaceRecord {
            let text = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            return try WorkspaceRecord.make(key: key, kind: .note, payload: .string(text))
        }
        let page = try make("note:companion/atlas/\(id)-nodes-0.md", ["schemaVersion":1,"mapId":id,"kind":"nodes","items":[node]])
        let index = try make("note:companion/atlas/index.md", ["schemaVersion":1,"maps":[["id":id,"title":"Sağlık","updatedAt":"2026-09-29","nodeCount":1,"edgeCount":0,"pages":[["key":page.key,"hash":page.hash]]]]])
        return [page,index]
    }
    func testCompleteSnapshotAndMissingPage() throws {
        let records = try fixtures()
        let atlas = try XCTUnwrap(MobileAtlas.load(records: records))
        XCTAssertEqual(try MobileAtlas.graph(for: atlas.maps[0], records: records).nodes.first?.label, "Yürüyüş")
        XCTAssertThrowsError(try MobileAtlas.graph(for: atlas.maps[0], records: [records[1]]))
        XCTAssertNil(try MobileAtlas.load(records: []))
    }
    func testMixedRevisionsAreRejected() throws {
        let records = try fixtures(), atlas = try XCTUnwrap(MobileAtlas.load(records: records))
        let changedText = try XCTUnwrap(records[0].payload().string).replacingOccurrences(of: "Hareket rutini", with: "Yeni bilgi")
        let changed = try WorkspaceRecord.make(key: records[0].key, kind: .note, payload: .string(changedText))
        XCTAssertThrowsError(try MobileAtlas.graph(for: atlas.maps[0], records: [changed,records[1]]))
    }
    func testUnsupportedVersionDoesNotCrash() throws {
        let record = try WorkspaceRecord.make(key:"note:companion/atlas/index.md",kind:.note,payload:.string("{\"schemaVersion\":99,\"maps\":[]}"))
        XCTAssertThrowsError(try MobileAtlas.load(records:[record]))
    }
    func testQualityMetadataIsOptionalAndRejectsInvalidPercentages() throws {
        var records=try fixtures()
        XCTAssertNil(try XCTUnwrap(MobileAtlas.load(records:records)).maps[0].quality)
        var index=try JSONSerialization.jsonObject(with:Data(try XCTUnwrap(records[1].payload().string).utf8)) as! [String:Any]
        var maps=index["maps"] as! [[String:Any]]
        var quality:[String:Any]=["percent":78,"reviewedNodes":1,"totalNodes":1,"current":true,"scope":"full",
            "rationale":"Kaynaklar incelendi.","assessedAt":"2026-11-12","strengths":["Kaynak desteği"],"gaps":[],
            "dimensions":["coverage":80,"evidence":90,"coherence":70,"distinctness":60]]
        func updated() throws -> WorkspaceRecord {
            maps[0]["quality"]=quality;index["maps"]=maps
            let text=String(data:try JSONSerialization.data(withJSONObject:index),encoding:.utf8)!
            return try WorkspaceRecord.make(key:records[1].key,kind:.note,payload:.string(text))
        }
        records[1]=try updated()
        XCTAssertEqual(try XCTUnwrap(MobileAtlas.load(records:records)).maps[0].quality?.percent,78)
        quality["percent"]=101;records[1]=try updated()
        XCTAssertThrowsError(try MobileAtlas.load(records:records))
    }
    func testFullNotesAndMissingDetailPage() throws {
        var records = try fixtures()
        let noteText = String(repeating: "Tam içerik ", count: 180)
        let text = String(data: try JSONSerialization.data(withJSONObject: ["schemaVersion":1,"mapId":id,"kind":"notes","items":[["nodeId":"n","kind":"observation","date":"2026-09-29","text":noteText]]]), encoding:.utf8)!
        let detail = try WorkspaceRecord.make(key:"note:companion/atlas/\(id)-notes-0.md",kind:.note,payload:.string(text))
        var index = try JSONSerialization.jsonObject(with:Data(try XCTUnwrap(records[1].payload().string).utf8)) as! [String:Any]
        var maps = index["maps"] as! [[String:Any]]
        maps[0]["detailPages"] = [["key":detail.key,"hash":detail.hash]]; index["maps"] = maps
        records[1] = try WorkspaceRecord.make(key:records[1].key,kind:.note,payload:.string(String(data:try JSONSerialization.data(withJSONObject:index),encoding:.utf8)!))
        let atlas = try XCTUnwrap(MobileAtlas.load(records:records))
        XCTAssertThrowsError(try MobileAtlas.notes(for:atlas.maps[0],records:records))
        XCTAssertEqual(try MobileAtlas.notes(for:atlas.maps[0],records:records+[detail]).first?.text,noteText)
    }

    func testSearchMatchesMapAndNodeLabelsAndFindsFullNoteWithSource() throws {
        let records = try fixtures()
        let noteText = String(repeating: "Önce yürüyüş planladım. ", count: 14) + "Sunumdan önce gerildim."
        let note: [String: Any] = [
            "nodeId": "n", "kind": "observation", "date": "2026-09-27", "text": noteText,
            "sourceTitle": "Pazar günlüğü", "sourceId": "journal-pazar"
        ]
        let detailText = String(decoding: try JSONSerialization.data(withJSONObject:
            ["schemaVersion": 1, "mapId": id, "kind": "notes", "items": [note]]), as: UTF8.self)
        let detail = try WorkspaceRecord.make(key: "note:companion/atlas/\(id)-notes-0.md",
                                               kind: .note, payload: .string(detailText))
        let indexText = try XCTUnwrap(records[1].payload().string)
        var index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(indexText.utf8)) as? [String: Any])
        var maps = try XCTUnwrap(index["maps"] as? [[String: Any]])
        maps[0]["detailPages"] = [["key": detail.key, "hash": detail.hash]]
        index["maps"] = maps
        let updated = try WorkspaceRecord.make(key: records[1].key, kind: .note, payload: .string(
            String(decoding: try JSONSerialization.data(withJSONObject: index), as: UTF8.self)))
        let atlas = try XCTUnwrap(MobileAtlas.load(records: [updated]))
        let byKey = Dictionary(uniqueKeysWithValues: [records[0], detail].map { (WorkspaceHash.sha256($0.key), $0) })
        let search = try AtlasSearchIndex(atlas: atlas, records: byKey)
        let locale = Locale(identifier: "tr_TR")

        XCTAssertEqual(try search.search("Sağlık", locale: locale).map(\.title), ["Sağlık"])
        XCTAssertEqual(try search.search("YURUYUS", locale: locale).first?.nodeID, "n")
        let match = try XCTUnwrap(search.search("Sunumdan", locale: locale).first)
        XCTAssertEqual(match.nodeID, "n")
        XCTAssertEqual(match.mapID, id)
        XCTAssertEqual(match.date, "2026-09-27")
        XCTAssertEqual(match.sourceTitle, "Pazar günlüğü")
        XCTAssertTrue(match.excerpt?.contains("Sunumdan") == true)
        XCTAssertEqual(try search.search("bambaşka", locale: locale).count, 0)

        let partial = try AtlasSearchIndex(atlas: atlas, records: [WorkspaceHash.sha256(records[0].key): records[0]])
        XCTAssertTrue(partial.hasUnavailablePages)
        XCTAssertEqual(try partial.search("Yürüyüş", locale: locale).first?.nodeID, "n")
        XCTAssertTrue(try partial.search("Sunumdan", locale: locale).isEmpty)
    }

}
