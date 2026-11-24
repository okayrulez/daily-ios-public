import Foundation

/// Deletes only paths whose owner is known. Account credentials and appearance preferences are separate.
public enum WorkspaceResetFiles {
    public static func erase(root: URL, scope: MemoryScope, mapIDs: [String], jobIDs: [String]) throws {
        let fm = FileManager.default
        func remove(_ file: URL) throws {
            guard fm.fileExists(atPath: file.path) else { return }
            try fm.removeItem(at: file)
        }
        for name in ["DailyXMemory", "DailyXOutbox", "DailyXProfileOutbox"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: directory.path) {
                for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    where file.lastPathComponent == scope.storageIdentity + ".json"
                        || file.lastPathComponent.hasPrefix(scope.storageIdentity + "-") {
                    try remove(file)
                }
            }
        }
        try remove(root.appendingPathComponent("WorkspaceDraftsByProject", isDirectory: true)
            .appendingPathComponent(scope.projectID, isDirectory: true)
            .appendingPathComponent(WorkspaceHash.sha256(scope.uid), isDirectory: true))
        for name in ["DailyXResults", "DailyXTasks"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try remove(directory.appendingPathComponent(scope.storageIdentity, isDirectory: true))
            // Earlier releases used a shared result directory. Only provably owned jobs are removed.
            if fm.fileExists(atPath: directory.path) {
                let owned = Set(jobIDs.filter(WorkspaceHash.valid))
                for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    where owned.contains(String(file.lastPathComponent.prefix(64))) {
                    try remove(file)
                }
            }
        }
        for id in mapIDs {
            let file = WorkspaceHash.sha256(scope.projectID + ":" + scope.uid + ":" + id) + ".json"
            try remove(root.appendingPathComponent("atlas-seen-v1", isDirectory: true).appendingPathComponent(file))
        }
    }
}
