import Foundation

public struct PhoneAnalysisCommit: Sendable, Codable {
    public let jobID: String
    public let source: WorkspaceRecord
    public let expectedManifest: WorkspaceRecord?
    public let memory: PortableMemory
    public let journal: WorkspaceRecord
    public let manifest: WorkspaceRecord
    public let receipt: WorkspaceRecord
    public let chunks: [WorkspaceRecord]
    public let atlas: [WorkspaceRecord]
    public let changes: AnalysisChanges?
    public let execution: String?
    public let appleDestinations: [String: String]?
    public let appleRevocations: [String]?
    public static let manifestKey = "note:companion/dailyx-memory.json"

    /// Structured approvals never call an inference provider, even without a ChatGPT session.
    public static func functional(scope: MemoryScope, source: WorkspaceRecord, memory: PortableMemory,
                                  manifest: WorkspaceRecord?, now: String) throws -> PhoneAnalysisCommit {
        let job = try PhoneAnalysisJob(scope: scope, accountID: scope.uid, model: "device-functional-v1", source: source,
            memoryHash: memory.contentHash, memoryContext: "", workContext: "", localOnly: true)
        let json = "{\"kind\":\"functional_answers\"}"
        let result = PhoneAnalysisResult(jobID: job.id, sourceHash: source.hash, memoryHash: memory.contentHash,
            validatedJSON: json, contentHash: WorkspaceHash.sha256(json), createdAt: now)
        return try PhoneAnalysisCommit(job: job, result: result, source: source, memory: memory,
                                       expectedManifest: manifest, now: now, uploadMemory: true)
    }

    public init(job: PhoneAnalysisJob, result: PhoneAnalysisResult, source: WorkspaceRecord,
                memory: PortableMemory, expectedManifest: WorkspaceRecord?, now: String,
                uploadMemory: Bool = false, suppressedQuestionPrompts: [String] = []) throws {
        guard result.jobID == job.id, result.sourceHash == source.hash, result.memoryHash == memory.contentHash,
              job.sourceHash == source.hash, job.memoryHash == memory.contentHash,
              result.contentHash == WorkspaceHash.sha256(result.validatedJSON) else { throw WorkspaceError.conflict }
        let input = try source.analysisJournal().payload
        let fields: [String:JSONValue] = ["memory": try JSONValue.parse(memory.json),
            "journal": input, "result": try JSONValue.parse(result.validatedJSON),
            "expectedMemoryHash": .string(memory.contentHash), "expectedSourceHash": .string(WorkspaceHash.sha256(try input.canonical())),
            "jobID": .string(job.id), "model": .string(job.model), "now": .string(now)]
        let args=JSONValue.object(fields)
        let kind = fields["result"]?.object?["kind"]
        self.execution = kind == .string("functional_answers") ? "functional" : nil
        if source.isProfileResearch {
            let resultFields = fields["result"]?.object
            guard kind == .string("daily_task"), resultFields?["action"] == .string("research"),
                  resultFields?["operations"] == .array([]), resultFields?["reminderProposals"] == .array([]) else {
                throw AnalysisCoreError.invalidOutput
            }
        }
        let command = kind == .string("functional_answers") ? "applyFunctionalAnswers" : kind == .string("map_links_result") ? "applyMapLinks" : kind == .string("daily_task") ? "applyTask" : "applyJournal"
        guard let output = try JSONValue.parse(AnalysisCore.invoke(command, json: args.canonical())).object,
              let nextMemory = output["memory"], var journal = output["journal"], let rawAtlas = output["atlas"]?.array,
              let cards=output["cards"]?.array else {
            throw WorkspaceError.malformedRecord
        }
        self.appleDestinations = output["appleDestinations"]?.object?.compactMapValues(\.string)
        self.appleRevocations = output["appleRevocations"]?.array?.compactMap(\.string)
        if !suppressedQuestionPrompts.isEmpty, var row=journal.object, let questions=row["questions"]?.array {
            func key(_ value:String)->String { value.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"tr_TR")).split(whereSeparator:{!$0.isLetter && !$0.isNumber}).joined(separator:" ") }
            let known=Set(suppressedQuestionPrompts.map(key))
            row["questions"] = .array(questions.filter { item in
                guard let fields=item.object,let prompt=fields["prompt"]?.string else {return true}
                return fields["reminder_proposal"]?.object != nil || !known.contains(key(prompt))
            })
            journal = .object(row)
        }
        self.jobID = job.id; self.source = source; self.expectedManifest = expectedManifest
        self.memory = try PortableMemory(json: nextMemory.canonical())
        self.journal = source.isProfileResearch ? try ProfileResearchSource.record(key: source.key, payload: journal) :
            try WorkspaceRecord.make(key: source.key, kind: .journal, payload: journal)
        guard let oldGraph = try JSONValue.parse(memory.json).object?["graph"],
              let newGraph = nextMemory.object?["graph"] else { throw WorkspaceError.malformedRecord }
        let journalDocument = try self.journal.analysisJournal()
        let finalQuestionCount = journalDocument.questions.count
        self.changes = try AnalysisChanges(before: oldGraph, after: newGraph, questionCount: finalQuestionCount)
        let filteredCards = source.isProfileResearch ? [] : cards.filter { card in
            guard finalQuestionCount == 0,let key=card.object?["key"]?.string else { return true }
            return !key.hasPrefix("note:companion/cards/journal_questions_")
        }
        var displayRecords = try (rawAtlas+filteredCards).map { value in
            guard let row = value.object, let key = row["key"]?.string, let content = row["content"]?.string else {
                throw WorkspaceError.malformedRecord
            }
            return try WorkspaceRecord.make(key: key, kind: .note, payload: JSONValue.parse(content))
        }
        let previousAgenda = try JSONValue.parse(memory.json).object?["agenda"]?.array ?? []
        let agendaChanges = (nextMemory.object?["agenda"]?.array ?? []).filter { item in
            !previousAgenda.contains(item)
        }.map { item in
            let fields=item.object ?? [:]
            let title=fields["title"]?.string ?? "Etkinlik"
            return JSONValue.string((fields["status"] == .string("cancelled") ? "Kaldırıldı: " : "Kaydedildi: ") + title)
        }
        let changesJSON = try JSONValue.parse(String(decoding: JSONEncoder().encode(self.changes), as: UTF8.self))
        let receiptID = now + "-" + job.id
        if !source.isProfileResearch && kind != .string("functional_answers") {
            let changeReceipt = try WorkspaceRecord.make(key:"note:companion/changes/"+receiptID+".json",kind:.note,payload:.string(
            try JSONValue.object(["id":.string(receiptID),"date":.string(journalDocument.date),"createdAt":.string(now),
                "resultHash":.string(self.journal.hash),"memoryHash":.string(self.memory.contentHash),"sourceHash":.string(source.hash),
                "priorManifest":expectedManifest?.json ?? .null,"changes":changesJSON,"agenda":.array(agendaChanges)]).canonical()))
            displayRecords.append(changeReceipt)
        }
        self.atlas = displayRecords
        let bytes = Data(self.memory.json.utf8)
        guard bytes.count <= 16_000_000 else { throw WorkspaceError.oversizedRecord }
        var chunks: [WorkspaceRecord] = []
        for offset in stride(from: 0, to: uploadMemory ? bytes.count : 0, by: 300_000) {
            let text = bytes.subdata(in: offset..<min(offset + 300_000, bytes.count)).base64EncodedString()
            let content = try JSONValue.string(text).canonical()
            chunks.append(try WorkspaceRecord.make(key: "note:dailyx/chunks/" + WorkspaceHash.sha256(content),
                                                   kind: .note, payload: .string(text)))
        }
        self.chunks = chunks
        self.manifest = try WorkspaceRecord.make(key: Self.manifestKey, kind: .note, payload: .string(
            try JSONValue.object(["schemaVersion": .number(1), "revision": .number(Double(self.memory.revision)),
                "storage": .string(uploadMemory ? "cloud" : "device"),
                "memoryHash": .string(self.memory.contentHash), "chunks": .array(chunks.map {
                    .object(["key": .string($0.key), "hash": .string($0.hash)])
                })]).canonical()))
        self.receipt = try WorkspaceRecord.make(key: "note:dailyx/receipts/" + job.id, kind: .note, payload: .string(
            try JSONValue.object(["jobID": .string(job.id), "sourceHash": .string(source.hash),
                "resultHash": .string(self.journal.hash), "memoryHash": .string(self.memory.contentHash)]).canonical()))
        // Leave generous headroom under Firestore's 500 writes / 10 MiB transaction limits.
        guard atlas.count + 4 <= 400,
              try ([self.journal,self.manifest,self.receipt] + atlas).reduce(0, { $0 + (try WorkspaceRecordStorage($1).fields.canonical().utf8.count) }) < 8_000_000 else {
            throw WorkspaceError.oversizedRecord
        }
    }

    public static func decodeMemory(manifest: WorkspaceRecord, chunks: [WorkspaceRecord]) throws -> PortableMemory {
        guard manifest.key == manifestKey, let text = try manifest.payload().string,
              let value = try JSONValue.parse(text).object, value["schemaVersion"] == .number(1),
              value["storage"] == .string("cloud"),
              let refs = value["chunks"]?.array, !refs.isEmpty, refs.count <= 54, refs.count == chunks.count,
              let expected = value["memoryHash"]?.string else { throw WorkspaceError.malformedRecord }
        var bytes = Data()
        for (ref, chunk) in zip(refs,chunks) {
            guard ref.object?["key"]?.string == chunk.key, ref.object?["hash"]?.string == chunk.hash,
                  let data = try chunk.payload().string.flatMap({ Data(base64Encoded: $0) }) else { throw WorkspaceError.invalidHash }
            bytes.append(data)
            guard bytes.count <= 16_000_000 else { throw WorkspaceError.oversizedRecord }
        }
        guard let json = String(data: bytes, encoding: .utf8), WorkspaceHash.sha256(json) == expected else { throw WorkspaceError.invalidHash }
        let memory = try PortableMemory(json: json)
        guard memory.revision == value["revision"]?.integer else { throw WorkspaceError.malformedRecord }
        return memory
    }
}
