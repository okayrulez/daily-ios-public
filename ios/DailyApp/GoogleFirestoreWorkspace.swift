import Foundation
import DailyCore

/// OAuth acts as the user who selected this project. No service key, default developer database,
/// anonymous Firebase account or user-entered configuration file is used.
@MainActor final class GoogleFirestoreWorkspace: WorkspaceCloudClient {
    let api: GoogleFirebaseConnection
    let project: String
    let uid: String
    private let googleUID: String
    private var base: String { "https://firestore.googleapis.com/v1/projects/\(project)/databases/(default)/documents" }
    private var root: String { "projects/\(project)/databases/(default)/documents/users/\(uid)/dailyXRecords" }
    init(api: GoogleFirebaseConnection, project: String, uid: String, googleUID: String) throws {
        _ = try MemoryScope(projectID: project, uid: uid)
        try WorkspaceIdentity.validateUID(googleUID)
        self.api = api; self.project = project; self.uid = uid; self.googleUID = googleUID
    }
    private func request(_ url: String, method: String = "GET", body: JSONValue? = nil, missingAllowed: Bool = false) async throws -> JSONValue? {
        guard api.googleUID == googleUID else { throw WorkspaceSyncError.disconnected }
        let result = try await api.request(url, method: method, body: body, missingAllowed: missingAllowed)
        guard api.googleUID == googleUID else { throw WorkspaceSyncError.disconnected }
        return result
    }
    private func name(_ key: String) -> String { root + "/" + WorkspaceHash.sha256(key) }
    private func wire(_ record: WorkspaceRecord, at name: String? = nil) throws -> JSONValue {
        .object(["name": .string(name ?? self.name(record.key)), "fields": try FirestoreDocumentCodec.fields(WorkspaceRecordStorage(record).fields)])
    }
    private func decode(_ document: JSONValue, key: String? = nil) async throws -> WorkspaceRecord {
        guard let fields = document.object?["fields"], let resource = document.object?["name"]?.string,
              resource.hasPrefix(root + "/") else { throw WorkspaceError.invalidAddress }
        let value = try FirestoreDocumentCodec.decodeFields(fields)
        guard let recordKey = value.object?["key"]?.string, key == nil || key == recordKey,
              resource == name(recordKey) || resource.hasPrefix(name(recordKey) + "/versions/") else { throw WorkspaceError.invalidAddress }
        var chunks: [String: WorkspaceRecord] = [:]
        for reference in try WorkspaceRecordStorage.references(value) ?? [] {
            if chunks[reference] != nil { continue }
            guard let chunk = try await read(reference) else { throw WorkspaceError.malformedRecord }; chunks[reference] = chunk
        }
        return try WorkspaceRecordStorage.decode(value) { reference in
            guard let chunk = chunks[reference] else { throw WorkspaceError.malformedRecord }; return chunk
        }.validated(documentID: WorkspaceHash.sha256(recordKey))
    }
    func read(_ key: String) async throws -> WorkspaceRecord? {
        guard let document = try await request("https://firestore.googleapis.com/v1/" + name(key), missingAllowed: true) else { return nil }
        return try await decode(document, key: key)
    }
    func eraseWorkspace() async throws {
        // Enumerate the full collections, including old chunks and receipts omitted by snapshot().
        for collection in ["dailyXPushDevices", "dailyXRequests", "dailyXRecords", "dailyXPushDeliveries", "dailyXPushBudgets"] {
            do { try await eraseCollection("projects/\(project)/databases/(default)/documents/users/\(uid)/" + collection,
                                      versions: collection == "dailyXRecords") }
            catch { throw WorkspaceResetFailure(collection: collection, underlying: error) }
        }
    }
    private func eraseCollection(_ path: String, versions: Bool = false) async throws {
        // Drain the first page instead of using a page token invalidated by our own deletions.
        while true {
            try Task.checkCancellation()
            let response = try await request("https://firestore.googleapis.com/v1/" + path + "?pageSize=100&showMissing=true")
            let documents = response?.object?["documents"]?.array ?? []
            if documents.isEmpty { return }
            var names: [String] = []
            for document in documents {
                guard let name = document.object?["name"]?.string,
                      name.hasPrefix(path + "/"), !name.dropFirst(path.count + 1).contains("/") else { throw WorkspaceError.invalidAddress }
                if versions { try await eraseCollection(name + "/versions") }
                names.append(name)
            }
            _ = try await request(base + ":commit", method: "POST", body: .object([
                "writes": .array(names.map { .object(["delete": .string($0)]) })]))
        }
    }
    func version(key: String, hash: String) async throws -> WorkspaceRecord {
        guard WorkspaceHash.valid(hash), let document = try await request("https://firestore.googleapis.com/v1/" + name(key) + "/versions/" + hash) else { throw WorkspaceError.malformedRecord }
        let record = try await decode(document, key: key)
        guard record.hash == hash else { throw WorkspaceError.malformedRecord }
        return record
    }
    func snapshot() async throws -> [WorkspaceRecord] {
        guard try await request("https://firestore.googleapis.com/v1/projects/\(project)/databases/(default)", missingAllowed: true) != nil else { throw WorkspaceSyncError.databaseMissing }
        var rows: [WorkspaceRecord] = []
        let ranges: [(String?, String?)] = [(nil, nil), ("note:companion/", "note:companion/atlas/"),
            ("note:companion/atlas0", "note:companion/changes/"), ("note:companion/changes0", "note:companion0"),
            ("note:companion/changes/", "note:companion/changes0")]
        for (index, range) in ranges.enumerated() {
            func filter(_ field: String, _ op: String, _ value: String) -> JSONValue {
                .object(["fieldFilter": .object(["field": .object(["fieldPath": .string(field)]), "op": .string(op), "value": .object(["stringValue": .string(value)])])])
            }
            var query: [String: JSONValue] = ["from": .array([.object(["collectionId": .string("dailyXRecords")])])]
            if let lower = range.0, let upper = range.1 {
                query["where"] = .object(["compositeFilter": .object(["op": .string("AND"), "filters": .array([
                    filter("key", "GREATER_THAN_OR_EQUAL", lower), filter("key", "LESS_THAN", upper)])])])
            } else { query["where"] = filter("kind", "EQUAL", "journal") }
            if index == 4 { query["orderBy"] = .array([.object(["field": .object(["fieldPath": .string("key")]), "direction": .string("DESCENDING")])]); query["limit"] = .number(50) }
            let response = try await request(base + "/users/\(uid):runQuery", method: "POST", body: .object(["structuredQuery": .object(query)]))
            for item in response?.array ?? [] {
                if let document = item.object?["document"] { rows.append(try await decode(document)) }
            }
        }
        if let index = try await read("note:companion/atlas/index.md"), let atlas = try MobileAtlas.load(records: [index]) {
            rows.append(index)
            for reference in atlas.maps.flatMap({ $0.pages + ($0.detailPages ?? []) }) {
                guard let page = try await read(reference.key), page.hash == reference.hash else { throw WorkspaceError.conflict }; rows.append(page)
            }
        }
        if let manifest = try await read(PhoneAnalysisCommit.manifestKey), let text = try manifest.payload().string,
           let refs = try JSONValue.parse(text).object?["chunks"]?.array {
            rows.append(manifest)
            for ref in refs {
                guard let key = ref.object?["key"]?.string, let chunk = try await read(key) else { throw WorkspaceError.malformedRecord }; rows.append(chunk)
            }
        }
        return Array(Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }).values)
    }
    private func batchGet(_ names: [String], transaction: String? = nil) async throws -> [String: JSONValue] {
        var body: [String: JSONValue] = ["documents": .array(names.map(JSONValue.string))]
        if let transaction { body["transaction"] = .string(transaction) }
        let response = try await request(base + ":batchGet", method: "POST", body: .object(body))
        var result: [String: JSONValue] = [:]
        for row in response?.array ?? [] {
            if let found = row.object?["found"], let name = found.object?["name"]?.string, names.contains(name) { result[name] = found }
        }
        return result
    }
    func publish(_ publication: WorkspacePublication) async throws {
        guard publication.id.range(of: "^[a-zA-Z0-9_-]{1,100}$", options: .regularExpression) != nil else { throw WorkspaceError.invalidAddress }
        var chunks = publication.chunks
        for record in publication.records { chunks += try WorkspaceRecordStorage(record).chunks }
        chunks = Array(Dictionary(chunks.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }).values)
        for offset in stride(from: 0, to: chunks.count, by: 10) {
            let batch = Array(chunks[offset..<min(offset + 10, chunks.count)])
            let old = try await batchGet(batch.map { name($0.key) })
            var writes: [JSONValue] = []
            for chunk in batch {
                if let previous = old[name(chunk.key)] {
                    guard try await decode(previous).hash == chunk.hash else { throw WorkspaceSyncError.conflict }
                } else { writes.append(.object(["update": try wire(chunk), "currentDocument": .object(["exists": .bool(false)])])) }
            }
            if !writes.isEmpty { _ = try await request(base + ":commit", method: "POST", body: .object(["writes": .array(writes)])) }
        }
        let receiptKey = "note:dailyx/receipts/sync-" + publication.id
        let receipt = try WorkspaceRecord.make(key: receiptKey, kind: .note, payload: .string(
            JSONValue.object(["id": .string(publication.id), "records": .array(publication.records.map { .string($0.key + ":" + $0.hash) })]).canonical()))
        let transaction = try await request(base + ":beginTransaction", method: "POST", body: .object([:]))
        guard let token = transaction?.object?["transaction"]?.string else { throw WorkspaceError.malformedRecord }
        let names = Array(Set(publication.records.map { name($0.key) } + publication.expected.map { name($0.key) } + [name(receiptKey)]))
        let old = try await batchGet(names, transaction: token)
        if let previous = old[name(receiptKey)] {
            guard try await decode(previous).hash == receipt.hash else { throw WorkspaceSyncError.conflict }; return
        }
        let expected = Dictionary(uniqueKeysWithValues: publication.expected.map { ($0.key, $0.hash) })
        for condition in publication.expected where !publication.records.contains(where: { $0.key == condition.key }) {
            let fields = old[name(condition.key)]?.object?["fields"]
            let decoded = try fields.map(FirestoreDocumentCodec.decodeFields)
            let hash = decoded?.object?["hash"]?.string
            guard hash == condition.hash else { throw WorkspaceSyncError.conflict }
        }
        var writes: [JSONValue] = []
        for record in publication.records {
            let previous = old[name(record.key)]
            let oldFields: JSONValue?
            if let fields = previous?.object?["fields"] { oldFields = try FirestoreDocumentCodec.decodeFields(fields) }
            else { oldFields = nil }
            let currentHash = oldFields?.object?["hash"]?.string
            if currentHash == record.hash { continue }
            guard currentHash == (expected[record.key] ?? nil) else { throw WorkspaceSyncError.conflict }
            if let previous, let currentHash, record.kind == .journal || record.key == PhoneAnalysisCommit.manifestKey || record.isProfileResearch {
                var archived = previous.object!; archived.removeValue(forKey: "createTime"); archived.removeValue(forKey: "updateTime")
                archived["name"] = .string(name(record.key) + "/versions/" + currentHash)
                writes.append(.object(["update": .object(archived)]))
            }
            writes.append(.object(["update": try wire(record)]))
        }
        let marker = try WorkspaceRecord.make(key: "note:companion/sync-revision.json", kind: .note,
            payload: .string(JSONValue.object(["revision": .string(publication.id)]).canonical()))
        writes += [.object(["update": try wire(receipt)]), .object(["update": try wire(marker)])]
        let body = JSONValue.object(["transaction": .string(token), "writes": .array(writes)])
        guard writes.count <= 500, try body.canonical().utf8.count < 9_500_000 else { throw WorkspaceError.oversizedRecord }
        _ = try await request(base + ":commit", method: "POST", body: body)
    }
    private func decodeRequest(_ document: JSONValue) throws -> WorkspaceAnalysisRequest {
        guard let resource = document.object?["name"]?.string,
              resource.hasPrefix("projects/\(project)/databases/(default)/documents/users/\(uid)/dailyXRequests/"),
              let id = resource.split(separator: "/").last, let fields = document.object?["fields"],
              let row = try FirestoreDocumentCodec.decodeFields(fields).object else { throw WorkspaceRequestError.malformed }
        return try WorkspaceAnalysisRequest(documentID: String(id), fields: row)
    }
    func analysisRequests() async throws -> [WorkspaceAnalysisRequest] {
        let response = try await request(base + "/users/\(uid):runQuery", method: "POST", body: .object([
            "structuredQuery": .object(["from": .array([.object(["collectionId": .string("dailyXRequests")])])])]))
        return try (response?.array ?? []).compactMap { row in
            guard let doc = row.object?["document"] else { return nil }; return try decodeRequest(doc)
        }
    }
    func enqueue(source: WorkspaceRecord, kind: WorkspaceAnalysisKind) async throws -> String {
        let id = try WorkspaceAnalysisRequest.identity(kind: kind, sourceHash: source.hash)
        let resource = "projects/\(project)/databases/(default)/documents/users/\(uid)/dailyXRequests/" + id
        let transaction = try await request(base + ":beginTransaction", method: "POST", body: .object([:]))
        guard let token = transaction?.object?["transaction"]?.string else { throw WorkspaceRequestError.malformed }
        let docs = try await batchGet([name(source.key), resource], transaction: token)
        let current: WorkspaceRecord?
        if let document = docs[name(source.key)] { current = try await decode(document) } else { current = nil }
        let existing = try docs[resource].map { try decodeRequest($0) }
        let now = Date()
        guard let plan = try WorkspaceRequestPlanner.enqueue(current: current, expected: source, kind: kind, existing: existing, now: now.timeIntervalSince1970) else { return id }
        guard var fields = try FirestoreDocumentCodec.fields(.object(plan.fields)).object else { throw WorkspaceRequestError.malformed }
        let timestamp = JSONValue.object(["timestampValue": .string(CompanionCard.timestamp(now))])
        fields["createdAt"] = docs[resource]?.object?["fields"]?.object?["createdAt"] ?? timestamp
        fields["updatedAt"] = timestamp
        _ = try await request(base + ":commit", method: "POST", body: .object([
            "transaction": .string(token), "writes": .array([.object(["update": .object(["name": .string(resource), "fields": .object(fields)])])])]))
        return id
    }
    func prompts() async throws -> AnalysisPromptConfiguration {
        let documents = "projects/\(project)/databases/(default)/documents/"
        let journal = documents + AnalysisPromptConfiguration.documentPath
        let tasks = documents + AnalysisPromptConfiguration.taskDocumentPath
        let values = try await batchGet([journal, tasks])
        var result = AnalysisPromptConfiguration.bundled
        if let fields = values[journal]?.object?["fields"] {
            result = try AnalysisPromptConfiguration(json: FirestoreDocumentCodec.decodeFields(fields).canonical())
        }
        if let fields = values[tasks]?.object?["fields"] {
            result = try result.addingTaskInstructions(json: FirestoreDocumentCodec.decodeFields(fields).canonical())
        }
        return result
    }
    func registerPush(deviceID: String, token: String?, environment: String) async throws {
        guard CompanionCard.validID(deviceID), ["development", "production"].contains(environment) else { throw WorkspaceError.invalidAddress }
        let name = "projects/\(project)/databases/(default)/documents/users/\(uid)/dailyXPushDevices/\(deviceID)"
        let write: JSONValue
        if let token {
            let fields = JSONValue.object(["schemaVersion": .number(1), "transport": .string("apns"), "token": .string(token),
                "environment": .string(environment), "enabled": .bool(true), "updatedAt": .string(CompanionCard.timestamp(Date())),
                "expiresAt": .string(CompanionCard.timestamp(Date().addingTimeInterval(7 * 86400)))])
            write = .object(["update": .object(["name": .string(name), "fields": try FirestoreDocumentCodec.fields(fields)])])
        } else { write = .object(["delete": .string(name)]) }
        _ = try await request(base + ":commit", method: "POST", body: .object(["writes": .array([write])]))
    }
}
