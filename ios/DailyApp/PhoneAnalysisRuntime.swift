import Foundation
import DailyCore

actor PhoneAnalysisRuntime {
    private let client: ChatGPTInferenceClient
    let memories: MemoryStore
    let outbox: PhoneAnalysisOutbox
    let profileOutbox: PhoneAnalysisOutbox
    let coordinator: PhoneAnalysisCoordinator
    let tasks: PhoneTaskCoordinator
    init(client: ChatGPTInferenceClient) throws {
        self.client = client
        let root=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        memories=try MemoryStore(root:root.appendingPathComponent("DailyXMemory",isDirectory:true))
        outbox=try PhoneAnalysisOutbox(root:root.appendingPathComponent("DailyXOutbox",isDirectory:true))
        profileOutbox=try PhoneAnalysisOutbox(root:root.appendingPathComponent("DailyXProfileOutbox",isDirectory:true))
        coordinator=try PhoneAnalysisCoordinator(root:root.appendingPathComponent("DailyXResults",isDirectory:true)) { model,prompt in
            try await client.infer(model:model,preparedJSON:prompt)
        }
        tasks=try PhoneTaskCoordinator(root:root.appendingPathComponent("DailyXTasks",isDirectory:true)) { model,prompt in
            try await client.infer(model:model,preparedJSON:prompt)
        }
    }
    func mapQuestions(model: String, reasoningEffort: String? = nil, nodes: JSONValue, prompts: AnalysisPromptConfiguration) async throws -> JSONValue {
        let prepared = try AnalysisCore.invoke("prepareMapQuestions", json: JSONValue.object(["nodes": nodes]).canonical())
        let configured = try prompts.applying(to: prepared, stage: "mapQuestions")
        let raw = try await client.infer(model: model, preparedJSON: ChatGPTModel.applyingReasoning(reasoningEffort, to: configured))
        let validated = try await AnalysisCore.validateModelResponse(raw, prepared: configured, command: "validateMapQuestions",
            reasoningEffort: reasoningEffort, infer: { try await self.client.infer(model: model, preparedJSON: $0) }) {
            try AnalysisCore.invoke("validateMapQuestions", json: $0)
        }
        return try JSONValue.parse(validated)
    }
    func prepare(scope: MemoryScope, accountID: String, model: String, source: WorkspaceRecord,
                 remoteMemory: PortableMemory?, manifest: WorkspaceRecord?, experience: String = "[]", suppressedQuestionPrompts: [String] = [],
                 prompts: AnalysisPromptConfiguration = .bundled, reasoningEffort: String? = nil,
                 onProgress: @Sendable (String) async -> Void = { _ in },
                 onReply: @Sendable (String) async -> Void = { _ in }) async throws -> PhoneAnalysisCommit {
        let targetOutbox = source.isProfileResearch ? profileOutbox : outbox
        if let pending=try await targetOutbox.load(scope:scope) { return pending }
        let local=try await memories.load(scope:scope)
        if let manifest,remoteMemory == nil {
            guard let text=try manifest.payload().string,
                  let expected=try JSONValue.parse(text).object?["memoryHash"]?.string,
                  local?.contentHash==expected else { throw WorkspaceError.conflict }
        }
        if let local,let remoteMemory,local.revision>remoteMemory.revision,local.contentHash != remoteMemory.contentHash {
            throw WorkspaceError.conflict
        }
        let memory: PortableMemory
        if let remoteMemory { memory=remoteMemory }
        else if let local { memory=local }
        else { memory=try PortableMemory(json:AnalysisCore.invoke("emptyMemory",json:"{}")) }
        let journal = try source.analysisJournal()
        let contextInput=try JSONValue.object(["memory":JSONValue.parse(memory.json),"journal":journal.payload,
            "feedback":.string(experience)]).canonical()
        guard let context=try JSONValue.parse(AnalysisCore.invoke("selectContext",json:contextInput)).object?["context"]?.string else {
            throw AnalysisCoreError.invalidOutput
        }
        let job=try PhoneAnalysisJob(scope:scope,accountID:accountID,model:model,source:source,
            memoryHash:memory.contentHash,memoryContext:context,workContext:"DailyX task-router-v2. Güncel yazı ve yanıtları tam değerlendir; geçmiş küme özetlerini yalnız ilgili bağlam olarak kullan.",prompts:prompts,reasoningEffort:reasoningEffort)
        await coordinator.activate(scope:scope,accountID:accountID)
        // Oversized diary input is processed completely in resumable parts, not sent through the
        // single-request task router whose provider context cannot contain the whole journal.
        let taskResult: PhoneAnalysisResult?
        if !source.isProfileResearch && (job.rawText.utf8.count > 180_000 || journal.isFinishingDayReflection) {
            taskResult = nil
        } else {
            taskResult = try await tasks.run(job, source: source, memory: memory, onProgress: onProgress)
        }
        let result: PhoneAnalysisResult
        if let taskResult { result=taskResult }
        else {
            guard !source.isProfileResearch else { throw AnalysisCoreError.invalidOutput }
            let stage = job.finishingQuestionSession ? "DAY_REFLECTION" : "JOURNAL_ANALYSIS"
            await onProgress(job.rawText.utf8.count > 180_000 ? "LONG_JOURNAL_ANALYSIS" : stage)
            result=try await coordinator.run(job)
        }
        try Task.checkCancellation()
        let plan = try PhoneAnalysisCommit(job:job,result:result,source:source,memory:memory,expectedManifest:manifest,
            now:result.createdAt,uploadMemory:true,suppressedQuestionPrompts:suppressedQuestionPrompts)
        try await targetOutbox.save(plan,scope:scope)
        let savedJournal = try plan.journal.analysisJournal()
        if !savedJournal.awaitsDayReflectionQuestions {
            let savedTask = savedJournal.payload.object?["daily_task"]
            await onReply(try savedTask?.canonical() ?? result.validatedJSON)
        }
        return plan
    }
    func completed(_ plan: PhoneAnalysisCommit, scope: MemoryScope) async throws {
        try await cacheCommittedMemory(plan.memory, scope: scope)
        let targetOutbox = plan.source.isProfileResearch ? profileOutbox : outbox
        if let pending = try await targetOutbox.load(scope: scope) {
            guard pending.jobID == plan.jobID else { throw WorkspaceError.conflict }
            try await targetOutbox.remove(jobID:plan.jobID,scope:scope)
        }
    }

    func cacheCommittedMemory(_ memory: PortableMemory, scope: MemoryScope) async throws {
        let current=try await memories.load(scope:scope)
        if let current,current.revision==memory.revision,current.contentHash != memory.contentHash {
            throw WorkspaceError.conflict
        }
        if current == nil || current!.revision<memory.revision {
            try await memories.save(memory,expectedHash:current?.contentHash,scope:scope)
        }
    }

    func hasPendingCommits(scope: MemoryScope) async throws -> Bool {
        if try await outbox.load(scope: scope) != nil { return true }
        return try await profileOutbox.load(scope: scope) != nil
    }

    func prepareFunctional(scope: MemoryScope, source: WorkspaceRecord, remoteMemory: PortableMemory?,
                           manifest: WorkspaceRecord?) async throws -> PhoneAnalysisCommit {
        if let pending = try await outbox.load(scope: scope) {
            guard pending.source.key == source.key,
                  pending.execution == "functional" else {
                throw PhoneAnalysisError.alreadyRunning
            }
            return pending
        }
        let local = try await memories.load(scope: scope)
        if let local, let remoteMemory, local.revision > remoteMemory.revision, local.contentHash != remoteMemory.contentHash {
            throw WorkspaceError.conflict
        }
        let memory = try remoteMemory ?? local ?? PortableMemory(json: AnalysisCore.invoke("emptyMemory", json: "{}"))
        if let manifest, remoteMemory == nil {
            guard let text = try manifest.payload().string,
                  try JSONValue.parse(text).object?["memoryHash"]?.string == memory.contentHash else { throw WorkspaceError.conflict }
        }
        let plan = try PhoneAnalysisCommit.functional(scope: scope, source: source, memory: memory,
            manifest: manifest, now: ISO8601DateFormatter().string(from: Date()))
        try await outbox.save(plan, scope: scope)
        return plan
    }
}
