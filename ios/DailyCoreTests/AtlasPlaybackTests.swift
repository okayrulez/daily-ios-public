import XCTest
@testable import DailyCore

final class AtlasPlaybackTests: XCTestCase {
    private func node(_ id: String, _ label: String = "Not") -> MobileAtlas.Node {
        .init(id: id, label: label, status: "observation", summary: "", updatedAt: "", topicPath: ["Konu"])
    }
    func testRemoteChangesIncludeRemovedGhostsAndChangedRelationships() {
        let old = MobileAtlas.Graph(nodes: [node("a"), node("b")], edges: [.init(id: "e", source: "a", target: "b", relation: "bağ")])
        let new = MobileAtlas.Graph(nodes: [node("a", "Güncel"), node("c")], edges: [.init(id: "f", source: "a", target: "c", relation: "yeni")])
        let delta = AtlasPlayback(previous: old, current: new)
        XCTAssertEqual(delta.addedNodes, ["c"]); XCTAssertEqual(delta.updatedNodes, ["a"])
        XCTAssertEqual(delta.removedNodes, ["b"]); XCTAssertEqual(delta.removedEdges, ["e"])
        XCTAssertEqual(delta.changedEdges, ["f"])
        XCTAssertEqual(delta.drawing.nodes.count, 3); XCTAssertEqual(delta.drawing.edges.count, 2)
    }
    func testIndependentDevicesAccountsAndInterruptedPlayback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pc = AtlasPlaybackStore(root: root.appendingPathComponent("pc"))
        let phone = AtlasPlaybackStore(root: root.appendingPathComponent("phone"))
        let graph = MobileAtlas.Graph(nodes: [node("a")], edges: [])
        // Computing playback does not consume it; only a completed display acknowledges it.
        XCTAssertTrue(AtlasPlayback(previous: pc.read(scope: "owner", mapID: "map"), current: graph).hasChanges)
        XCTAssertNil(pc.read(scope: "owner", mapID: "map"))
        try pc.acknowledge(graph, scope: "owner", mapID: "map")
        XCTAssertFalse(AtlasPlayback(previous: pc.read(scope: "owner", mapID: "map"), current: graph).hasChanges)
        XCTAssertTrue(AtlasPlayback(previous: phone.read(scope: "owner", mapID: "map"), current: graph).hasChanges)
        XCTAssertNil(pc.read(scope: "other", mapID: "map"))
    }
    func testRevisionIsStableAcrossOrderAndChangesForSameNodeContent() {
        let first = MobileAtlas.Graph(nodes: [node("a"), node("b")], edges: [])
        XCTAssertEqual(first.revision, MobileAtlas.Graph(nodes: Array(first.nodes.reversed()), edges: []).revision)
        XCTAssertNotEqual(first.revision, MobileAtlas.Graph(nodes: [node("a", "Değişti"), node("b")], edges: []).revision)
    }
}
