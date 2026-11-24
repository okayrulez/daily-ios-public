import Foundation
import DailyCore
@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFirestore

extension FirebaseWorkspace {
    func saveSocialProfile(_ profile: SocialProfile, expectedHash: String?, scope: WorkspaceRequestScope) async throws -> WorkspaceRecord {
        let data = try JSONEncoder().encode(profile.validated())
        guard let text = String(data: data, encoding: .utf8) else { throw WorkspaceError.malformedRecord }
        let record = try WorkspaceRecord.make(key: SocialProfile.key, kind: .note, payload: .string(text))
        let ref = database.collection(try WorkspaceIdentity.recordsPath(uid: scope.uid)).document(record.documentID)
        return try await withCheckedThrowingContinuation { continuation in
            Self.socialProfileTransaction(database: database, ref: ref, gate: requestGate, scope: scope,
                record: record, expectedHash: expectedHash, continuation: continuation)
        }
    }
    nonisolated private static func socialProfileTransaction(database: Firestore, ref: DocumentReference, gate: WorkspaceRequestSessionGate,
        scope: WorkspaceRequestScope, record: WorkspaceRecord, expectedHash: String?, continuation: CheckedContinuation<WorkspaceRecord, Error>) {
        database.runTransaction({ tx, error -> Any? in
            do {
                guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
                let snapshot = try tx.getDocument(ref)
                let current = try snapshot.data().map { try Self.decode($0, documentID: ref.documentID) }
                guard current?.hash == expectedHash || current?.hash == record.hash else { throw WorkspaceError.conflict }
                tx.setData(try Self.fields(record), forDocument: ref)
                return try record.json.canonical()
            } catch let failure { error?.pointee = failure as NSError; return nil }
        }, completion: { result, error in
            do {
                if let error { throw error }
                guard gate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid), let text = result as? String else { throw WorkspaceRequestError.accountChanged }
                continuation.resume(returning: try WorkspaceRecord(json: JSONValue.parse(text)))
            } catch { continuation.resume(throwing: error) }
        })
    }

    func recordExperience(_ event: ExperienceEvent, scope: WorkspaceRequestScope) async throws -> WorkspaceRecord {
        let ref=database.collection(try WorkspaceIdentity.recordsPath(uid:scope.uid)).document(WorkspaceHash.sha256(WorkspaceExperience.key))
        return try await withCheckedThrowingContinuation { continuation in
            Self.experienceTransaction(database:database,ref:ref,gate:requestGate,scope:scope,event:event,continuation:continuation)
        }
    }
    nonisolated private static func experienceTransaction(database: Firestore, ref: DocumentReference, gate: WorkspaceRequestSessionGate,
        scope: WorkspaceRequestScope,event: ExperienceEvent,continuation: CheckedContinuation<WorkspaceRecord,Error>) {
        database.runTransaction({ tx,error -> Any? in
            do {
                guard gate.accepts(scope,authenticatedUID:Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
                let old=try tx.getDocument(ref)
                let record=try old.data().map { try Self.decode($0,documentID:ref.documentID) }
                let updated=try WorkspaceExperience(record:record).recording(event).record()
                tx.setData(try Self.fields(updated),forDocument:ref)
                return try updated.json.canonical()
            } catch let failure { error?.pointee=failure as NSError;return nil }
        }, completion: { result,error in
            do {
                if let error { throw error }
                guard gate.accepts(scope,authenticatedUID:Auth.auth().currentUser?.uid),let text=result as? String else { throw WorkspaceRequestError.accountChanged }
                continuation.resume(returning:try WorkspaceRecord(json:JSONValue.parse(text)))
            }catch{continuation.resume(throwing:error)}
        })
    }
    func fetchVersion(key: String,hash: String,scope: WorkspaceRequestScope) async throws -> WorkspaceRecord {
        guard WorkspaceHash.valid(hash),requestGate.accepts(scope,authenticatedUID:Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
        let ref=database.collection(try WorkspaceIdentity.recordsPath(uid:scope.uid)).document(WorkspaceHash.sha256(key))
        let old=try await ref.collection("versions").document(hash).getDocument(source:.server)
        guard requestGate.accepts(scope,authenticatedUID:Auth.auth().currentUser?.uid),old.exists else { throw WorkspaceError.conflict }
        let value=try await decodeRemote(old)
        guard value.hash == hash else { throw WorkspaceError.invalidHash }
        return value
    }
    func commitMemoryEdit(_ plan: WorkspaceMemoryMutation,scope: WorkspaceRequestScope) async throws {
        for chunk in plan.chunks { try await immutable(chunk,scope:scope) }
        for record in plan.records {
            for chunk in try WorkspaceRecordStorage(record).chunks { try await immutable(chunk, scope: scope) }
        }
        try await withCheckedThrowingContinuation { continuation in
            Self.memoryEditTransaction(database:database,gate:requestGate,scope:scope,plan:plan,continuation:continuation)
        }
    }
    nonisolated private static func memoryEditTransaction(database: Firestore,gate: WorkspaceRequestSessionGate,scope: WorkspaceRequestScope,
        plan: WorkspaceMemoryMutation,continuation: CheckedContinuation<Void,Error>) {
        guard let path=try? WorkspaceIdentity.recordsPath(uid:scope.uid) else { continuation.resume(throwing:WorkspaceError.invalidAccount);return }
        let collection=database.collection(path)
        database.runTransaction({ tx,error -> Any? in
            do {
                guard gate.accepts(scope,authenticatedUID:Auth.auth().currentUser?.uid) else { throw WorkspaceRequestError.accountChanged }
                let ref=collection.document(plan.manifest.documentID),old=try tx.getDocument(ref)
                let existing=try old.data().map { try Self.decode($0,documentID:ref.documentID) }
                // Lost acknowledgements are idempotent. Later edits are never overwritten.
                if existing == plan.manifest { return true }
                guard existing == plan.expectedManifest else { throw WorkspaceError.conflict }
                var archivedFields: [String: [String: Any]] = [:]
                for expected in plan.expectedRecords {
                    let snapshot=try tx.getDocument(collection.document(expected.documentID))
                    guard let data=snapshot.data(),try Self.decode(data,documentID:expected.documentID,transaction:tx,root:collection) == expected else { throw WorkspaceError.conflict }
                    archivedFields[expected.documentID] = data
                }
                if let existing { tx.setData(try Self.fields(existing),forDocument:ref.collection("versions").document(existing.hash)) }
                for expected in plan.expectedRecords { tx.setData(archivedFields[expected.documentID]!,forDocument:collection.document(expected.documentID).collection("versions").document(expected.hash)) }
                for record in [plan.manifest]+plan.records { tx.setData(try Self.fields(record),forDocument:collection.document(record.documentID)) }
                return true
            }catch let failure {error?.pointee=failure as NSError;return nil}
        },completion:{ _,error in
            if let error { continuation.resume(throwing:error) }
            else if !gate.accepts(scope,authenticatedUID:Auth.auth().currentUser?.uid) { continuation.resume(throwing:WorkspaceRequestError.accountChanged) }
            else { continuation.resume() }
        })
    }
}


extension FirebaseWorkspace {
    func saveNotificationLimit(_ limit:Int,hour:Int,scope:WorkspaceRequestScope) async throws -> WorkspaceRecord {
        guard (1...5).contains(limit),(8...21).contains(hour) else {throw WorkspaceError.malformedRecord}
        let key="note:companion/preferences.md"
        let ref=database.collection(try WorkspaceIdentity.recordsPath(uid:scope.uid)).document(WorkspaceHash.sha256(key))
        return try await withCheckedThrowingContinuation { continuation in
            Self.notificationLimitTransaction(database:database,ref:ref,gate:requestGate,scope:scope,limit:limit,hour:hour,continuation:continuation)
        }
    }
    nonisolated private static func notificationLimitTransaction(database:Firestore,ref:DocumentReference,gate:WorkspaceRequestSessionGate,
        scope:WorkspaceRequestScope,limit:Int,hour:Int,continuation:CheckedContinuation<WorkspaceRecord,Error>) {
        database.runTransaction({tx,error -> Any? in
            do {
                guard gate.accepts(scope,authenticatedUID:Auth.auth().currentUser?.uid) else {throw WorkspaceRequestError.accountChanged}
                let snapshot=try tx.getDocument(ref)
                var row:[String:JSONValue]=["enabled":.bool(true),"dailyLimit":.number(3),"hour":.number(10),"pinnedNodeIds":.array([])]
                if let data=snapshot.data() {
                    let record=try Self.decode(data,documentID:ref.documentID)
                    guard let text=try record.payload().string,let parsed=try JSONValue.parse(text).object else {throw WorkspaceError.malformedRecord}
                    for (key,value) in parsed {row[key]=value}
                }
                row["dailyLimit"] = .number(Double(limit))
                row["hour"] = .number(Double(hour))
                let record=try WorkspaceRecord.make(key:"note:companion/preferences.md",kind:.note,payload:.string(JSONValue.object(row).canonical()))
                tx.setData(try Self.fields(record),forDocument:ref)
                return try record.json.canonical()
            }catch let failure{error?.pointee=failure as NSError;return nil}
        },completion:{result,error in
            do {
                if let error {throw error}
                guard gate.accepts(scope,authenticatedUID:Auth.auth().currentUser?.uid),let text=result as? String else {throw WorkspaceRequestError.accountChanged}
                continuation.resume(returning:try WorkspaceRecord(json:JSONValue.parse(text)))
            }catch{continuation.resume(throwing:error)}
        })
    }
}
