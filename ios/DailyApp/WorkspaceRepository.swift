import Foundation
import DailyCore

enum NativePushFailure: LocalizedError {
    case workerUpdate
    var errorDescription: String? {
        String(localized: "Bu hatırlatmayı Apple’a aktarmak için Firebase bildirim servisinin etkinlik bazlı teslimatı desteklemesi gerekiyor.")
    }
}

enum WorkspaceSyncError: LocalizedError, Equatable {
    case cloudRequired, disconnected, conflict, databaseMissing, googleSetupMissing
    var errorDescription: String? {
        switch self {
        case .cloudRequired: "Bu özellik için isteğe bağlı Firebase eşitlemesini bağla. Cihazındaki kayıtlar korunuyor."
        case .disconnected: "Google bağlantısı yenilenemedi. Kayıtların bu cihazda saklandı."
        case .conflict: "Bulutta aynı kayıt değişmiş. Yerel kayıtların korundu; farklı sürümler otomatik olarak birbirinin üstüne yazılmadı."
        case .databaseMissing: "Bu projede henüz Firestore veritabanı yok. Ücretsiz veritabanını oluşturup yeniden bağlanabilirsin."
        case .googleSetupMissing: "Bu uygulama derlemesinin Google bağlantısı hazır değil. Firebase olmadan bu cihazda devam edebilirsin."
        }
    }
}

@MainActor protocol WorkspaceCloudClient: AnyObject, Sendable {
    func read(_ key: String) async throws -> WorkspaceRecord?
    func snapshot() async throws -> [WorkspaceRecord]
    func publish(_ publication: WorkspacePublication) async throws
    func prompts() async throws -> AnalysisPromptConfiguration
    func version(key: String, hash: String) async throws -> WorkspaceRecord
    func registerPush(deviceID: String, token: String?, environment: String) async throws
    func analysisRequests() async throws -> [WorkspaceAnalysisRequest]
    func enqueue(source: WorkspaceRecord, kind: WorkspaceAnalysisKind) async throws -> String
    func invalidate()
    func eraseWorkspace() async throws
}
extension WorkspaceCloudClient { func invalidate() {} }
struct WorkspaceResetFailure: LocalizedError {
    let collection: String
    let underlying: Error
    var errorDescription: String? { "\(collection): \(underlying.localizedDescription)" }
}

/// Every feature uses protected device storage. The cloud is only an optional publication target.
@MainActor final class WorkspaceRepository {
    let store: DeviceWorkspaceStore
    let cloud: (any WorkspaceCloudClient)?
    private(set) var cloudVerified = false
    private(set) var syncConflict = false
    var syncNotice = ""
    var onSyncStateChange: (() -> Void)?
    private var scope: WorkspaceRequestScope?
    private var receive: (@MainActor @Sendable ([WorkspaceRecord]?, Bool, Bool, String?) -> Void)?
    private var requestReceive: (@MainActor @Sendable ([WorkspaceAnalysisRequest]?, Bool, Bool, String?) -> Void)?
    private var syncTask: Task<Void, Never>?
    private var publicationSuspended = false
    private var cloudFingerprint: String?
    private var promptCache: (scope: WorkspaceRequestScope, config: AnalysisPromptConfiguration, expires: ContinuousClock.Instant)?
    private var active = true
    var cloudEnabled: Bool { cloud != nil }

    init(store: DeviceWorkspaceStore, cloud: (any WorkspaceCloudClient)? = nil) {
        self.store = store; self.cloud = cloud
        cloudFingerprint = (store.record("note:companion/sync-revision.json")?.hash ?? "") + (store.record(PhoneAnalysisCommit.manifestKey)?.hash ?? "")
    }
    func detach() { promptCache = nil; active = false; receive = nil; requestReceive = nil; scope = nil; syncTask?.cancel(); syncTask = nil; cloud?.invalidate() }
    private var publishChanges: Bool { cloudEnabled || store.scope.projectID != "daily-local" }
    func listen(uid: String, receive: @escaping @MainActor @Sendable ([WorkspaceRecord]?, Bool, Bool, String?) -> Void) throws {
        guard uid == store.scope.uid else { throw WorkspaceRequestError.accountChanged }
        active = true; self.receive = receive; emit()
        // Bootstrap is explicit at connection time. Reopening screens never queries the cloud.
    }
    func listenRequests(scope: WorkspaceRequestScope, receive: @escaping @MainActor @Sendable ([WorkspaceAnalysisRequest]?, Bool, Bool, String?) -> Void) throws {
        guard scope.uid == store.scope.uid else { throw WorkspaceRequestError.accountChanged }
        self.scope = scope; requestReceive = receive
        receive([], false, false, nil)
        // Server queues are refreshed only explicitly / after a request, never on tab navigation.
    }
    private func check(_ request: WorkspaceRequestScope) throws {
        guard active, !store.resetPending, scope == request, request.uid == store.scope.uid else { throw WorkspaceRequestError.accountChanged }
    }
    private func emit() { if active { receive?(store.resetPending ? [] : store.records(), false, false, nil) } }
    func beginReset(authorizedCloud: (any WorkspaceCloudClient)? = nil) async throws {
        guard active else { throw WorkspaceRequestError.accountChanged }
        await suspendPublication()
        guard active else { throw WorkspaceRequestError.accountChanged }
        do { try store.beginReset() }
        catch { resumePublication(); throw error }
        emit(); onSyncStateChange?()
        // Local data is retained behind the fence until remote deletion succeeds.
        try await (authorizedCloud ?? cloud)?.eraseWorkspace()
    }
    func finishReset() throws {
        try store.finishReset()
        promptCache = nil
        cloudFingerprint = ""; syncNotice = ""; syncConflict = false
        publicationSuspended = false
        emit(); onSyncStateChange?()
    }
    func retryLocalProjection() { emit() }
    func suspendPublication() async {
        publicationSuspended = true
        if let task = syncTask { await task.value }
    }
    func resumePublication() { publicationSuspended = false; scheduleSync() }
    private func changed() { emit(); onSyncStateChange?(); scheduleSync() }
    func scheduleSync() {
        guard !store.resetPending, !publicationSuspended, cloud != nil, active, syncTask == nil, store.pendingCount > 0 else { return }
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.syncTask = nil; self.onSyncStateChange?() }
            do { try await self.flush() }
            catch {
                if self.active {
                    self.syncNotice = error.localizedDescription
                    self.syncConflict = (error as? WorkspaceSyncError) == .conflict || (error as? WorkspaceError) == .conflict
                }
            }
        }
    }
    private func flush() async throws {
        guard !store.resetPending else { throw WorkspaceError.conflict }
        guard let cloud else { return }
        while active, let next = store.firstPublication() {
            try Task.checkCancellation()
            try await cloud.publish(next)
            guard active else { throw WorkspaceRequestError.accountChanged }
            try store.acknowledge(next); cloudVerified = true
        }
        syncNotice = ""
        syncConflict = false
        cloudFingerprint = (store.record("note:companion/sync-revision.json")?.hash ?? "") + (store.record(PhoneAnalysisCommit.manifestKey)?.hash ?? "")
        onSyncStateChange?()
    }
    func synchronize(force: Bool = false) async throws {
        guard !store.resetPending else { throw WorkspaceError.conflict }
        guard let cloud else { return }
        if let task = syncTask { await task.value }
        if store.pendingCount > 0 { try await flush() }
        async let marker = cloud.read("note:companion/sync-revision.json")
        async let manifest = cloud.read(PhoneAnalysisCommit.manifestKey)
        let revision = try await (marker, manifest)
        guard active, !store.resetPending else { throw WorkspaceRequestError.accountChanged }
        cloudVerified = true; onSyncStateChange?()
        let fingerprint = (revision.0?.hash ?? "") + (revision.1?.hash ?? "")
        guard active else { throw WorkspaceRequestError.accountChanged }
        guard force || (cloudFingerprint != nil && cloudFingerprint != fingerprint) else { cloudFingerprint = fingerprint; return }
        let remote = try await cloud.snapshot()
        guard active else { throw WorkspaceRequestError.accountChanged }
        try store.importCloud(remote); cloudFingerprint = fingerprint; emit()
    }
    func bootstrap(importing local: DeviceWorkspaceStore? = nil) async throws {
        guard !store.resetPending else { return }
        guard let cloud else { return }
        if store.pendingCount > 0 { try await flush() }
        let remote = try await cloud.snapshot()
        guard active else { throw WorkspaceRequestError.accountChanged }
        if remote.isEmpty, let local, !local.records().isEmpty, store.records().isEmpty {
            try store.copyDeviceWorkspace(from: local); try store.queueCurrentRecords(); try await flush()
        } else { try store.importCloud(remote) }
        cloudVerified = true
        cloudFingerprint = (store.record("note:companion/sync-revision.json")?.hash ?? "") + (store.record(PhoneAnalysisCommit.manifestKey)?.hash ?? "")
    }
    func useCloudVersion(preservingIn backup: DeviceWorkspaceStore) async throws {
        guard let cloud else { throw WorkspaceSyncError.cloudRequired }
        if let task = syncTask { await task.value }
        let remote = try await cloud.snapshot()
        guard active else { throw WorkspaceRequestError.accountChanged }
        try store.useCloudRecords(remote, preservingIn: backup)
        syncNotice = ""; syncConflict = false; cloudVerified = true
        cloudFingerprint = (store.record("note:companion/sync-revision.json")?.hash ?? "") + (store.record(PhoneAnalysisCommit.manifestKey)?.hash ?? "")
        emit(); onSyncStateChange?()
    }
    func fetchJournals(uid: String) async throws -> [WorkspaceRecord] {
        guard uid == store.scope.uid else { throw WorkspaceRequestError.accountChanged }
        if cloud != nil { try await synchronize(force: true) }
        return store.records().filter { $0.kind == .journal }
    }
    func fetch(uid: String, date: String) async throws -> WorkspaceRecord? {
        guard uid == store.scope.uid else { throw WorkspaceRequestError.accountChanged }
        return store.record("journal:" + date)
    }
    func save(uid: String, date: String, expectedHash: String?, text: String?, answers: [String: DraftAnswer],
              closeQuestionSession: Bool = false, closedQuestionIDs: [String] = [], restoring: WorkspaceRecord? = nil) async throws -> WorkspaceRecord {
        guard uid == store.scope.uid else { throw WorkspaceRequestError.accountChanged }
        let plan = try WorkspaceSavePlanner.plan(current: store.record("journal:" + date), expectedHash: expectedHash,
            date: date, text: text, answers: answers, now: CompanionCard.timestamp(Date()), newID: UUID().uuidString.lowercased(),
            closeQuestionSession: closeQuestionSession, closedQuestionIDs: closedQuestionIDs, restoring: restoring)
        try store.apply([plan.record], expected: [WorkspaceExpected(key: plan.record.key, hash: expectedHash)], publish: publishChanges)
        changed(); return plan.record
    }
    func rememberSavedRecords(_ records: [WorkspaceRecord], uid: String) throws { /* Store owns persistence; model projections never replace it. */ }
    func rememberMemoryEdit(_ records: [WorkspaceRecord], uid: String) throws { }
    func acceptCommittedAnalysis(_ plan: PhoneAnalysisCommit, scope: WorkspaceRequestScope) throws { try check(scope); emit() }
    func refreshPeriodicallyAfterAnalysis(_ plan: PhoneAnalysisCommit, scope: WorkspaceRequestScope) async throws {
        try check(scope); scheduleSync() // No journal-count-based full reread.
    }
    func fetchAnalysisPrompts(scope: WorkspaceRequestScope) async throws -> AnalysisPromptConfiguration {
        try check(scope)
        guard let cloud else { return .bundled }
        do {
            // Prompt documents are independent of workspace data. The sync and its CAS checks
            // still run on every analysis, including when the instructions are already cached.
            async let instructions = recentPrompts(cloud, scope: scope)
            try await synchronize()
            let config = try await instructions
            try check(scope)
            return config
        } catch {
            try check(scope)
            try Task.checkCancellation()
            if syncConflict || (error as? WorkspaceSyncError) == .conflict || (error as? WorkspaceError) == .conflict {
                throw WorkspaceSyncError.conflict
            }
            if error is WorkspaceRequestError || error is AnalysisPromptConfigurationError ||
                (error as? WorkspaceSyncError) == .disconnected { throw error }
            if let connectionError = error as? WorkspaceConnectionError, case .accountChanged = connectionError { throw error }
            syncNotice = error.localizedDescription
            return .bundled
        }
    }
    private func recentPrompts(_ cloud: any WorkspaceCloudClient, scope: WorkspaceRequestScope) async throws -> AnalysisPromptConfiguration {
        if let cached = promptCache, cached.scope == scope, ContinuousClock.now < cached.expires { return cached.config }
        let config = try await cloud.prompts()
        try Task.checkCancellation()
        try check(scope)
        promptCache = (scope, config, ContinuousClock.now.advanced(by: .seconds(60)))
        return config
    }
    func fetchMemory(scope: WorkspaceRequestScope) async throws -> (PortableMemory?, WorkspaceRecord?) {
        try check(scope)
        if let result = try? store.memory(), let manifest = result.1 {
            if result.0 != nil { return result }
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let memories = try MemoryStore(root: root.appendingPathComponent("DailyXMemory", isDirectory: true))
            if let local = try await memories.load(scope: store.scope), let text = try manifest.payload().string,
               try JSONValue.parse(text).object?["memoryHash"]?.string == local.contentHash { return (local, manifest) }
            return result
        }
        guard let cloud, let manifest = try await cloud.read(PhoneAnalysisCommit.manifestKey),
              let text = try manifest.payload().string, let refs = try JSONValue.parse(text).object?["chunks"]?.array else { return try store.memory() }
        var chunks: [WorkspaceRecord] = []
        for ref in refs {
            guard let key = ref.object?["key"]?.string, let chunk = try await cloud.read(key) else { throw WorkspaceError.malformedRecord }
            try check(scope); chunks.append(chunk)
        }
        try store.apply([manifest], expected: [WorkspaceExpected(key: manifest.key, hash: store.record(manifest.key)?.hash)], chunks: chunks, publish: false)
        return try store.memory()
    }
    func fetchMemoryManifest(_ manifest: WorkspaceRecord, scope: WorkspaceRequestScope) async throws -> PortableMemory? {
        try check(scope)
        if let local = try? store.memory(manifest: manifest).0 { return local }
        guard let cloud, let text = try manifest.payload().string, let refs = try JSONValue.parse(text).object?["chunks"]?.array else { throw WorkspaceError.malformedRecord }
        var chunks: [WorkspaceRecord] = []
        for ref in refs {
            guard let key = ref.object?["key"]?.string, let record = try await cloud.read(key) else { throw WorkspaceError.malformedRecord }
            try check(scope); chunks.append(record)
        }
        try store.apply([], expected: [], chunks: chunks, publish: false)
        return try PhoneAnalysisCommit.decodeMemory(manifest: manifest, chunks: chunks)
    }
    func commitAnalysis(_ plan: PhoneAnalysisCommit, scope: WorkspaceRequestScope) async throws {
        try check(scope); try store.commitAnalysis(plan, publish: publishChanges); changed()
    }
    func commitMemoryEdit(_ plan: WorkspaceMemoryMutation, scope: WorkspaceRequestScope) async throws {
        try check(scope); try store.commitMemoryEdit(plan, publish: publishChanges); changed()
    }
    func immutable(_ record: WorkspaceRecord, scope: WorkspaceRequestScope) async throws {
        try check(scope)
        if let old = store.record(record.key) { guard old == record else { throw WorkspaceError.conflict }; return }
        try store.apply([record], expected: [WorkspaceExpected(key: record.key, hash: nil)], publish: publishChanges); changed()
    }
    func saveMapLinkJournal(scope: WorkspaceRequestScope, record: WorkspaceRecord, expectedHash: String?, cards: [WorkspaceRecord]) async throws -> WorkspaceRecord {
        try check(scope)
        try store.apply([record] + cards, expected: [WorkspaceExpected(key: record.key, hash: expectedHash)], publish: publishChanges)
        changed(); return record
    }
    func saveSocialProfile(_ profile: SocialProfile, expectedHash: String?, scope: WorkspaceRequestScope) async throws -> WorkspaceRecord {
        try check(scope)
        let text = String(decoding: try JSONEncoder().encode(profile.validated()), as: UTF8.self)
        let record = try WorkspaceRecord.make(key: SocialProfile.key, kind: .note, payload: .string(text))
        try store.apply([record], expected: [WorkspaceExpected(key: record.key, hash: expectedHash)], publish: publishChanges)
        changed(); return record
    }
    func fetchProfileResearch(key: String, scope: WorkspaceRequestScope) async throws -> WorkspaceRecord? {
        try check(scope); guard key.hasPrefix(ProfileResearchSource.prefix) else { throw WorkspaceError.invalidAddress }
        if let local = store.record(key) { return local }; return try await cloud?.read(key)
    }
    func fetchTaskReport(key: String, scope: WorkspaceRequestScope) async throws -> String {
        try check(scope)
        guard key.hasPrefix("note:dailyx/tasks/") else { throw WorkspaceError.invalidAddress }
        let record: WorkspaceRecord?
        if let local = store.record(key) { record = local } else { record = try await cloud?.read(key) }
        try check(scope)
        guard let record, let text = try record.payload().string,
              let result = try JSONValue.parse(text).object?["result"] else { throw WorkspaceError.malformedRecord }
        return try result.canonical()
    }
    func recordExperience(_ event: ExperienceEvent, scope: WorkspaceRequestScope) async throws -> WorkspaceRecord {
        try check(scope)
        let old = store.record(WorkspaceExperience.key)
        let record = try WorkspaceExperience(record: old).recording(event).record()
        try store.apply([record], expected: [WorkspaceExpected(key: record.key, hash: old?.hash)], publish: publishChanges)
        changed(); return record
    }
    func atlasPage(_ ref: MobileAtlas.PageReference, scope: WorkspaceRequestScope) async throws -> WorkspaceRecord {
        try check(scope)
        if let stored = store.record(ref.key), stored.hash == ref.hash { return stored }
        if let stored = store.version(key: ref.key, hash: ref.hash) { return stored }
        if let current = try await cloud?.read(ref.key), current.hash == ref.hash {
            try check(scope)
            return current
        }
        return try await fetchVersion(key: ref.key, hash: ref.hash, scope: scope)
    }
    func fetchVersion(key: String, hash: String, scope: WorkspaceRequestScope) async throws -> WorkspaceRecord {
        try check(scope)
        if let record = store.version(key: key, hash: hash) { return record }
        guard let cloud else { throw WorkspaceError.malformedRecord }; return try await cloud.version(key: key, hash: hash)
    }
    func saveNotificationLimit(_ limit: Int, hour: Int, scope: WorkspaceRequestScope) async throws -> WorkspaceRecord {
        try check(scope); guard (1...5).contains(limit), (8...21).contains(hour) else { throw WorkspaceError.malformedRecord }
        let key = "note:companion/preferences.md", old = store.record("note:companion/preferences.md")
        var row = try old.flatMap { try $0.payload().string }.flatMap { try JSONValue.parse($0).object } ?? [:]
        row["enabled"] = .bool(true); row["dailyLimit"] = .number(Double(limit)); row["hour"] = .number(Double(hour))
        let record = try WorkspaceRecord.make(key: key, kind: .note, payload: .string(JSONValue.object(row).canonical()))
        try store.apply([record], expected: [WorkspaceExpected(key: key, hash: old?.hash)], publish: publishChanges)
        changed(); return record
    }
    func publishNativePush(scope: WorkspaceRequestScope, deviceID: String, keys: Set<String>, checkingCapability: Bool = false) async throws {
        try check(scope)
        guard let cloud else { throw WorkspaceSyncError.cloudRequired }
        if checkingCapability {
            let heartbeat = try await cloud.read("note:companion/push-service.json")
            guard let text = try heartbeat?.payload().string,
                  let config = try JSONValue.parse(text).object,
                  config["bundleID"]?.string == Bundle.main.bundleIdentifier,
                  config["capabilities"]?.array?.contains(.string("agenda-native-device-v1")) == true else {
                throw NativePushFailure.workerUpdate
            }
        }
        let key = "note:companion/native-push/" + deviceID + ".json"
        let previous = try await cloud.read(key)
        try check(scope)
        if keys.isEmpty && previous == nil { return }
        let payload = try JSONValue.array(keys.sorted().map(JSONValue.string)).canonical()
        let record = try WorkspaceRecord.make(key: key, kind: .note, payload: .string(payload))
        guard previous?.hash != record.hash else { return }
        try await cloud.publish(WorkspacePublication(id: UUID().uuidString.lowercased(), records: [record],
            expected: [WorkspaceExpected(key: key, hash: previous?.hash)], chunks: []))
        try check(scope)
    }
    func registerPush(scope: WorkspaceRequestScope, deviceID: String, token: String?, environment: String) async throws {
        try check(scope); guard let cloud else { throw WorkspaceSyncError.cloudRequired }
        try await cloud.registerPush(deviceID: deviceID, token: token, environment: environment)
    }
    func enqueue(scope: WorkspaceRequestScope, source: WorkspaceRecord, kind: WorkspaceAnalysisKind) async throws -> String {
        try check(scope); guard let cloud else { throw WorkspaceSyncError.cloudRequired }
        if let task = syncTask { await task.value }; try await flush()
        try check(scope)
        let id = try await cloud.enqueue(source: source, kind: kind)
        try check(scope)
        let requests = try await cloud.analysisRequests()
        try check(scope); requestReceive?(requests, false, false, nil)
        return id
    }
    func sendCommand(scope: WorkspaceRequestScope, command: PhoneCommand) async throws {
        try check(scope); guard cloudEnabled else { throw WorkspaceSyncError.cloudRequired }
        try await immutable(command.record(), scope: scope)
    }
    func respondCompanion(scope: WorkspaceRequestScope, card: WorkspaceRecord, event: CompanionEvent) async throws {
        try check(scope)
        let decoded = try CompanionCard.decode(card)
        guard store.record(card.key) == card, decoded.id == event.cardId, decoded.withdrawn != true,
              (CompanionCard.date(decoded.expiresAt) ?? .distantPast) > Date(),
              event.action != "done" || decoded.kind == "deadline" else { throw WorkspaceError.conflict }
        let record = try event.record()
        if let old = store.record(record.key) { guard old == record else { throw WorkspaceError.conflict }; return }
        var updates = [record]
        var expected = [WorkspaceExpected(key: card.key, hash: card.hash), WorkspaceExpected(key: record.key, hash: nil)]
        if event.action == "answer" {
            let date = try CompanionReplyPlanner.date(event)
            let old = store.record("journal:" + date)
            updates.append(try CompanionReplyPlanner.plan(current: old, card: CompanionCard.decode(card), event: event))
            expected.append(WorkspaceExpected(key: "journal:" + date, hash: old?.hash))
        }
        try store.apply(updates, expected: expected, publish: publishChanges); changed()
    }
}
