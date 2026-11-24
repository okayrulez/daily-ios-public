import Foundation
import DailyCore
@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseCore
@preconcurrency import FirebaseFirestore

enum WorkspaceConnectionError: Error { case accountChanged, rejected, offline }

@MainActor
final class FirebaseWorkspace {
    let database: Firestore
    private var listeners: [ListenerRegistration] = []
    private var recordGeneration = UUID()
    private var recordParts: [Int: [WorkspaceRecord]] = [:]
    private var recordMetadata: [Int: (cached: Bool, pending: Bool)] = [:]
    private var atlasRequest = UUID()
    private var atlasRecords: [WorkspaceRecord] = []
    private var atlasLoadingHash: String?
    private var atlasReceive: (@MainActor @Sendable ([WorkspaceRecord]?, Bool, Bool, String?) -> Void)?
    private var requestListener: ListenerRegistration?
    let requestGate = WorkspaceRequestSessionGate()

    init() {
        database = Firestore.firestore()
        let settings = database.settings
        // Drafts are separately durable and UID-scoped. Do not persist shared SDK query caches.
        settings.cacheSettings = MemoryCacheSettings(garbageCollectorSettings: MemoryLRUGCSettings())
        database.settings = settings
    }

    /// Online transaction; no queued device registration can outlive the account session.
    func registerPush(scope: WorkspaceRequestScope, deviceID: String, token: String?, environment: String) async throws {
        let gate = requestGate
        guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid),
              ["development", "production"].contains(environment) else { throw WorkspaceConnectionError.accountChanged }
        let ref = database.collection("users").document(scope.uid).collection("dailyXPushDevices").document(deviceID)
        let now = Date()
        let updated = CompanionCard.timestamp(now), expires = CompanionCard.timestamp(now.addingTimeInterval(7 * 86400))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.runPushTransaction(database: database, reference: ref, gate: gate, scope: scope, token: token,
                                    environment: environment, updated: updated, expires: expires,
                                    continuation: continuation)
        }
    }

    nonisolated private static func runPushTransaction(
        database: Firestore, reference: DocumentReference, gate: WorkspaceRequestSessionGate,
        scope: WorkspaceRequestScope, token: String?, environment: String,
        updated: String, expires: String, continuation: CheckedContinuation<Void, Error>
    ) {
        database.runTransaction({ transaction, errorPointer -> Any? in
            do {
                guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceConnectionError.accountChanged }
                _ = try transaction.getDocument(reference)
                if let token {
                    transaction.setData(["schemaVersion": 1, "transport": "apns", "token": token,
                        "environment": environment, "enabled": true, "updatedAt": updated, "expiresAt": expires], forDocument: reference)
                } else { transaction.deleteDocument(reference) }
                return true
            } catch { errorPointer?.pointee = error as NSError; return nil }
        }, completion: { _, error in
            if let error { continuation.resume(throwing: error) }
            else if !gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) { continuation.resume(throwing: WorkspaceConnectionError.accountChanged) }
            else { continuation.resume() }
        })
    }

    func detach() {
        listeners.forEach { $0.remove() }; listeners = []
        recordGeneration = UUID(); atlasRequest = UUID(); atlasLoadingHash = nil; atlasReceive = nil; atlasRecords = []; recordParts = [:]; recordMetadata = [:]
        requestListener?.remove(); requestListener = nil
        requestGate.invalidate()
    }

    func listen(uid: String, receive: @escaping @MainActor @Sendable ([WorkspaceRecord]?, Bool, Bool, String?) -> Void) throws {
        detach()
        let path = try WorkspaceIdentity.recordsPath(uid: uid)
        let generation = recordGeneration
        _ = path
        atlasRecords = loadAtlasCache(uid: uid)
        recordParts[3] = atlasRecords
        recordMetadata[3] = (false, false)
        atlasReceive = receive
        let file = workspaceCacheURL(uid: uid)
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([WorkspaceRecord].self, from: data) {
            recordParts[0] = saved
            recordMetadata[0] = (false, false)
            receive(saved + atlasRecords, false, false, nil)
        } else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.refreshWorkspaceSnapshot(uid: uid, generation: generation) }
                catch {
                    guard self.recordGeneration == generation, Auth.auth().currentUser?.uid == uid else { return }
                    receive(nil, false, false, WorkspaceConnectionDiagnostic.firestore(error))
                }
            }
        }
        // Bootstrap once on a new device. Reopening never checks the remote atlas index.
        if !FileManager.default.fileExists(atPath: atlasCacheURL(uid: uid).path) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.fetchAtlasSnapshot(uid: uid, generation: generation) }
                catch {
                    guard self.recordGeneration == generation, Auth.auth().currentUser?.uid == uid else { return }
                    receive(nil, false, false, WorkspaceConnectionDiagnostic.firestore(error))
                }
            }
        }
    }

    /// Manual refresh remains available; opening a map never invokes this method.
    func repositorySnapshot(scope: WorkspaceRequestScope) async throws -> [WorkspaceRecord] {
        if atlasReceive == nil { atlasReceive = { _, _, _, _ in } }
        try await refreshAtlasAfterAnalysis(scope: scope)
        var result = (recordParts[0] ?? []) + atlasRecords
        let root = database.collection(try WorkspaceIdentity.recordsPath(uid: scope.uid))
        let manifest = try await root.document(WorkspaceHash.sha256(PhoneAnalysisCommit.manifestKey)).getDocument(source: .server)
        if let fields = manifest.data() {
            let record = try Self.decode(fields, documentID: manifest.documentID)
            result.append(record)
            if let text = try record.payload().string, let refs = try JSONValue.parse(text).object?["chunks"]?.array {
                for ref in refs {
                    guard requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid), let key = ref.object?["key"]?.string else { throw WorkspaceRequestError.accountChanged }
                    let snapshot = try await root.document(WorkspaceHash.sha256(key)).getDocument(source: .server)
                    guard let data = snapshot.data() else { throw WorkspaceError.malformedRecord }
                    result.append(try Self.decode(data, documentID: snapshot.documentID))
                }
            }
        }
        return Array(Dictionary(result.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }).values)
    }

    func refreshAtlasAfterAnalysis(scope: WorkspaceRequestScope) async throws {
        guard requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else {
            throw WorkspaceConnectionError.accountChanged
        }
        try await refreshWorkspaceSnapshot(uid: scope.uid, generation: recordGeneration)
        try await fetchAtlasSnapshot(uid: scope.uid, generation: recordGeneration)
    }

    /// Apply the exact committed payload, without reading journals or atlas pages back from Firestore.
    func acceptCommittedAnalysis(_ plan: PhoneAnalysisCommit, scope: WorkspaceRequestScope) throws {
        guard requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceConnectionError.accountChanged }
        var current = Dictionary(uniqueKeysWithValues: (recordParts[0] ?? []).map { ($0.documentID, $0) })
        if let currentManifest = current[plan.manifest.documentID],
           let text = try currentManifest.payload().string,
           let revision = try JSONValue.parse(text).object?["revision"]?.integer, revision > plan.memory.revision {
            // Lost acknowledgement of an older receipt must not roll back a newer local view.
            return
        }
        for record in [plan.journal, plan.manifest, plan.receipt] + plan.atlas where !record.key.hasPrefix("note:companion/atlas/") {
            if record.key == plan.journal.key, let newer = current[record.documentID],
               newer.hash != plan.source.hash && newer.hash != plan.journal.hash { continue }
            current[record.documentID] = record
        }
        let pages = plan.atlas.filter { $0.key.hasPrefix("note:companion/atlas/") }
        let atlas = pages.contains(where: { $0.key == "note:companion/atlas/index.md" }) ? pages : atlasRecords
        // Publish memory first: even a device-file failure cannot hide a successful cloud commit.
        atlasRecords = atlas; recordParts[3] = atlas; recordMetadata[3] = (false, false)
        recordParts[0] = Array(current.values); recordMetadata[0] = (false, false)
        atlasReceive?(Array(current.values) + atlas, false, false, nil)
        try rememberMemoryEdit(Array(current.values) + atlas, uid: scope.uid)
    }

    func refreshPeriodicallyAfterAnalysis(_ plan: PhoneAnalysisCommit, scope: WorkspaceRequestScope) async throws {
        let file = atlasCacheURL(uid: scope.uid).appendingPathExtension("sync.json")
        var policy = (try? JSONDecoder().decode(WorkspaceRefreshPolicy.self, from: Data(contentsOf: file))) ?? WorkspaceRefreshPolicy()
        if !plan.source.isProfileResearch, let source = try? plan.source.journal(), source.analyses.isEmpty,
           (try? plan.journal.journal().analyses.isEmpty) == false { policy.completedNewJournal(source.id) }
        // Keep the pending count on failure; a retry never repeats inference.
        try JSONEncoder().encode(policy).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard policy.isDue() else { return }
        try await refreshAtlasAfterAnalysis(scope: scope)
        policy.didSync()
        try JSONEncoder().encode(policy).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func fetchAtlasSnapshot(uid: String, generation: UUID) async throws {
        guard recordGeneration == generation, Auth.auth().currentUser?.uid == uid,
              let receive = atlasReceive else { throw WorkspaceConnectionError.accountChanged }
        let root = database.collection(try WorkspaceIdentity.recordsPath(uid: uid))
        let snapshot = try await root.document(WorkspaceHash.sha256("note:companion/atlas/index.md")).getDocument(source: .server)
        guard recordGeneration == generation, Auth.auth().currentUser?.uid == uid else {
            throw WorkspaceConnectionError.accountChanged
        }
        let index = try snapshot.data().map { try Self.decode($0, documentID: snapshot.documentID) }
        if let index, atlasRecords.first(where: { $0.key == index.key })?.hash == index.hash { return }
        try await refreshAtlas(index: index, root: root, uid: uid, generation: generation,
                               cached: false, pending: false, receive: receive)
    }

    private func workspaceCacheURL(uid: String) -> URL {
        atlasCacheURL(uid: uid).deletingPathExtension().appendingPathExtension("workspace.json")
    }

    private func refreshWorkspaceSnapshot(uid: String, generation: UUID) async throws {
        let root = database.collection(try WorkspaceIdentity.recordsPath(uid: uid))
        let queries = [root.whereField("kind", isEqualTo: "journal"),
            root.whereField("key", isGreaterThanOrEqualTo: "note:companion/").whereField("key", isLessThan: "note:companion/atlas/"),
            root.whereField("key", isGreaterThanOrEqualTo: "note:companion/atlas0").whereField("key", isLessThan: "note:companion/changes/"),
            root.whereField("key", isGreaterThanOrEqualTo: "note:companion/changes0").whereField("key", isLessThan: "note:companion0"),
            root.whereField("key", isGreaterThanOrEqualTo: "note:companion/changes/").whereField("key", isLessThan: "note:companion/changes0").order(by:"key",descending:true).limit(to:50)]
        var fresh: [WorkspaceRecord] = []
        for query in queries {
            let snapshot = try await query.getDocuments(source: .server)
            for document in snapshot.documents { fresh.append(try await decodeRemote(document)) }
        }
        guard recordGeneration == generation, Auth.auth().currentUser?.uid == uid else { throw WorkspaceConnectionError.accountChanged }
        try persistWorkspace(fresh, uid: uid)
        recordParts[0] = fresh; recordMetadata[0] = (false, false)
        atlasReceive?(fresh + atlasRecords, false, false, nil)
    }

    private func persistWorkspace(_ records: [WorkspaceRecord], uid: String) throws {
        let file = workspaceCacheURL(uid: uid)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func rememberSavedRecords(_ records: [WorkspaceRecord], uid: String) throws {
        guard Auth.auth().currentUser?.uid == uid else { throw WorkspaceConnectionError.accountChanged }
        let fresh = records.filter { !$0.key.hasPrefix("note:companion/atlas/") }
        try persistWorkspace(fresh, uid: uid)
        recordParts[0] = fresh
    }

    func rememberMemoryEdit(_ records: [WorkspaceRecord], uid: String) throws {
        try rememberSavedRecords(records,uid:uid)
        let next=records.filter { $0.key.hasPrefix("note:companion/atlas/") }
        let file=atlasCacheURL(uid:uid)
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(next).write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        atlasRecords=next;recordParts[3]=next;recordMetadata[3]=(false,false)
    }

    private func atlasCacheURL(uid: String) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DailyXAtlasCache", isDirectory: true)
        // Firestore's owning app is authoritative, including when a user supplies another project.
        return folder.appendingPathComponent(WorkspaceRefreshPolicy.cacheIdentity(projectID: database.app.options.projectID ?? database.app.name, uid: uid) + ".json")
    }

    private func loadAtlasCache(uid: String) -> [WorkspaceRecord] {
        guard let data = try? Data(contentsOf: atlasCacheURL(uid: uid)),
              let stored = try? JSONDecoder().decode([WorkspaceRecord].self, from: data),
              let checked = try? stored.map({ try WorkspaceRecord(json: $0.json) }),
              let atlas = try? MobileAtlas.load(records: checked) else { return [] }
        for map in atlas.maps {
            guard (try? MobileAtlas.graph(for: map, records: checked)) != nil,
                  (try? MobileAtlas.notes(for: map, records: checked)) != nil else { return [] }
        }
        return checked
    }

    private func refreshAtlas(index: WorkspaceRecord?, root: CollectionReference, uid: String,
                              generation: UUID, cached: Bool, pending: Bool,
                              receive: @escaping @MainActor @Sendable ([WorkspaceRecord]?, Bool, Bool, String?) -> Void) async throws {
        // Cached or locally pending manifests must not replace the durable server snapshot.
        guard !cached && !pending else { return }
        let revision = index?.hash ?? "missing"
        guard atlasLoadingHash != revision else { return }
        let request = UUID(); atlasRequest = request; atlasLoadingHash = revision
        defer { if atlasRequest == request { atlasLoadingHash = nil } }
        do {
            var next: [WorkspaceRecord] = []
            if let index, let atlas = try MobileAtlas.load(records: [index]) {
                next = [index]
                for reference in atlas.maps.flatMap({ $0.pages + ($0.detailPages ?? []) }) {
                    guard recordGeneration == generation, atlasRequest == request,
                          Auth.auth().currentUser?.uid == uid else { return }
                    if let saved = atlasRecords.first(where: { $0.key == reference.key && $0.hash == reference.hash }) {
                        next.append(saved); continue
                    }
                    let doc = try await root.document(WorkspaceHash.sha256(reference.key)).getDocument(source: .server)
                    guard let fields = doc.data() else { throw WorkspaceError.conflict }
                    let item = try Self.decode(fields, documentID: doc.documentID)
                    guard item.hash == reference.hash else { throw WorkspaceError.conflict }
                    next.append(item)
                }
                for map in atlas.maps {
                    _ = try MobileAtlas.graph(for: map, records: next)
                    _ = try MobileAtlas.notes(for: map, records: next)
                }
            }
            guard recordGeneration == generation, atlasRequest == request,
                  Auth.auth().currentUser?.uid == uid else { return }
            atlasRecords = next; recordParts[3] = next; recordMetadata[3] = (cached, pending)
            if !cached && !pending {
                let file = atlasCacheURL(uid: uid)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            if recordParts[0] != nil {
                receive((0..<4).flatMap { recordParts[$0] ?? [] }, recordMetadata.values.contains { $0.cached },
                        recordMetadata.values.contains { $0.pending }, nil)
            }
        } catch {
            guard recordGeneration == generation, atlasRequest == request, Auth.auth().currentUser?.uid == uid else { return }
            throw error
        }
    }

    func fetchJournals(uid: String) async throws -> [WorkspaceRecord] {
        guard Auth.auth().currentUser?.uid == uid else { throw WorkspaceConnectionError.accountChanged }
        let snapshot = try await database.collection(WorkspaceIdentity.recordsPath(uid: uid))
            .whereField("kind", isEqualTo: "journal").getDocuments(source: .server)
        guard Auth.auth().currentUser?.uid == uid else { throw WorkspaceConnectionError.accountChanged }
        var records: [WorkspaceRecord] = []
        for document in snapshot.documents { records.append(try await decodeRemote(document)) }
        return records
    }

    func fetch(uid: String, date: String) async throws -> WorkspaceRecord? {
        guard Auth.auth().currentUser?.uid == uid else { throw WorkspaceConnectionError.accountChanged }
        let reference = database.collection(try WorkspaceIdentity.recordsPath(uid: uid))
            .document(WorkspaceHash.sha256("journal:\(date)"))
        let snapshot = try await reference.getDocument(source: .server)
        guard Auth.auth().currentUser?.uid == uid else { throw WorkspaceConnectionError.accountChanged }
        guard snapshot.exists else { return nil }
        return try await decodeRemote(snapshot)

    }

    func listenRequests(scope: WorkspaceRequestScope,
                        receive: @escaping @MainActor @Sendable ([WorkspaceAnalysisRequest]?, Bool, Bool, String?) -> Void) throws {
        requestListener?.remove(); requestListener = nil
        let path = try WorkspaceAnalysisRequest.path(uid: scope.uid)
        let gate = requestGate
        gate.activate(scope)
        database.collection(path).getDocuments(source: .server) { snapshot, error in
            guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { return }
            guard error == nil, let snapshot else {
                let diagnostic = WorkspaceConnectionDiagnostic.firestore(error)
                Task { @MainActor in
                    guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { return }
                    receive(nil, false, false, diagnostic)
                }
                return
            }
            do {
                let requests = try snapshot.documents.map { try Self.decodeRequest($0.data(), documentID: $0.documentID) }
                let cached = snapshot.metadata.isFromCache
                let pending = snapshot.metadata.hasPendingWrites
                Task { @MainActor in
                    guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { return }
                    receive(requests, cached, pending, nil)
                }
            } catch {
                let diagnostic = WorkspaceConnectionDiagnostic.firestore(error)
                Task { @MainActor in
                    guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { return }
                    receive(nil, false, false, diagnostic)
                }
            }
        }
    }

    /// This is the only native request write: explicit, server-acknowledged enqueue.
    /// It never changes workspaceRecords, leases, analyses, questions or answers.
    func enqueue(scope: WorkspaceRequestScope, source: WorkspaceRecord, kind: WorkspaceAnalysisKind) async throws -> String {
        let gate = requestGate
        guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
        let id = try WorkspaceAnalysisRequest.identity(kind: kind, sourceHash: source.hash)
        let sourceReference = database.collection(try WorkspaceIdentity.recordsPath(uid: scope.uid)).document(source.documentID)
        let requestReference = database.collection(try WorkspaceAnalysisRequest.path(uid: scope.uid)).document(id)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            Self.runEnqueueTransaction(database: database, sourceReference: sourceReference,
                                       requestReference: requestReference, gate: gate, scope: scope,
                                       source: source, kind: kind, id: id, continuation: continuation)
        }
    }

    nonisolated private static func runEnqueueTransaction(
        database: Firestore, sourceReference: DocumentReference, requestReference: DocumentReference,
        gate: WorkspaceRequestSessionGate, scope: WorkspaceRequestScope, source: WorkspaceRecord,
        kind: WorkspaceAnalysisKind, id: String, continuation: CheckedContinuation<String, Error>
    ) {
        database.runTransaction({ transaction, errorPointer -> Any? in
            do {
                guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
                let sourceSnapshot = try transaction.getDocument(sourceReference)
                let current = try sourceSnapshot.data().map { try Self.decode($0, documentID: sourceSnapshot.documentID, transaction: transaction, root: sourceReference.parent) }
                let requestSnapshot = try transaction.getDocument(requestReference)
                let oldFields = requestSnapshot.data()
                let existing = try oldFields.map { try Self.decodeRequest($0, documentID: id) }
                let now = Timestamp(date: Date())
                let plan = try WorkspaceRequestPlanner.enqueue(current: current, expected: source, kind: kind,
                                                               existing: existing, now: now.dateValue().timeIntervalSince1970)
                guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
                if let plan {
                    var fields = try Self.requestFields(plan)
                    // Preserve the exact server Timestamp (including nanos) on explicit retry.
                    fields["createdAt"] = oldFields?["createdAt"] ?? now
                    fields["updatedAt"] = now
                    transaction.setData(fields, forDocument: requestReference)
                }
                return id
            } catch {
                let code = (error as? WorkspaceRequestError) == .sourceChanged ? 1 : 2
                errorPointer?.pointee = NSError(domain: "dAIly.WorkspaceRequest", code: code)
                return nil
            }
        }, completion: { result, error in
            guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else {
                continuation.resume(throwing: WorkspaceRequestError.accountChanged); return
            }
            if let error {
                let failure = error as NSError
                continuation.resume(throwing: failure.domain == "dAIly.WorkspaceRequest" && failure.code == 1
                                    ? WorkspaceRequestError.sourceChanged : error)
                return
            }
            guard let result = result as? String, result == id else {
                continuation.resume(throwing: WorkspaceConnectionError.rejected); return
            }
            continuation.resume(returning: result)
        })
    }

    func save(uid: String, date: String, expectedHash: String?, text: String?, answers: [String: DraftAnswer], closeQuestionSession: Bool = false, closedQuestionIDs: [String] = [], restoring: WorkspaceRecord? = nil) async throws -> WorkspaceRecord {
        guard Auth.auth().currentUser?.uid == uid else { throw WorkspaceConnectionError.accountChanged }
        let reference = database.collection(try WorkspaceIdentity.recordsPath(uid: uid))
            .document(WorkspaceHash.sha256("journal:\(date)"))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = formatter.string(from: Date())
        let newID = UUID().uuidString.lowercased()
        let cached = (recordParts[0] ?? []).first { $0.key == "journal:" + date }
        let staged = (text?.utf8.count ?? 0) > 600_000 || (cached?.content.utf8.count ?? 0) > 600_000 || (restoring?.content.utf8.count ?? 0) > 600_000
        if staged {
            let current: WorkspaceRecord?
            if let cached, cached.hash == expectedHash { current = cached }
            else { current = try await fetch(uid: uid, date: date) }
            let plan = try WorkspaceSavePlanner.plan(current: current, expectedHash: expectedHash, date: date, text: text, answers: answers,
                now: now, newID: newID, closeQuestionSession: closeQuestionSession, closedQuestionIDs: closedQuestionIDs, restoring: restoring)
            for chunk in try WorkspaceRecordStorage(plan.record).chunks {
                try await saveImmutableJournalPart(chunk, uid: uid)
            }
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WorkspaceRecord, Error>) in
            Self.runSaveTransaction(database: database, reference: reference, uid: uid, date: date,
                                    expectedHash: expectedHash, text: text, answers: answers,
                                    now: now, newID: newID, closeQuestionSession: closeQuestionSession, closedQuestionIDs: closedQuestionIDs, restoring: restoring, staged: staged, continuation: continuation)
        }
    }

    private func saveImmutableJournalPart(_ part: WorkspaceRecord, uid: String) async throws {
        let ref = database.collection(try WorkspaceIdentity.recordsPath(uid: uid)).document(part.documentID)
        // Content-addressed auxiliary records are harmless until a journal manifest references them.
        guard Auth.auth().currentUser?.uid == uid else { throw WorkspaceConnectionError.accountChanged }
        try await ref.setData(Self.fields(part))
        guard Auth.auth().currentUser?.uid == uid else { throw WorkspaceConnectionError.accountChanged }
    }

    // Firestore invokes the update block on its own concurrent queue. Constructing it
    // inside this nonisolated function prevents Swift 6 from inheriting MainActor
    // isolation from FirebaseWorkspace.save and trapping when Firestore calls it.
    nonisolated private static func runSaveTransaction(
        database: Firestore, reference: DocumentReference, uid: String, date: String,
        expectedHash: String?, text: String?, answers: [String: DraftAnswer],
        now: String, newID: String, closeQuestionSession: Bool, closedQuestionIDs: [String], restoring: WorkspaceRecord?, staged: Bool, continuation: CheckedContinuation<WorkspaceRecord, Error>
    ) {
        database.runTransaction({ transaction, errorPointer -> Any? in
            do {
                guard Auth.auth().currentUser?.uid == uid else { throw WorkspaceConnectionError.accountChanged }
                let snapshot = try transaction.getDocument(reference)
                let current = try snapshot.data().map { try Self.decode($0, documentID: snapshot.documentID, transaction: transaction, root: reference.parent) }
                let plan = try WorkspaceSavePlanner.plan(current: current, expectedHash: expectedHash, date: date,
                                                         text: text, answers: answers, now: now, newID: newID, closeQuestionSession: closeQuestionSession, closedQuestionIDs: closedQuestionIDs, restoring: restoring)
                if let previous = plan.previous {
                    transaction.setData(snapshot.data()!, forDocument: reference.collection("versions").document(previous.hash))
                }
                if staged { transaction.setData(try Self.fields(plan.record), forDocument: reference) }
                else { try Self.write(plan.record, transaction: transaction, reference: reference) }
                return try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan.record))
            } catch {
                let code = (error as? WorkspaceError) == .conflict ? 1 : 2
                errorPointer?.pointee = NSError(domain: "dAIly.Workspace", code: code)
                return nil
            }
        }, completion: { result, error in
            if let error {
                let failure = error as NSError
                continuation.resume(throwing: failure.domain == "dAIly.Workspace" && failure.code == 1 ? WorkspaceError.conflict : error)
                return
            }
            do {
                guard let fields = result as? [String: Any] else { throw WorkspaceConnectionError.rejected }
                continuation.resume(returning: try Self.decode(fields, documentID: WorkspaceHash.sha256("journal:\(date)")))
            } catch { continuation.resume(throwing: error) }
        })
    }

    func saveMapLinkJournal(scope: WorkspaceRequestScope, record: WorkspaceRecord, expectedHash: String?, cards: [WorkspaceRecord]) async throws -> WorkspaceRecord {
        guard requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid), record.kind == .journal else {
            throw WorkspaceConnectionError.accountChanged
        }
        for part in try WorkspaceRecordStorage(record).chunks { try await immutable(part, scope: scope) }
        let root = database.collection(try WorkspaceIdentity.recordsPath(uid: scope.uid))
        return try await withCheckedThrowingContinuation { continuation in
            Self.runMapLinkTransaction(database: database, reference: root.document(record.documentID),
                uid: scope.uid, record: record, expectedHash: expectedHash, cards: cards, continuation: continuation)
        }
    }
    nonisolated private static func runMapLinkTransaction(database: Firestore, reference: DocumentReference,
        uid: String, record: WorkspaceRecord, expectedHash: String?, cards: [WorkspaceRecord],
        continuation: CheckedContinuation<WorkspaceRecord, Error>) {
        database.runTransaction({ transaction, errorPointer -> Any? in
            do {
                guard Auth.auth().currentUser?.uid == uid else { throw WorkspaceConnectionError.accountChanged }
                let snapshot = try transaction.getDocument(reference)
                let current = try snapshot.data().map { try Self.decode($0, documentID: snapshot.documentID, transaction: transaction, root: reference.parent) }
                guard current?.hash == expectedHash else { throw WorkspaceError.conflict }
                if let current { transaction.setData(snapshot.data()!, forDocument: reference.collection("versions").document(current.hash)) }
                transaction.setData(try Self.fields(record), forDocument: reference)
                for card in cards { transaction.setData(try Self.fields(card), forDocument: reference.parent.document(card.documentID)) }
                return true
            } catch {
                errorPointer?.pointee = NSError(domain: "dAIly.MapLinks", code: (error as? WorkspaceError) == .conflict ? 1 : 2)
                return nil
            }
        }, completion: { result, error in
            if let error {
                let failure = error as NSError
                continuation.resume(throwing: failure.domain == "dAIly.MapLinks" && failure.code == 1 ? WorkspaceError.conflict : error)
            } else if result as? Bool == true { continuation.resume(returning: record) }
            else { continuation.resume(throwing: WorkspaceConnectionError.rejected) }
        })
    }

    /// The same immutable ID is retried after a lost network acknowledgement.
    func sendCommand(scope: WorkspaceRequestScope, command: PhoneCommand) async throws {
        let record = try command.record(), gate = requestGate
        guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
        let reference = database.collection(try WorkspaceIdentity.recordsPath(uid: scope.uid)).document(record.documentID)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.runCommandTransaction(database: database, reference: reference, gate: gate, scope: scope, record: record, continuation: continuation)
        }
    }
    nonisolated private static func runCommandTransaction(database: Firestore, reference: DocumentReference,
        gate: WorkspaceRequestSessionGate, scope: WorkspaceRequestScope, record: WorkspaceRecord,
        continuation: CheckedContinuation<Void, Error>) {
        database.runTransaction({ transaction, errorPointer -> Any? in
            do {
                guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
                let existing = try transaction.getDocument(reference)
                if let fields = existing.data() {
                    guard try Self.decode(fields, documentID: record.documentID) == record else { throw WorkspaceError.conflict }
                } else { try Self.write(record, transaction: transaction, reference: reference) }
                return true
            } catch { errorPointer?.pointee = error as NSError; return nil }
        }, completion: { _, error in
            guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { continuation.resume(throwing: WorkspaceRequestError.accountChanged); return }
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }

    /// Append-only reply, bound to both account session and exact displayed card revision.
    func respondCompanion(scope: WorkspaceRequestScope, card: WorkspaceRecord, event: CompanionEvent) async throws {
        let gate = requestGate
        guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
        let decoded = try CompanionCard.decode(card)
        guard decoded.id == event.cardId, decoded.withdrawn != true, (CompanionCard.date(decoded.expiresAt) ?? .distantPast) > Date(), event.action != "done" || decoded.kind == "deadline" else { throw WorkspaceError.invalidAddress }
        let record = try event.record()
        let collection = database.collection(try WorkspaceIdentity.recordsPath(uid: scope.uid))
        let reference = collection.document(record.documentID)
        let cardReference = collection.document(card.documentID)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.runCompanionTransaction(database: database, reference: reference, cardReference: cardReference,
                                         gate: gate, scope: scope, card: card, record: record,
                                         continuation: continuation)
        }
    }

    nonisolated private static func runCompanionTransaction(
        database: Firestore, reference: DocumentReference, cardReference: DocumentReference,
        gate: WorkspaceRequestSessionGate, scope: WorkspaceRequestScope, card: WorkspaceRecord,
        record: WorkspaceRecord, continuation: CheckedContinuation<Void, Error>
    ) {
        database.runTransaction({ transaction, errorPointer -> Any? in
            do {
                guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
                let currentCard = try transaction.getDocument(cardReference)
                let existing = try transaction.getDocument(reference)
                guard let fields = currentCard.data(), try Self.decode(fields, documentID: card.documentID) == card else { throw WorkspaceError.conflict }
                if let fields = existing.data() {
                    guard try Self.decode(fields, documentID: record.documentID) == record else { throw WorkspaceError.conflict }
                } else {
                    let event = try CompanionEvent.decode(record)
                    if event.action == "answer" {
                        let date = try CompanionReplyPlanner.date(event)
                        let journalRef = database.collection(try WorkspaceIdentity.recordsPath(uid: scope.uid))
                            .document(WorkspaceHash.sha256("journal:" + date))
                        let snapshot = try transaction.getDocument(journalRef)
                        let old = try snapshot.data().map { try Self.decode($0, documentID: snapshot.documentID, transaction: transaction, root: journalRef.parent) }
                        let next = try CompanionReplyPlanner.plan(current: old, card: CompanionCard.decode(card), event: event)
                        if let old { transaction.setData(snapshot.data()!, forDocument: journalRef.collection("versions").document(old.hash)) }
                        try Self.write(next, transaction: transaction, reference: journalRef)
                    }
                    try Self.write(record, transaction: transaction, reference: reference)
                }
                return true
            } catch { errorPointer?.pointee = error as NSError; return nil }
        }, completion: { _, error in
            guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { continuation.resume(throwing: WorkspaceRequestError.accountChanged); return }
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }

    nonisolated static func decode(_ fields: [String: Any], documentID: String) throws -> WorkspaceRecord {
        let data = try JSONSerialization.data(withJSONObject: fields)
        return try JSONDecoder().decode(WorkspaceRecord.self, from: data).validated(documentID: documentID)
    }

    nonisolated static func fields(_ record: WorkspaceRecord) throws -> [String: Any] {
        let wire = try WorkspaceRecordStorage(record)
        guard let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire.fields)) as? [String: Any] else { throw WorkspaceError.malformedRecord }
        return fields
    }

    nonisolated static func decode(_ fields: [String: Any], documentID: String, transaction: Transaction, root: CollectionReference) throws -> WorkspaceRecord {
        let value = try JSONValue.parse(String(decoding: JSONSerialization.data(withJSONObject: fields), as: UTF8.self))
        return try WorkspaceRecordStorage.decode(value) { key in
            let snapshot = try transaction.getDocument(root.document(WorkspaceHash.sha256(key)))
            guard let data = snapshot.data() else { throw WorkspaceError.malformedRecord }
            return try Self.decode(data, documentID: snapshot.documentID)
        }.validated(documentID: documentID)
    }

    nonisolated static func write(_ record: WorkspaceRecord, transaction: Transaction, reference: DocumentReference) throws {
        let wire = try WorkspaceRecordStorage(record)
        for chunk in wire.chunks {
            transaction.setData(try Self.fields(chunk), forDocument: reference.parent.document(chunk.documentID))
        }
        transaction.setData(try Self.fields(record), forDocument: reference)
    }

    func decodeRemote(_ snapshot: DocumentSnapshot) async throws -> WorkspaceRecord {
        guard let fields = snapshot.data() else { throw WorkspaceError.malformedRecord }
        let value = try JSONValue.parse(String(decoding: JSONSerialization.data(withJSONObject: fields), as: UTF8.self))
        var parts: [String: WorkspaceRecord] = [:]
        let owner = Auth.auth().currentUser?.uid
        let root = snapshot.reference.parent.collectionID == "versions" ?
            snapshot.reference.parent.parent!.parent : snapshot.reference.parent
        for key in try WorkspaceRecordStorage.references(value) ?? [] {
            if parts[key] != nil { continue }
            let chunk = try await root.document(WorkspaceHash.sha256(key)).getDocument(source: .server)
            guard Auth.auth().currentUser?.uid == owner, let data = chunk.data() else { throw WorkspaceConnectionError.accountChanged }
            parts[key] = try Self.decode(data, documentID: chunk.documentID)
        }
        let identity = snapshot.reference.parent.collectionID == "versions" ? snapshot.reference.parent.parent!.documentID : snapshot.documentID
        return try WorkspaceRecordStorage.decode(value) { key in
            guard let record = parts[key] else { throw WorkspaceError.malformedRecord }; return record
        }.validated(documentID: identity)
    }

    nonisolated static func decodeRequest(_ fields: [String: Any], documentID: String) throws -> WorkspaceAnalysisRequest {
        var normalized = fields
        for key in ["createdAt", "updatedAt", "leaseUntil"] {
            if key == "leaseUntil", fields[key] is NSNull { continue }
            guard let timestamp = fields[key] as? Timestamp else { throw WorkspaceRequestError.malformed }
            normalized[key] = timestamp.dateValue().timeIntervalSince1970
        }
        let data = try JSONSerialization.data(withJSONObject: normalized)
        let values = try JSONDecoder().decode([String: JSONValue].self, from: data)
        return try WorkspaceAnalysisRequest(documentID: documentID, fields: values)
    }

    nonisolated private static func requestFields(_ request: WorkspaceAnalysisRequest) throws -> [String: Any] {
        guard var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request.fields)) as? [String: Any] else {
            throw WorkspaceRequestError.malformed
        }
        for key in ["createdAt", "updatedAt", "leaseUntil"] {
            if let seconds = request.fields[key]?.number { fields[key] = Timestamp(date: Date(timeIntervalSince1970: seconds)) }
        }
        return fields
    }
}
