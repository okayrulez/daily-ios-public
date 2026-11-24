import Foundation
import XCTest
@testable import DailyCore

final class PortableMemoryTests: XCTestCase {
    private func memory(_ revision: Int) throws -> PortableMemory {
        try PortableMemory(json: """
        {"schemaVersion":1,"revision":\(revision),"sources":[],"graph":{"topics":[],"nodes":[],"edges":[]},"deadlines":[],"routing":{"version":1,"bindings":{}}}
        """)
    }

    func testAtomicCompareAndSwapAndAccountIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MemoryStore(root: root)
        let alice = try MemoryScope(projectID: "dailyx-test", uid: "alice")
        let bob = try MemoryScope(projectID: "dailyx-test", uid: "bob")
        let otherProject = try MemoryScope(projectID: "dailyx-other", uid: "alice")
        let first = try memory(1)
        try await store.save(first, expectedHash: nil, scope: alice)
        let restored = try await store.load(scope: alice)
        XCTAssertEqual(restored?.contentHash, first.contentHash)
        let other = try await store.load(scope: bob)
        let project = try await store.load(scope: otherProject)
        XCTAssertNil(other); XCTAssertNil(project)
        do {
            try await store.save(memory(2), expectedHash: nil, scope: alice)
            XCTFail("Must reject stale writer")
        } catch { XCTAssertEqual(error as? WorkspaceError, .conflict) }
        try await store.save(memory(2), expectedHash: first.contentHash, scope: alice)
        do {
            let newer = try await store.load(scope: alice)
            try await store.save(first, expectedHash: newer?.contentHash, scope: alice)
            XCTFail("Must reject older revision")
        } catch { XCTAssertEqual(error as? WorkspaceError, .conflict) }
    }

    func testRejectsAtlasAndMalformedSourceMemory() {
        XCTAssertThrowsError(try PortableMemory(json: #"{"schemaVersion":1,"maps":[]}"#))
        XCTAssertThrowsError(try MemoryScope(projectID: "dailyx-test", uid: "../alice"))
    }
}
