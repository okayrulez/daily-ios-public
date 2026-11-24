import Foundation
import DailyCore
@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseCore
@preconcurrency import FirebaseFirestore

extension FirebaseWorkspace {
    func fetchProfileResearch(key: String, scope: WorkspaceRequestScope) async throws -> WorkspaceRecord? {
        guard key.hasPrefix(ProfileResearchSource.prefix),
              requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else {
            throw WorkspaceRequestError.accountChanged
        }
        let snapshot = try await database.collection(WorkspaceIdentity.recordsPath(uid: scope.uid))
            .document(WorkspaceHash.sha256(key)).getDocument(source: .server)
        guard requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else {
            throw WorkspaceRequestError.accountChanged
        }
        return try snapshot.data().map { try Self.decode($0, documentID: snapshot.documentID) }
    }

    func fetchTaskReport(key: String, scope: WorkspaceRequestScope) async throws -> String {
        guard key.hasPrefix("note:dailyx/tasks/"),
              requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
        let snapshot = try await database.collection(WorkspaceIdentity.recordsPath(uid: scope.uid))
            .document(WorkspaceHash.sha256(key)).getDocument(source: .server)
        guard requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid),
              let data = snapshot.data() else { throw WorkspaceError.malformedRecord }
        let record = try Self.decode(data, documentID: snapshot.documentID)
        guard record.key == key, let text = try record.payload().string,
              let result = try JSONValue.parse(text).object?["result"] else { throw WorkspaceError.malformedRecord }
        return try result.canonical()
    }
    func fetchMemory(scope: WorkspaceRequestScope) async throws -> (PortableMemory?, WorkspaceRecord?) {
        guard requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
        let collection = database.collection(try WorkspaceIdentity.recordsPath(uid: scope.uid))
        let snapshot = try await collection.document(WorkspaceHash.sha256(PhoneAnalysisCommit.manifestKey)).getDocument(source: .server)
        guard let fields = snapshot.data() else { return (nil,nil) }
        let manifest = try Self.decode(fields, documentID: snapshot.documentID)
        return (try await fetchMemoryManifest(manifest, scope: scope), manifest)
    }
    func fetchMemoryManifest(_ manifest: WorkspaceRecord, scope: WorkspaceRequestScope) async throws -> PortableMemory? {
        let collection = database.collection(try WorkspaceIdentity.recordsPath(uid: scope.uid))
        guard let text = try manifest.payload().string, let content=try JSONValue.parse(text).object,
              let refs = content["chunks"]?.array,
              refs.count <= 54 else { throw WorkspaceError.malformedRecord }
        if content["storage"] == .string("device") { return nil }
        let scopeIdentity = try MemoryScope(projectID: database.app.options.projectID ?? database.app.name, uid: scope.uid)
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let store = try MemoryStore(root: root.appendingPathComponent("DailyXMemory", isDirectory: true))
        if let cached = try await store.load(scope: scopeIdentity), cached.contentHash == content["memoryHash"]?.string {
            guard requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
            return cached
        }
        var chunks: [WorkspaceRecord] = []
        for ref in refs {
            guard requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid),
                  let key = ref.object?["key"]?.string, key.hasPrefix("note:dailyx/chunks/") else { throw WorkspaceRequestError.accountChanged }
            let item = try await collection.document(WorkspaceHash.sha256(key)).getDocument(source: .server)
            guard let data = item.data() else { throw WorkspaceError.malformedRecord }
            chunks.append(try Self.decode(data, documentID: item.documentID))
        }
        guard requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
        return try PhoneAnalysisCommit.decodeMemory(manifest: manifest, chunks: chunks)
    }

    /// Immutable chunks are invisible until the manifest is committed. Partial uploads are harmless.
    func commitAnalysis(_ plan: PhoneAnalysisCommit, scope: WorkspaceRequestScope) async throws {
        for chunk in plan.chunks + (try WorkspaceRecordStorage(plan.journal).chunks) {
            try Task.checkCancellation()
            try await immutable(chunk, scope: scope)
        }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.commit(database: database, gate: requestGate, scope: scope, plan: plan, continuation: continuation)
        }
    }

    func immutable(_ record: WorkspaceRecord, scope: WorkspaceRequestScope) async throws {
        let ref = database.collection(try WorkspaceIdentity.recordsPath(uid: scope.uid)).document(record.documentID)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.writeImmutable(database: database, ref: ref, record: record, gate: requestGate, scope: scope, continuation: continuation)
        }
    }
    nonisolated private static func writeImmutable(database: Firestore, ref: DocumentReference, record: WorkspaceRecord,
        gate: WorkspaceRequestSessionGate, scope: WorkspaceRequestScope, continuation: CheckedContinuation<Void, Error>) {
        database.runTransaction({ tx, error -> Any? in
            do {
                guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
                let old = try tx.getDocument(ref)
                if let data = old.data() {
                    guard try Self.decode(data, documentID: ref.documentID) == record else { throw WorkspaceError.conflict }
                } else { tx.setData(try Self.fields(record), forDocument: ref) }
                return true
            } catch let failure { error?.pointee = failure as NSError; return nil }
        }, completion: { _, error in
            if let error { continuation.resume(throwing:error) }
            else if !gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) { continuation.resume(throwing: WorkspaceRequestError.accountChanged) }
            else { continuation.resume() }
        })
    }
    nonisolated private static func commit(database: Firestore, gate: WorkspaceRequestSessionGate,
        scope: WorkspaceRequestScope, plan: PhoneAnalysisCommit, continuation: CheckedContinuation<Void, Error>) {
        guard let path = try? WorkspaceIdentity.recordsPath(uid: scope.uid) else {
            continuation.resume(throwing: WorkspaceError.invalidAccount); return
        }
        let collection = database.collection(path)
        database.runTransaction({ tx, error -> Any? in
            do {
                guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
                let receiptRef = collection.document(plan.receipt.documentID)
                let receipt = try tx.getDocument(receiptRef)
                // Check receipt FIRST: an acknowledgement can be lost before a later user edit.
                if let data = receipt.data() {
                    guard try Self.decode(data, documentID: receipt.documentID) == plan.receipt else { throw WorkspaceError.conflict }
                    return true
                }
                let sourceRef = collection.document(plan.source.documentID), manifestRef = collection.document(plan.manifest.documentID)
                let source = try tx.getDocument(sourceRef), manifest = try tx.getDocument(manifestRef)
                guard let sourceFields = source.data(), try Self.decode(sourceFields, documentID: source.documentID, transaction: tx, root: collection) == plan.source,
                      try manifest.data().map({ try Self.decode($0, documentID: manifest.documentID) }) == plan.expectedManifest else {
                    throw WorkspaceError.conflict
                }
                if plan.source.isProfileResearch {
                    let profileRef = collection.document(WorkspaceHash.sha256(SocialProfile.key))
                    let snapshot = try tx.getDocument(profileRef)
                    guard let fields = snapshot.data(),
                          ProfileResearchSource.key(for: try Self.decode(fields, documentID: profileRef.documentID)) == plan.source.key else {
                        throw WorkspaceError.conflict
                    }
                }
                guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
                tx.setData(sourceFields, forDocument: sourceRef.collection("versions").document(plan.source.hash))
                if let previous=plan.expectedManifest {
                    tx.setData(try Self.fields(previous), forDocument:manifestRef.collection("versions").document(previous.hash))
                }
                for record in [plan.journal,plan.manifest,plan.receipt] + plan.atlas {
                    tx.setData(try Self.fields(record), forDocument: collection.document(record.documentID))
                }
                return true
            } catch let failure {
                error?.pointee = NSError(domain: "DailyX.Commit", code: (failure as? WorkspaceError) == .conflict ? 1 : 2)
                return nil
            }
        }, completion: { _, error in
            guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else {
                continuation.resume(throwing: WorkspaceRequestError.accountChanged); return
            }
            if let error {
                let ns = error as NSError
                continuation.resume(throwing: ns.domain == "DailyX.Commit" && ns.code == 1 ? WorkspaceError.conflict : error)
            } else { continuation.resume() }
        })
    }
}
