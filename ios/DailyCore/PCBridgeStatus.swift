import Foundation

public struct PCBridgeStatus: Decodable, Sendable {
    public let schemaVersion: Int
    public let heartbeatAt: String
    public let busy: Bool
    public let pending, failed, complete, mapCount, nodeCount: Int
    public let lastAnalysisAt: String?
    public let atlasHash: String
    public static func load(records: [WorkspaceRecord]) throws -> PCBridgeStatus? {
        guard let record = records.first(where: { $0.key == "note:companion/pc-status.md" }) else { return nil }
        guard record.kind == .note, let text = try record.payload().string else { throw WorkspaceError.malformedRecord }
        let status = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard status.schemaVersion == 1, [status.pending,status.failed,status.complete,status.mapCount,status.nodeCount].allSatisfy({ $0 >= 0 }),
              CompanionCard.date(status.heartbeatAt) != nil else { throw WorkspaceError.malformedRecord }
        return status
    }
    public func recentlySeen(at date: Date) -> Bool {
        guard let seen = CompanionCard.date(heartbeatAt) else { return false }
        let age = date.timeIntervalSince(seen)
        return age >= -60 && age < 180
    }
}
