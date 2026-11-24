import XCTest
@testable import DailyCore

final class AnalysisChangesTests: XCTestCase {
    func testCountsAddedAndUpdatedWithoutCountingUnchangedOrRemoved() throws {
        let before = try JSONValue.parse(#"{"nodes":[{"id":"a","label":"Same"},{"id":"b","label":"Old"},{"id":"gone"}],"edges":[{"id":"e1"}]}"#)
        let after = try JSONValue.parse(#"{"nodes":[{"id":"a","label":"Same"},{"id":"b","label":"New"},{"id":"c"}],"edges":[{"id":"e1"},{"id":"e2"}]}"#)
        let changes = try AnalysisChanges(before: before, after: after, questionCount: 13)
        XCTAssertEqual(changes.newNotes, 1)
        XCTAssertEqual(changes.updatedNotes, 1)
        XCTAssertEqual(changes.newLinks, 1)
        XCTAssertEqual(changes.questions, 13)
        XCTAssertEqual(changes.addedNodeIDs, ["c"])
        XCTAssertEqual(changes.updatedNodeIDs, ["b"])
        XCTAssertEqual(changes.addedEdgeIDs, ["e2"])
        XCTAssertEqual(changes.updatedEdgeIDs, [])
    }
    func testUnchangedGraphDoesNotInventChanges() throws {
        let graph = try JSONValue.parse(#"{"nodes":[{"id":"a"}],"edges":[]}"#)
        let changes = try AnalysisChanges(before: graph, after: graph, questionCount: 0)
        XCTAssertEqual(changes.newNotes + changes.updatedNotes + changes.newLinks, 0)
    }
    func testEditedEdgesAnimateWithoutNewNodes() throws {
        let before = try JSONValue.parse(#"{"nodes":[{"id":"a"},{"id":"b"}],"edges":[{"id":"e","relation":"old"}]}"#)
        let after = try JSONValue.parse(#"{"nodes":[{"id":"a"},{"id":"b"}],"edges":[{"id":"e","relation":"new"}]}"#)
        let changes = try AnalysisChanges(before: before, after: after, questionCount: 0)
        XCTAssertEqual(changes.updatedEdgeIDs, ["e"])
        XCTAssertFalse(changes.animationIdentity.isEmpty)
    }
    func testOlderOutboxChangeSummaryRemainsReadable() throws {
        let data = Data(#"{"questions":8,"newNotes":1,"updatedNotes":0,"newLinks":0,"addedNodeIDs":["a"]}"#.utf8)
        let changes = try JSONDecoder().decode(AnalysisChanges.self, from: data)
        XCTAssertNil(changes.updatedNodeIDs)
        XCTAssertEqual(changes.animationIdentity, "a")
    }
    func testRejectsAmbiguousNodeIdentities() throws {
        let empty = try JSONValue.parse(#"{"nodes":[],"edges":[]}"#)
        let duplicate = try JSONValue.parse(#"{"nodes":[{"id":"a"},{"id":"a"}],"edges":[]}"#)
        XCTAssertThrowsError(try AnalysisChanges(before: empty, after: duplicate, questionCount: 0))
    }
}
