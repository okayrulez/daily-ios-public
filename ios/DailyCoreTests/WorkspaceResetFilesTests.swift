import XCTest
@testable import DailyCore

final class WorkspaceResetFilesTests: XCTestCase {
    func testOnlySelectedProjectAndUserFilesAreErasedAndRetryIsSafe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = try MemoryScope(projectID: "own-project", uid: "alice")
        let other = try MemoryScope(projectID: "other-project", uid: "alice")
        func write(_ path: String) throws -> URL {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("private data".utf8).write(to: file)
            return file
        }
        let ownFiles = try [
            "DailyXMemory/\(scope.storageIdentity).json",
            "DailyXOutbox/\(scope.storageIdentity).json",
            "DailyXProfileOutbox/\(scope.storageIdentity)-old.archived.json",
            "DailyXTasks/\(scope.storageIdentity)/result.json",
            "DailyXResults/\(scope.storageIdentity)/result.json",
            "WorkspaceDraftsByProject/\(scope.projectID)/\(WorkspaceHash.sha256(scope.uid))/2026-11-15.json",
            "atlas-seen-v1/\(WorkspaceHash.sha256(scope.projectID + ":" + scope.uid + ":map-one")).json"
        ].map(write)
        let protectedFiles = try [
            "DailyXMemory/\(other.storageIdentity).json",
            "DailyXTasks/\(other.storageIdentity)/result.json",
            "WorkspaceDraftsByProject/\(other.projectID)/\(WorkspaceHash.sha256(other.uid))/2026-11-15.json",
            "credentials.json"
        ].map(write)
        try WorkspaceResetFiles.erase(root: root, scope: scope, mapIDs: ["map-one"], jobIDs: [])
        XCTAssertTrue(ownFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(protectedFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        try WorkspaceResetFiles.erase(root: root, scope: scope, mapIDs: ["map-one"], jobIDs: [])
    }
}
