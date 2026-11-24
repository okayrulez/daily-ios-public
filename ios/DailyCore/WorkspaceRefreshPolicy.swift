import Foundation

/// Full cross-device reconciliation is independent of the five-entry AI map quality review.
public struct WorkspaceRefreshPolicy: Codable, Sendable {
    public var lastFullSync: Date
    public var newJournalIDs: Set<String> = []
    public init(now: Date = Date()) { lastFullSync = now }
    public mutating func completedNewJournal(_ id: String) { newJournalIDs.insert(id) }
    public func isDue(now: Date = Date()) -> Bool {
        newJournalIDs.count >= 5 || now.timeIntervalSince(lastFullSync) >= 7 * 86400
    }
    public mutating func didSync(now: Date = Date()) { lastFullSync = now; newJournalIDs = [] }
    public static func cacheIdentity(projectID: String, uid: String) -> String {
        WorkspaceHash.sha256(projectID) + "-" + WorkspaceHash.sha256(uid)
    }
}
