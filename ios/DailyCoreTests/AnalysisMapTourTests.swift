import XCTest
@testable import DailyCore

final class AnalysisMapTourTests: XCTestCase {
    private let mapID = String(repeating: "a", count: 32)
    private func fixtures(
        missingNotes: Bool = false,
        edges: [[String: String]] = [["id": "link", "source": "one", "target": "two", "relation": "Kaynaklı bağlantı"]]
    ) throws -> [WorkspaceRecord] {
        let nodes: [[String: Any]] = ["one", "two", "three"].map {
            ["id": $0, "label": $0, "summary": "Kaydedilmiş not " + $0, "status": "observation",
             "updatedAt": "2026-11-06", "topicPath": ["Üretim"]]
        }
        func record(_ key: String, _ payload: [String: Any]) throws -> WorkspaceRecord {
            let data = try JSONSerialization.data(withJSONObject: payload)
            return try WorkspaceRecord.make(key: key, kind: .note, payload: .string(String(decoding: data, as: UTF8.self)))
        }
        let nodePage = try record("note:companion/atlas/\(mapID)-nodes-0.md",
            ["schemaVersion": 1, "mapId": mapID, "kind": "nodes", "items": nodes])
        let edgePage = try record("note:companion/atlas/\(mapID)-edges-0.md",
            ["schemaVersion": 1, "mapId": mapID, "kind": "edges",
             "items": edges])
        let index = try record("note:companion/atlas/index.md", ["schemaVersion": 1,
            "maps": [["id": mapID, "title": "Üretim", "updatedAt": "2026-11-06", "nodeCount": 3, "edgeCount": edges.count,
                      "detailPages": missingNotes ? [["key": "note:companion/atlas/\(mapID)-notes-0.md", "hash": nodePage.hash]] : [],
                      "pages": [["key": nodePage.key, "hash": nodePage.hash], ["key": edgePage.key, "hash": edgePage.hash]]]]])
        return [index, nodePage, edgePage]
    }
    private func changes(_ json: String) throws -> AnalysisChanges {
        try JSONDecoder().decode(AnalysisChanges.self, from: Data(json.utf8))
    }
    func testShowsChangedNotesAndLinksTogetherWithoutCountingOldEndpointsAsNew() throws {
        let changes = try changes(#"{"questions":3,"newNotes":1,"updatedNotes":1,"newLinks":1,"addedNodeIDs":["one","missing"],"updatedNodeIDs":["two"],"addedEdgeIDs":["link"]}"#)
        let tour = try XCTUnwrap(AnalysisMapTour.make(id: "job", date: "2026-11-06", changes: changes, records: fixtures()))
        XCTAssertEqual(tour.stops.count, 1)
        let stop = try XCTUnwrap(tour.stops.first)
        XCTAssertEqual(stop.addedNodeIDs, ["one"])
        XCTAssertEqual(stop.updatedNodeIDs, ["two"])
        XCTAssertEqual(stop.graph.nodes.map(\.id), ["one", "two"])
        XCTAssertEqual(stop.graph.edges.map(\.id), ["link"])
    }

    func testGroupsFourRelationshipRecordsIntoOneMapWithDistinctLines() throws {
        let edges = [
            ["id": "link", "source": "one", "target": "two", "relation": "İlişkili"],
            ["id": "reverse", "source": "two", "target": "one", "relation": "İlgili"],
            ["id": "additional", "source": "one", "target": "two", "relation": "Destekler"],
            ["id": "other", "source": "two", "target": "three", "relation": "Eşlik ediyor"]
        ]
        let changes = try changes(#"{"questions":0,"newNotes":2,"updatedNotes":0,"newLinks":4,"addedNodeIDs":["one","two"],"addedEdgeIDs":["link","reverse","additional","other"]}"#)
        let tour = try XCTUnwrap(AnalysisMapTour.make(id: "job", date: "2026-11-17", changes: changes, records: fixtures(edges: edges)))
        XCTAssertEqual(tour.stops.count, 1)
        let stop = try XCTUnwrap(tour.stops.first)
        XCTAssertEqual(stop.addedEdgeIDs, ["link", "reverse", "additional", "other"])
        XCTAssertTrue(stop.updatedEdgeIDs.isEmpty)
        XCTAssertEqual(stop.addedNodeIDs.count, 2)
        XCTAssertEqual(stop.graph.edges.map(\.id), ["link", "other"])
        XCTAssertEqual(tour.graphs[mapID]?.edges.count, 4)
    }

    func testUnlinkedChangedNoteStaysOnTheSameScreenAsChangedLinks() throws {
        let changes = try changes(#"{"questions":0,"newNotes":2,"updatedNotes":0,"newLinks":1,"addedNodeIDs":["one","three"],"addedEdgeIDs":["link"]}"#)
        let tour = try XCTUnwrap(AnalysisMapTour.make(id: "job", date: "2026-11-17", changes: changes, records: fixtures()))
        XCTAssertEqual(tour.stops.count, 1)
        XCTAssertEqual(tour.stops[0].graph.nodes.map(\.id), ["one", "two", "three"])
    }

    func testEditedLinkIsVisibleWithoutNewNotes() throws {
        let changes = try changes(#"{"questions":0,"newNotes":0,"updatedNotes":0,"newLinks":0,"addedNodeIDs":[],"updatedEdgeIDs":["link"]}"#)
        let tour = try XCTUnwrap(AnalysisMapTour.make(id: "job", date: "2026-11-06", changes: changes, records: fixtures()))
        XCTAssertEqual(tour.stops.count, 1)
        XCTAssertTrue(tour.stops[0].addedNodeIDs.isEmpty)
        XCTAssertTrue(tour.stops[0].addedEdgeIDs.isEmpty)
        XCTAssertEqual(tour.stops[0].updatedEdgeIDs, ["link"])
        XCTAssertEqual(tour.stops[0].graph.edges.map(\.id), ["link"])
    }

    @MainActor func testFirstConnectionHintWaitsForASavedJournalLinkAndSurvivesRelaunch() throws {
        let suite = "AnalysisMapTourTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let edges = [
            ["id": "existing", "source": "one", "target": "two", "relation": "İlgili"],
            ["id": "new", "source": "two", "target": "one", "relation": "Destekler"]
        ]
        let records = try fixtures(edges: edges)
        let delta = try changes(#"{"questions":0,"newNotes":0,"updatedNotes":0,"newLinks":1,"addedNodeIDs":[],"updatedEdgeIDs":["existing"],"addedEdgeIDs":["new"]}"#)
        let preview = try XCTUnwrap(AnalysisMapTour.make(id: "example", date: "2026-11-06", changes: delta, records: records))
        XCTAssertNil(preview.claimConnectionHint(at: preview.stops[0], defaults: defaults))

        let edit = try changes(#"{"questions":0,"newNotes":1,"updatedNotes":0,"newLinks":1,"addedNodeIDs":["one"],"updatedEdgeIDs":["existing"],"addedEdgeIDs":["absent"]}"#)
        let earlier = try XCTUnwrap(AnalysisMapTour.make(id: "earlier", date: "2026-11-05", changes: edit,
            records: records, isJournalAnalysis: true))
        XCTAssertNil(earlier.claimConnectionHint(at: earlier.stops[0], defaults: defaults))

        let saved = try XCTUnwrap(AnalysisMapTour.make(id: "journal", date: "2026-11-06", changes: delta,
            records: records, isJournalAnalysis: true))
        let stop = saved.stops[0]
        XCTAssertEqual(stop.graph.edges.map(\.id), ["existing"])
        let hint = try XCTUnwrap(saved.claimConnectionHint(at: stop, defaults: defaults))
        XCTAssertEqual(hint.from.label, "two")
        XCTAssertEqual(hint.to.label, "one")
        XCTAssertNil(saved.claimConnectionHint(at: stop, defaults: defaults))
        let next = try XCTUnwrap(AnalysisMapTour.make(id: "another", date: "2026-11-07", changes: delta,
            records: records, isJournalAnalysis: true))
        XCTAssertNil(next.claimConnectionHint(at: next.stops[0], defaults: try XCTUnwrap(UserDefaults(suiteName: suite))))
    }

    func testMissingNotePageKeepsTheStopAndItsRetryReference() throws {
        let changes = try changes(#"{"questions":0,"newNotes":1,"updatedNotes":0,"newLinks":0,"addedNodeIDs":["one"]}"#)
        let tour = try XCTUnwrap(AnalysisMapTour.make(id: "job", date: "2026-11-06",
            changes: changes, records: fixtures(missingNotes: true)))
        XCTAssertNil(tour.notes[mapID])
        XCTAssertEqual(tour.stops.first?.map.detailPages?.count, 1)
        let complete = try XCTUnwrap(AnalysisMapTour.make(id: "job", date: "2026-11-06", changes: changes, records: fixtures()))
        XCTAssertEqual(complete.notes[mapID]?.count, 0)
    }

    func testRecentCardSkipsOtherMapsAndRevertedChangesAndNamesBothEndpoints() throws {
        let records = try fixtures()
        let map = try XCTUnwrap(MobileAtlas.load(records: records)?.maps.first)
        let graph = try MobileAtlas.graph(for: map, records: records)
        func receipt(_ nodes: [String], _ links: [String], undone: Bool = false) throws -> WorkspaceChangeReceipt {
            let payload: [String: Any] = ["id": "record", "date": "2026-11-10", "createdAt": "2026-11-10",
                "resultHash": "", "memoryHash": "", "sourceHash": "", "priorManifest": NSNull(), "agenda": [], "undone": undone,
                "changes": ["questions": 0, "newNotes": nodes.count, "updatedNotes": 0, "newLinks": links.count,
                            "addedNodeIDs": nodes, "addedEdgeIDs": links] as [String: Any]]
            return try JSONDecoder().decode(WorkspaceChangeReceipt.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let receipts = try [receipt(["one"], [], undone: true), receipt(["outside"], []), receipt([], ["link"])]
        let recent = try XCTUnwrap(AtlasRecentChange.latest(in: graph, receipts: receipts))
        XCTAssertEqual(recent.kind, .newLink)
        XCTAssertEqual(recent.title, "one ↔ two")
        XCTAssertEqual(recent.date, "2026-11-10")
        XCTAssertEqual(AtlasRecentChange.latest(in: graph, receipts: [])?.kind, .datedNote)
    }

    func testNoChangesDoesNotProduceAnEmptyPresentation() throws {
        let changes = try changes(#"{"questions":5,"newNotes":0,"updatedNotes":0,"newLinks":0,"addedNodeIDs":[]}"#)
        XCTAssertNil(try AnalysisMapTour.make(id: "job", date: "2026-11-06", changes: changes, records: fixtures()))
    }
    func testIncompleteOrMixedSnapshotDoesNotBecomeAPartialTour() throws {
        let changes = try changes(#"{"questions":0,"newNotes":1,"updatedNotes":0,"newLinks":0,"addedNodeIDs":["one"]}"#)
        var records = try fixtures()
        records.removeLast()
        XCTAssertThrowsError(try AnalysisMapTour.make(id: "job", date: "2026-11-06", changes: changes, records: records))
    }
}
