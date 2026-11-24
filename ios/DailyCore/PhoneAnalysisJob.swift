import Foundation

public struct PhoneAnalysisJob: Sendable {
    public let id: String
    public let scope: MemoryScope
    public let accountID: String
    public let model: String
    public let reasoningEffort: String?
    public let sourceHash: String
    public let memoryHash: String
    public let rawText: String
    public let journalID: String
    public let answers: [String]
    public let finishingQuestionSession: Bool
    public let preparedJSON: String
    public let memoryContext: String
    public let prompts: AnalysisPromptConfiguration
    public let source: WorkspaceRecord

    public init(scope: MemoryScope, accountID: String, model: String, source: WorkspaceRecord,
                memoryHash: String, memoryContext: String, workContext: String,
                prompts: AnalysisPromptConfiguration = .bundled, reasoningEffort: String? = nil, localOnly: Bool = false,
                includeReflectionAnswers: Bool = true, reflectionAnswerSource: WorkspaceRecord? = nil) throws {
        guard !accountID.isEmpty, !model.isEmpty, WorkspaceHash.valid(memoryHash) else {
            throw WorkspaceError.malformedRecord
        }
        let journal = try source.analysisJournal()
        self.source = source
        self.journalID=journal.id
        let finishing = journal.isFinishingDayReflection
        self.finishingQuestionSession = finishing
        let answerQuestions: [String]
        if finishing && includeReflectionAnswers {
            let answerJournal = try reflectionAnswerSource?.analysisJournal() ?? journal
            guard let rows = try JSONValue.parse(AnalysisCore.invoke("journalPromptAnswers", json: answerJournal.payload.canonical())).array else {
                throw AnalysisCoreError.invalidOutput
            }
            self.answers = rows.compactMap { $0.object?["answer"]?.string }
            answerQuestions = rows.compactMap { $0.object?["question"]?.string }
            guard answers.count == rows.count, answerQuestions.count == rows.count else { throw AnalysisCoreError.invalidOutput }
        } else if finishing {
            self.answers = []; answerQuestions = []
        } else {
            guard let evidence = try JSONValue.parse(AnalysisCore.invoke("journalEvidence", json: journal.payload.canonical())).array,
                  evidence.allSatisfy({ $0.string != nil }) else { throw AnalysisCoreError.invalidOutput }
            self.answers = evidence.dropFirst().compactMap(\.string); answerQuestions = []
        }
        var input: [String: JSONValue] = [
            "journalId": .string(journal.id), "localDate": .string(journal.date),
            "rawText": .string(journal.rawText), "workContext": .string(workContext),
            "memoryContext": .string(memoryContext),
            "answers": .array(self.answers.map(JSONValue.string)),
            "finishingQuestionSession": .bool(finishing),
        ]
        if finishing { input["answerQuestions"] = .array(answerQuestions.map(JSONValue.string)) }
        if let previous = journal.previousDayReflection {
            input["previousDayReflection"] = .string(previous)
            if let count = journal.previousTextByteCount {
                let prefix = String(decoding: journal.rawText.utf8.prefix(count), as: UTF8.self)
                input["previousTextLength"] = .number(Double(prefix.utf16.count))
            }
        }
        let basePrepared = source.isProfileResearch || localOnly ? "{}" :
            try prompts.applying(to: AnalysisCore.invoke("prepareJournal", json: JSONValue.object(input).canonical()),
                                 stage: "journal", usageStage: finishing ? "dayReflection" : nil)
        let prepared = try ChatGPTModel.applyingReasoning(reasoningEffort, to: basePrepared)
        self.reasoningEffort = reasoningEffort
        var identityParts: [JSONValue] = [.string(scope.storageIdentity), .string(accountID),
            .string(model), .string(source.hash), .string(memoryHash), .string(prepared)]
        if prompts.fingerprint != "bundled" { identityParts.append(.string(prompts.fingerprint)) }
        let identity = try JSONValue.array(identityParts).canonical()
        self.id = WorkspaceHash.sha256(identity)
        self.scope = scope; self.accountID = accountID; self.model = model
        self.sourceHash = source.hash; self.memoryHash = memoryHash
        self.rawText = journal.rawText; self.preparedJSON = prepared
        self.memoryContext = memoryContext
        self.prompts = prompts
    }
}

public struct PhoneAnalysisResult: Codable, Sendable {
    public let jobID: String
    public let sourceHash: String
    public let memoryHash: String
    public let validatedJSON: String
    public let contentHash: String
    public let createdAt: String
}

public enum PhoneAnalysisError: Error { case sessionChanged, alreadyRunning, invalidCheckpoint }

/// Owns one account session. It produces a durable result, not a Firebase commit.
public actor PhoneAnalysisCoordinator {
    public typealias Inference = @Sendable (_ model: String, _ preparedJSON: String) async throws -> String
    private let root: URL
    private let infer: Inference
    private var scope: MemoryScope?
    private var accountID: String?
    private var generation = UUID()
    private var running: [String: Task<String, Error>] = [:]

    public init(root: URL, infer: @escaping Inference) throws {
        self.root = root; self.infer = infer
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func activate(scope: MemoryScope?, accountID: String?) {
        running.values.forEach { $0.cancel() }
        running = [:]; generation = UUID()
        self.scope = scope; self.accountID = accountID
    }

    public func run(_ job: PhoneAnalysisJob) async throws -> PhoneAnalysisResult {
        guard scope == job.scope, accountID == job.accountID else { throw PhoneAnalysisError.sessionChanged }
        try Task.checkCancellation()
        let session = generation
        let directory = try checkpointDirectory(job.scope)
        let file = directory.appendingPathComponent(job.id + ".json")
        try migrateCheckpoint(job.id + ".json", to: directory)
        if FileManager.default.fileExists(atPath: file.path) {
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4_000_000 else {
                throw PhoneAnalysisError.invalidCheckpoint
            }
            let cached = try JSONDecoder().decode(PhoneAnalysisResult.self, from: Data(contentsOf: file))
            guard cached.jobID == job.id, cached.sourceHash == job.sourceHash, cached.memoryHash == job.memoryHash,
                  cached.contentHash == WorkspaceHash.sha256(cached.validatedJSON),
                  try validate(cached.validatedJSON, job: job) == cached.validatedJSON else {
                throw PhoneAnalysisError.invalidCheckpoint
            }
            return cached
        }
        guard running[job.id] == nil else { throw PhoneAnalysisError.alreadyRunning }
        let inference = infer
        let rawFile=directory.appendingPathComponent(job.id+".raw.json")
        try migrateCheckpoint(job.id + ".raw.json", to: directory)
        let cachedRaw: String?
        if FileManager.default.fileExists(atPath:rawFile.path) {
            guard (try rawFile.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<4_000_000,
                  let value=try JSONValue.parse(String(contentsOf:rawFile,encoding:.utf8)).object,
                  let text=value["text"]?.string,value["hash"]?.string==WorkspaceHash.sha256(text),
                  value["jobID"]?.string==job.id else { throw PhoneAnalysisError.invalidCheckpoint }
            cachedRaw=text
        } else { cachedRaw=nil }
        let task = Task {
            if let cachedRaw { return cachedRaw }
            if job.rawText.utf8.count > 180_000 { return try await self.partitionedOutput(job) }
            return try await inference(job.model, job.preparedJSON)
        }
        running[job.id] = task
        defer { if generation == session { running.removeValue(forKey: job.id) } }
        let output = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard generation == session, scope == job.scope, accountID == job.accountID else {
            throw PhoneAnalysisError.sessionChanged
        }
        guard output.utf8.count<=2_000_000 else { throw AnalysisCoreError.invalidOutput }
        if cachedRaw==nil {
            let value=try JSONValue.object(["jobID":.string(job.id),"text":.string(output),"hash":.string(WorkspaceHash.sha256(output))]).canonical()
            try Data(value.utf8).write(to: rawFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let evidenceErrors = ["unsupported_source_quote", "unsupported_emotion_quote", "unsupported_reminder_quote"]
        let json: String
        do { json=try validate(output,job:job) }
        catch let failure as AnalysisValidationFailure where failure.command == "validateJournal" &&
            (evidenceErrors + ["schema_validation", "invalid_json", "missing_living_memory"]).contains(failure.code) {
            let repair: String
            let questionOnly: Bool
            var evidenceInput: [String: JSONValue]?
            if evidenceErrors.contains(failure.code) {
                let input: [String: JSONValue] = ["rawText": .string(job.rawText),
                    "answers": .array(job.answers.map(JSONValue.string)), "output": .string(output)]
                evidenceInput = input
                repair = try job.prompts.applying(to: AnalysisCore.invoke("prepareJournalQuoteRepair", json: JSONValue.object(input).canonical()),
                    stage: "journalRepair", usageStage: job.finishingQuestionSession ? "dayReflectionRepair" : nil)
                questionOnly = false
            } else if !job.finishingQuestionSession, let questionRepair = try? {
                let envelope=try JSONValue.object(["rawText":.string(job.rawText),"answers":.array(job.answers.map(JSONValue.string)),
                    "journalID":.string(job.journalID),"historyContext":.string(job.memoryContext),"result":JSONValue.parse(output)]).canonical()
                return try job.prompts.applying(to: AnalysisCore.invoke("prepareQuestionRepair",json:envelope), stage:"questionRepair")
            }() {
                repair = questionRepair
                questionOnly = true
            } else {
                let envelope=try JSONValue.object(["rawText":.string(job.rawText),"answers":.array(job.answers.map(JSONValue.string)),
                    "output":.string(output),"errorCode":.string(failure.code),
                    "finishingQuestionSession":.bool(job.finishingQuestionSession)]).canonical()
                repair=try job.prompts.applying(to: AnalysisCore.invoke("prepareJournalRepair",json:envelope), stage:"journalRepair",
                    usageStage: job.finishingQuestionSession ? "dayReflectionRepair" : nil)
                questionOnly = false
            }
            let repairTask=Task { try await inference(job.model,ChatGPTModel.applyingReasoning(job.reasoningEffort, to: repair)) }
            running[job.id]=repairTask
            let answer=try await withTaskCancellationHandler { try await repairTask.value } onCancel: { repairTask.cancel() }
            try Task.checkCancellation()
            guard generation==session,scope==job.scope,accountID==job.accountID else { throw PhoneAnalysisError.sessionChanged }
            do {
                guard answer.utf8.count <= 2_000_000 else { throw AnalysisCoreError.invalidOutput }
                if var evidenceInput {
                    evidenceInput["repair"] = .string(answer)
                    let patched = try AnalysisCore.invoke("finishJournalQuoteRepair", json: JSONValue.object(evidenceInput).canonical())
                    json = try validate(patched, job: job)
                } else if questionOnly {
                    guard let base = try JSONValue.parse(repair).object?["base"] else { throw AnalysisCoreError.invalidOutput }
                    let completed = try JSONValue.object(["rawText": .string(job.rawText), "answers": .array(job.answers.map(JSONValue.string)),
                        "base": base, "questions": JSONValue.parse(answer)]).canonical()
                    json = try AnalysisCore.invoke("completeQuestionRepair", json: completed)
                } else {
                    json = try validate(answer, job: job)
                }
            } catch {
                // The provider responded twice. The next manual attempt needs a fresh generation.
                try archiveInvalidResponse(rawFile)
                throw error
            }
        } catch {
            try archiveInvalidResponse(rawFile)
            throw error
        }
        let result = PhoneAnalysisResult(jobID: job.id, sourceHash: job.sourceHash,
            memoryHash: job.memoryHash, validatedJSON: json, contentHash: WorkspaceHash.sha256(json),
            createdAt:ISO8601DateFormatter().string(from:Date()))
        try JSONEncoder().encode(result).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return result
    }

    public func crossMap(scope: MemoryScope, accountID: String, model: String, memory: PortableMemory,
                         prompts: AnalysisPromptConfiguration = .bundled, reasoningEffort: String? = nil) async throws -> String? {
        try Task.checkCancellation()
        guard self.scope == scope, self.accountID == accountID else { throw PhoneAnalysisError.sessionChanged }
        let session=generation
        let prepared=try prompts.applying(to: AnalysisCore.invoke("prepareMapReview",json:memory.json), stage:"crossMap")
        guard try JSONValue.parse(prepared).object?["needed"] == .bool(true) else { return nil }
        let identity = try JSONValue.array([.string(scope.storageIdentity), .string(accountID), .string(model),
            .string(memory.contentHash), .string(prepared), .string(reasoningEffort ?? ""), .string(prompts.fingerprint)]).canonical()
        let id = WorkspaceHash.sha256(identity)
        let directory = try checkpointDirectory(scope)
        let file=directory.appendingPathComponent(id+".json")
        try migrateCheckpoint(id + ".json", to: directory)
        func validateCross(_ text: String) throws -> String {
            let envelope=try JSONValue.object(["memory":JSONValue.parse(memory.json),"result":.string(text)]).canonical()
            return try AnalysisCore.invoke("validateCrossMap",json:envelope)
        }
        if FileManager.default.fileExists(atPath:file.path) {
            guard (try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<4_000_000 else { throw PhoneAnalysisError.invalidCheckpoint }
            let result=try JSONDecoder().decode(PhoneAnalysisResult.self,from:Data(contentsOf:file))
            guard result.jobID==id,result.memoryHash==memory.contentHash,result.sourceHash==memory.contentHash,
                  result.contentHash==WorkspaceHash.sha256(result.validatedJSON) else { throw PhoneAnalysisError.invalidCheckpoint }
            return try validateCross(result.validatedJSON)
        }
        let inference=infer
        let task=Task { try await inference(model,ChatGPTModel.applyingReasoning(reasoningEffort, to: prepared)) }
        running[id]=task
        defer { if generation==session { running.removeValue(forKey:id) } }
        let raw=try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard generation == session, self.scope == scope, self.accountID == accountID else { throw PhoneAnalysisError.sessionChanged }
        let json: String
        do { json=try validateCross(raw) }
        catch let failure as AnalysisValidationFailure where failure.command == "validateCrossMap" && ["schema_validation", "invalid_json", "missing_reorganization_reason", "self_replacement", "contradictory_cross_map_change", "missing_map_review_report"].contains(failure.code) {
            // Repair formatting or inconsistent edit instructions once. Evidence failures and
            // provider errors must not be retried or silently accepted.
            guard raw.utf8.count <= 200_000 else { throw failure }
            let envelope=try JSONValue.object(["memory":JSONValue.parse(memory.json),"output":.string(raw),"errorCode":.string(failure.code)]).canonical()
            let repair=try prompts.applying(to: AnalysisCore.invoke("prepareCrossMapRepair",json:envelope), stage:"crossMapRepair")
            try Task.checkCancellation()
            let repairTask=Task { try await inference(model,ChatGPTModel.applyingReasoning(reasoningEffort, to: repair)) }
            running[id]=repairTask
            let repaired=try await withTaskCancellationHandler { try await repairTask.value } onCancel: { repairTask.cancel() }
            try Task.checkCancellation()
            guard generation == session, self.scope == scope, self.accountID == accountID else { throw PhoneAnalysisError.sessionChanged }
            json=try validateCross(repaired)
        }
        let result=PhoneAnalysisResult(jobID:id,sourceHash:memory.contentHash,memoryHash:memory.contentHash,
            validatedJSON:json,contentHash:WorkspaceHash.sha256(json),createdAt:ISO8601DateFormatter().string(from:Date()))
        try JSONEncoder().encode(result).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return json
    }

    private func checkpointDirectory(_ scope: MemoryScope) throws -> URL {
        let directory = root.appendingPathComponent(scope.storageIdentity, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func migrateCheckpoint(_ name: String, to directory: URL) throws {
        let old = root.appendingPathComponent(name), next = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: next.path) {
            try FileManager.default.moveItem(at: old, to: next)
        }
    }

    private func archiveInvalidResponse(_ file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let archive = file.deletingPathExtension().deletingPathExtension()
            .appendingPathExtension(UUID().uuidString + ".invalid.json")
        try FileManager.default.moveItem(at: file, to: archive)
    }

    private func validate(_ output: String, job: PhoneAnalysisJob) throws -> String {
        guard output.utf8.count <= 2_000_000 else { throw AnalysisCoreError.invalidOutput }
        let envelope = try JSONValue.object(["rawText": .string(job.rawText), "answers": .array(job.answers.map(JSONValue.string)),
            "result": .string(output), "finishingQuestionSession": .bool(job.finishingQuestionSession)]).canonical()
        return try AnalysisCore.invoke("validateJournal", json: envelope)
    }

    private func partitionedOutput(_ job: PhoneAnalysisJob) async throws -> String {
        let segments = JournalTextPartitioner.segments(job.rawText)
        var parts: [JSONValue] = []
        let sourceJournal = try job.source.journal()
        var priorBytes = sourceJournal.previousTextByteCount
        for (index, text) in segments.enumerated() {
            try Task.checkCancellation()
            var root = sourceJournal.payload.object!
            var entry = root["entry"]!.object!
            entry["raw_text"] = .string(text); entry["content_hash"] = .string(WorkspaceHash.sha256(text))
            if let remaining = priorBytes {
                let bytes = min(remaining, text.utf8.count)
                let prefix = String(decoding: text.utf8.prefix(bytes), as: UTF8.self)
                root["previous_reflection_text_bytes"] = .number(Double(bytes))
                root["previous_reflection_text_hash"] = .string(WorkspaceHash.sha256(prefix))
                priorBytes = remaining - bytes
            } else {
                root.removeValue(forKey: "previous_reflection_text_bytes")
            }
            root["entry"] = .object(entry)
            let source = try WorkspaceRecord.make(key: job.source.key, kind: .journal, payload: .object(root))
            let part = try PhoneAnalysisJob(scope: job.scope, accountID: job.accountID, model: job.model, source: source,
                memoryHash: job.memoryHash, memoryContext: job.memoryContext,
                workContext: "Uzun günlüğün \(index + 1)/\(segments.count) bölümü. Bu bölümde bulunmayan ayrıntıları okuduğunu söyleme. Tüm bölümler kesilmeden ayrı ayrı değerlendirilecek ve uygulama sonuçları birleştirecek.",
                prompts: job.prompts, reasoningEffort: job.reasoningEffort, includeReflectionAnswers: index == segments.count - 1,
                reflectionAnswerSource: job.source)
            let result = try await run(part)
            parts.append(.object(["rawText": .string(text), "result": try JSONValue.parse(result.validatedJSON)]))
        }
        return try AnalysisCore.invoke("mergeJournalParts", json: JSONValue.object([
            "parts": .array(parts), "answers": .array(job.answers.map(JSONValue.string))]).canonical())
    }
}
