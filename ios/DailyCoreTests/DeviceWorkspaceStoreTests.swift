import XCTest
@testable import DailyCore

final class DeviceWorkspaceStoreTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func note(_ text: String, key: String = "note:test") throws -> WorkspaceRecord {
        try WorkspaceRecord.make(key: key, kind: .note, payload: .string(text))
    }
    func testResetFenceSurvivesRestartAndErasesVersionsAndUnsentWork() throws {
        let root = try root(), scope = try MemoryScope(projectID: "own-project", uid: "alice")
        let store = try DeviceWorkspaceStore(root: root, scope: scope)
        let first = try note("before"), second = try note("after")
        try store.apply([first], expected: [], publish: true)
        try store.apply([second], expected: [], publish: true)
        let pending = try XCTUnwrap(store.firstPublication())
        try store.beginReset()
        let reopened = try DeviceWorkspaceStore(root: root, scope: scope)
        XCTAssertTrue(reopened.resetPending)
        XCTAssertThrowsError(try reopened.apply([first], expected: [], publish: false))
        XCTAssertThrowsError(try reopened.importCloud([first]))
        XCTAssertThrowsError(try reopened.acknowledge(pending))
        XCTAssertThrowsError(try reopened.queueCurrentRecords())
        XCTAssertThrowsError(try reopened.memory())
        let other = try DeviceWorkspaceStore(root: root, scope: MemoryScope(projectID: "own-project", uid: "bob"))
        try other.apply([first], expected: [], publish: false)
        XCTAssertThrowsError(try other.copyDeviceWorkspace(from: reopened))
        try reopened.finishReset()
        let empty = try DeviceWorkspaceStore(root: root, scope: scope)
        XCTAssertFalse(empty.resetPending)
        XCTAssertTrue(empty.records().isEmpty)
        XCTAssertEqual(empty.pendingCount, 0)
        XCTAssertNil(empty.version(key: first.key, hash: first.hash))
        XCTAssertEqual(other.record(first.key), first)
        try empty.apply([first], expected: [], publish: false)
        XCTAssertEqual(empty.record(first.key), first)
    }
    func testLocalSaveSurvivesRestartWithoutCloudPublication() throws {
        let root = try root(), scope = try MemoryScope(projectID: "daily-local", uid: "device-a")
        let store = try DeviceWorkspaceStore(root: root, scope: scope), first = try note("Yerel yazım")
        try store.apply([first], expected: [.init(key: first.key, hash: nil)], publish: false)
        let reopened = try DeviceWorkspaceStore(root: root, scope: scope)
        XCTAssertEqual(reopened.record(first.key), first)
        XCTAssertEqual(reopened.pendingCount, 0)
    }
    func testNewDayAndTextEditsDoNotRemoveThePreviousDaysCompletedAnalysis() throws {
        let directory = try root(), scope = try MemoryScope(projectID: "daily-local", uid: "device-a")
        let store = try DeviceWorkspaceStore(root: directory, scope: scope)
        let historical = try WorkspaceFixture.record()
        try store.apply([historical], expected: [], publish: false)
        let next = try WorkspaceSavePlanner.plan(current: nil, expectedHash: nil, date: "2026-08-31",
            text: "Ertesi günün yazısı", answers: [:], now: "2026-08-31T10:00:00Z", newID: "next-day").record
        try store.apply([next], expected: [], publish: false)
        let reopened = try DeviceWorkspaceStore(root: directory, scope: scope)
        let yesterday = try XCTUnwrap(reopened.record(historical.key)).journal()
        XCTAssertEqual(yesterday.analysisStatus, "complete")
        XCTAssertEqual(yesterday.analyses.first?.reflection, "Sentetik değerlendirme")
        let changed = try WorkspaceSavePlanner.plan(current: historical, expectedHash: historical.hash, date: yesterday.date,
            text: "Dünkü yazıya ek", answers: [:], now: "2026-08-31T11:00:00Z", newID: "unused").record
        try reopened.apply([changed], expected: [.init(key: historical.key, hash: historical.hash)], publish: false)
        let final = try DeviceWorkspaceStore(root: directory, scope: scope)
        XCTAssertEqual(try final.record(historical.key)?.journal().analyses, yesterday.analyses)
        XCTAssertEqual(try final.record(next.key)?.journal().rawText, "Ertesi günün yazısı")
    }

    func testFailedCASDoesNotChangeAnyRecordOrQueue() throws {
        let store = try DeviceWorkspaceStore(root: root(), scope: MemoryScope(projectID: "daily-local", uid: "device-a"))
        let first = try note("one"), second = try note("two"), other = try note("other", key: "note:other")
        try store.apply([first], expected: [], publish: false)
        XCTAssertThrowsError(try store.apply([second, other], expected: [.init(key: first.key, hash: nil)], publish: true))
        XCTAssertEqual(store.record(first.key), first)
        XCTAssertNil(store.record(other.key))
        XCTAssertEqual(store.pendingCount, 0)
    }
    func testCloudQueueAndVersionsSurviveRestartAndAcknowledgeInOrder() throws {
        let root = try root(), scope = try MemoryScope(projectID: "personal-project", uid: "user-a")
        let store = try DeviceWorkspaceStore(root: root, scope: scope)
        let first = try note("first"), second = try note("second")
        try store.apply([first], expected: [], publish: true)
        try store.apply([second], expected: [.init(key: first.key, hash: first.hash)], publish: true)
        let restored = try DeviceWorkspaceStore(root: root, scope: scope)
        XCTAssertEqual(restored.pendingCount, 2)
        let pending = try XCTUnwrap(restored.firstPublication())
        XCTAssertThrowsError(try restored.importCloud([first]))
        XCTAssertEqual(restored.record(first.key), second)
        try restored.acknowledge(pending)
        XCTAssertThrowsError(try restored.acknowledge(pending))
        XCTAssertEqual(restored.pendingCount, 1)
        XCTAssertEqual(restored.version(key: first.key, hash: first.hash), first)
        XCTAssertEqual(restored.firstPublication()?.expected.first?.hash, first.hash)
    }
    func testLostAcknowledgementDoesNotDuplicateLocalPublication() throws {
        let store = try DeviceWorkspaceStore(root: root(), scope: MemoryScope(projectID: "personal-project", uid: "user-a"))
        let record = try note("source")
        XCTAssertTrue(try store.apply([record], expected: [], publish: true, id: "stable-id"))
        XCTAssertFalse(try store.apply([record], expected: [.init(key: record.key, hash: nil)], publish: true, id: "stable-id"))
        XCTAssertEqual(store.pendingCount, 1)
    }
    func testProjectAndUserIsolationIncludingTransferHistory() throws {
        let root = try root()
        let source = try DeviceWorkspaceStore(root: root, scope: MemoryScope(projectID: "daily-local", uid: "user-a"))
        let other = try DeviceWorkspaceStore(root: root, scope: MemoryScope(projectID: "daily-local", uid: "user-b"))
        let target = try DeviceWorkspaceStore(root: root, scope: MemoryScope(projectID: "own-project", uid: "user-a"))
        let first = try note("first"), second = try note("second")
        try source.apply([first], expected: [], publish: false)
        try source.apply([second], expected: [], publish: false)
        XCTAssertTrue(other.records().isEmpty)
        XCTAssertTrue(target.records().isEmpty)
        try target.copyDeviceWorkspace(from: source)
        XCTAssertEqual(target.record(second.key), second)
        XCTAssertEqual(target.version(key: first.key, hash: first.hash), first)
        try target.queueCurrentRecords()
        XCTAssertEqual(target.pendingCount, 1)
        XCTAssertEqual(source.pendingCount, 0)
        XCTAssertThrowsError(try target.copyDeviceWorkspace(from: source))
    }
    func testLongJournalIsNotTruncatedInDeviceStorage() throws {
        let root = try root(), scope = try MemoryScope(projectID: "daily-local", uid: "user-a")
        let store = try DeviceWorkspaceStore(root: root, scope: scope)
        let text = String(repeating: "Uzun günlük 🧠\n", count: 80_000)
        let record = try WorkspaceSavePlanner.plan(current: nil, expectedHash: nil, date: "2026-11-07", text: text,
            answers: [:], now: "2026-11-07T12:00:00Z", newID: "entry-a").record
        try store.apply([record], expected: [], publish: false)
        let reopened = try DeviceWorkspaceStore(root: root, scope: scope)
        XCTAssertEqual(try reopened.record(record.key)?.journal().rawText, text)
    }
    func testExplicitCloudConflictRecoveryKeepsCompleteLocalCopy() throws {
        let root = try root()
        let cloud = try DeviceWorkspaceStore(root: root, scope: MemoryScope(projectID: "own-project", uid: "user-a"))
        let backupScope = try MemoryScope(projectID: "daily-local", uid: "backup-a")
        let backup = try DeviceWorkspaceStore(root: root, scope: backupScope)
        let local = try note("my unsent edit"), remote = try note("other device's edit")
        try cloud.apply([local], expected: [], publish: true)
        try cloud.useCloudRecords([remote], preservingIn: backup)
        XCTAssertEqual(cloud.record(remote.key), remote)
        XCTAssertEqual(cloud.pendingCount, 0)
        XCTAssertEqual(try DeviceWorkspaceStore(root: root, scope: backupScope).record(local.key), local)
    }
    func testChunkCollisionIsAtomicAndPreconditionIsRetainedForCloud() throws {
        let store = try DeviceWorkspaceStore(root: root(), scope: MemoryScope(projectID: "own-project", uid: "user-a"))
        let chunk = try note("chunk", key: "note:dailyx/chunks/example"), card = try note("card", key: "note:card")
        try store.apply([card], expected: [], chunks: [chunk], publish: false)
        let replacement = try note("tampered", key: chunk.key), update = try note("answer", key: "note:answer")
        XCTAssertThrowsError(try store.apply([update], expected: [], chunks: [replacement], publish: true))
        XCTAssertNil(store.record(update.key))
        try store.apply([update], expected: [.init(key: card.key, hash: card.hash)], publish: true)
        XCTAssertTrue(try XCTUnwrap(store.firstPublication()).expected.contains { $0.key == card.key && $0.hash == card.hash })
    }
    func testFirestoreCodecRoundTripAndIntegerTimestampDecoding() throws {
        let value = JSONValue.object(["schemaVersion": .number(1), "nested": .object(["flag": .bool(true)]),
            "values": .array([.null, .string("🧠"), .number(0.25)])])
        XCTAssertEqual(try FirestoreDocumentCodec.decodeFields(FirestoreDocumentCodec.fields(value)), value)
        let decoded = try FirestoreDocumentCodec.decodeFields(.object([
            "revision": .object(["integerValue": .string("42")]),
            "updatedAt": .object(["timestampValue": .string("2026-11-07T12:00:00Z")])]))
        XCTAssertEqual(decoded.object?["revision"], .number(42))
        XCTAssertEqual(decoded.object?["updatedAt"]?.number, CompanionCard.date("2026-11-07T12:00:00Z")?.timeIntervalSince1970)
        XCTAssertThrowsError(try FirestoreDocumentCodec.decodeFields(.object(["bad": .object([:])])))
    }
}
