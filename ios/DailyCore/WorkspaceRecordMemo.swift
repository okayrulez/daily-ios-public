import Foundation

/// Reuses decoded UI values while the validated record's content hash is unchanged.
/// Each workspace owns its caches and resets them when its record snapshot changes.
public final class WorkspaceRecordMemo<Value> {
    private struct Entry {
        let hash: String
        let value: Value?
    }
    private var entries: [String: Entry] = [:]

    public init() {}

    public func value(for record: WorkspaceRecord?, decode: (WorkspaceRecord) throws -> Value) -> Value? {
        guard let record else { return nil }
        if let entry = entries[record.key], entry.hash == record.hash { return entry.value }
        let value = try? decode(record)
        entries[record.key] = Entry(hash: record.hash, value: value)
        return value
    }

    public func reset() { entries.removeAll(keepingCapacity: true) }
}
