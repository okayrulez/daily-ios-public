import Foundation
import DailyCore
@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFirestore

/// Existing developer-configured projects remain supported behind the same optional cloud interface.
@MainActor final class FirebaseWorkspaceCloud: WorkspaceCloudClient {
    let remote = FirebaseWorkspace()
    let scope: WorkspaceRequestScope
    init(uid: String) throws {
        scope = try WorkspaceRequestScope(uid: uid, session: UUID(), generation: UUID())
        remote.requestGate.activate(scope)
    }
    func invalidate() { remote.detach() }
    func eraseWorkspace() async throws {
        // Stop other clients before resetting: Firestore does not recursively delete subcollections.
        for collection in ["dailyXPushDevices", "dailyXRequests", "dailyXRecords", "dailyXPushDeliveries", "dailyXPushBudgets"] {
            do { try await eraseCollection(remote.database.collection("users/\(scope.uid)/" + collection), versions: collection == "dailyXRecords") }
            catch { throw WorkspaceResetFailure(collection: collection, underlying: error) }
        }
    }
    private func eraseCollection(_ collection: CollectionReference, versions: Bool = false) async throws {
        while true {
            try Task.checkCancellation()
            guard remote.requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
            let page = try await collection.limit(to: 100).getDocuments(source: .server)
            guard remote.requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
            if page.documents.isEmpty { return }
            for document in page.documents where versions { try await eraseCollection(document.reference.collection("versions")) }
            guard remote.requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
            let batch = remote.database.batch()
            for document in page.documents { batch.deleteDocument(document.reference) }
            try await batch.commit()
        }
    }
    func read(_ key: String) async throws -> WorkspaceRecord? {
        let snapshot = try await remote.database.collection(WorkspaceIdentity.recordsPath(uid: scope.uid))
            .document(WorkspaceHash.sha256(key)).getDocument(source: .server)
        guard remote.requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
        return snapshot.exists ? try await remote.decodeRemote(snapshot) : nil
    }
    func snapshot() async throws -> [WorkspaceRecord] { try await remote.repositorySnapshot(scope: scope) }
    func publish(_ publication: WorkspacePublication) async throws { try await remote.publishRepository(publication, scope: scope) }
    func prompts() async throws -> AnalysisPromptConfiguration { try await remote.fetchAnalysisPrompts(scope: scope) }
    func version(key: String, hash: String) async throws -> WorkspaceRecord { try await remote.fetchVersion(key: key, hash: hash, scope: scope) }
    func registerPush(deviceID: String, token: String?, environment: String) async throws {
        try await remote.registerPush(scope: scope, deviceID: deviceID, token: token, environment: environment)
    }
    func enqueue(source: WorkspaceRecord, kind: WorkspaceAnalysisKind) async throws -> String {
        try await remote.enqueue(scope: scope, source: source, kind: kind)
    }
    func analysisRequests() async throws -> [WorkspaceAnalysisRequest] {
        let result = try await remote.database.collection(WorkspaceAnalysisRequest.path(uid: scope.uid)).getDocuments(source: .server)
        guard remote.requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
        return try result.documents.map { try FirebaseWorkspace.decodeRequest($0.data(), documentID: $0.documentID) }
    }
}

extension FirebaseWorkspace {
    func publishRepository(_ publication: WorkspacePublication, scope: WorkspaceRequestScope) async throws {
        for chunk in publication.chunks { try await immutable(chunk, scope: scope) }
        for record in publication.records {
            for chunk in try WorkspaceRecordStorage(record).chunks { try await immutable(chunk, scope: scope) }
        }
        try await withCheckedThrowingContinuation { continuation in
            Self.repositoryTransaction(database: database, gate: requestGate, scope: scope, publication: publication, continuation: continuation)
        }
    }
    nonisolated private static func repositoryTransaction(database: Firestore, gate: WorkspaceRequestSessionGate,
        scope: WorkspaceRequestScope, publication: WorkspacePublication, continuation: CheckedContinuation<Void, Error>) {
        guard let path = try? WorkspaceIdentity.recordsPath(uid: scope.uid) else { continuation.resume(throwing: WorkspaceError.invalidAccount); return }
        let root = database.collection(path)
        database.runTransaction({ tx, error -> Any? in
            do {
                guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
                let receiptKey = "note:dailyx/receipts/sync-" + publication.id
                let receipt = try WorkspaceRecord.make(key: receiptKey, kind: .note, payload: .string(
                    JSONValue.object(["id": .string(publication.id), "records": .array(publication.records.map { .string($0.key + ":" + $0.hash) })]).canonical()))
                let receiptRef = root.document(receipt.documentID), oldReceipt = try tx.getDocument(receiptRef)
                if let data = oldReceipt.data() {
                    guard try Self.decode(data, documentID: receiptRef.documentID) == receipt else { throw WorkspaceError.conflict }; return true
                }
                var existing: [String: [String: Any]] = [:]
                for key in Set(publication.records.map(\.key) + publication.expected.map(\.key)) {
                    let snapshot = try tx.getDocument(root.document(WorkspaceHash.sha256(key)))
                    if let data = snapshot.data() { existing[key] = data }
                }
                for condition in publication.expected where !publication.records.contains(where: { $0.key == condition.key }) {
                    guard existing[condition.key]?["hash"] as? String == condition.hash else { throw WorkspaceSyncError.conflict }
                }
                let expected = Dictionary(uniqueKeysWithValues: publication.expected.map { ($0.key, $0.hash) })
                for record in publication.records {
                    let oldHash = existing[record.key]?["hash"] as? String
                    if oldHash == record.hash { continue }
                    guard oldHash == (expected[record.key] ?? nil) else { throw WorkspaceSyncError.conflict }
                    if let previous = existing[record.key], let oldHash,
                       record.kind == .journal || record.key == PhoneAnalysisCommit.manifestKey || record.isProfileResearch {
                        tx.setData(previous, forDocument: root.document(record.documentID).collection("versions").document(oldHash))
                    }
                    tx.setData(try Self.fields(record), forDocument: root.document(record.documentID))
                }
                let marker = try WorkspaceRecord.make(key: "note:companion/sync-revision.json", kind: .note,
                    payload: .string(JSONValue.object(["revision": .string(publication.id)]).canonical()))
                tx.setData(try Self.fields(receipt), forDocument: receiptRef)
                tx.setData(try Self.fields(marker), forDocument: root.document(marker.documentID))
                return true
            } catch let failure { error?.pointee = failure as NSError; return nil }
        }, completion: { _, error in
            if let error { continuation.resume(throwing: error) }
            else if !gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) { continuation.resume(throwing: WorkspaceRequestError.accountChanged) }
            else { continuation.resume() }
        })
    }
}
