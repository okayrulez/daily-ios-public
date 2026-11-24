import Foundation

/// Admin-authored instructions frozen for the duration of an analysis. Never contains user data.
public struct AnalysisPromptConfiguration: Sendable {
    public static let documentPath = "dailyXConfig/analysisPrompts"
    public static let taskDocumentPath = "dailyXConfig/taskPrompts"
    public static let bundled = AnalysisPromptConfiguration()
    public let revision: String
    private let stages: [String: String]
    public let fingerprint: String

    private init() {
        revision = "bundled"
        stages = [:]
        fingerprint = "bundled"
    }

    public init(json: String) throws {
        guard json.utf8.count <= 100_000, let value = try JSONValue.parse(json).object,
              Set(value.keys).isSubset(of: ["schemaVersion", "revision", "enabled", "instructions"]),
              value["schemaVersion"] == .number(1),
              let revision = value["revision"]?.string,
              revision.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil,
              let enabled = value["enabled"], (enabled == .bool(true) || enabled == .bool(false)),
              let entries = value["instructions"]?.object,
              Set(entries.keys).isSubset(of: ["journal", "questionRepair", "crossMap", "crossMapRepair", "routeTask", "executeTask", "mapQuestions", "mapLinks"])
        else { throw AnalysisPromptConfigurationError.invalidConfiguration }
        var stages: [String: String] = [:]
        for (key, entry) in entries {
            guard let text = entry.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 20_000 else { throw AnalysisPromptConfigurationError.invalidConfiguration }
            stages[key] = text
        }
        self.revision = enabled == .bool(true) ? revision : "bundled"
        self.stages = enabled == .bool(true) ? stages : [:]
        fingerprint = enabled == .bool(true) ? WorkspaceHash.sha256(try JSONValue.object(value).canonical()) : "bundled"
    }

    public func applying(to preparedJSON: String, stage: String, usageStage: String? = nil) throws -> String {
        guard var prepared = try JSONValue.parse(preparedJSON).object else { throw AnalysisCoreError.invalidOutput }
        prepared["usageStage"] = .string(usageStage ?? stage)
        guard let instructions = stages[stage] else { return try JSONValue.object(prepared).canonical() }
        let original = prepared["instructions"]?.string ?? ""
        if stage == "routeTask" || stage == "executeTask" || stage == "mapQuestions" || stage == "mapLinks" || stage == "crossMap" || stage == "crossMapRepair" {
            prepared["instructions"] = .string("Daily yöneticisinin görev yönergeleri:\n" + instructions + "\n\nUygulamanın araç, kanıt ve çıktı sözleşmesi:\n" + original)
            return try JSONValue.object(prepared).canonical()
        }
        // Keep editable guidance together with the bundled evidence, consent and output contract.
        prepared["instructions"] = .string(instructions + "\n\nYanıt, verilen çıktı şemasına uygun tek JSON nesnesi olmalı. Sağlanmayan araçları kullandığını veya okumadığın kaynakları araştırdığını söyleme. Kaynak alıntıları gerçek ve birebir olmalı." + "\n\nUygulamanın kanıt, onay ve çıktı kuralları:\n" + original)
        return try JSONValue.object(prepared).canonical()
    }

    public func addingTaskInstructions(json: String) throws -> AnalysisPromptConfiguration {
        let tasks = try AnalysisPromptConfiguration(json: json)
        guard Set(tasks.stages.keys).isSubset(of: ["routeTask", "executeTask"]) else {
            throw AnalysisPromptConfigurationError.invalidConfiguration
        }
        return AnalysisPromptConfiguration(revision: revision + "/" + tasks.revision,
            stages: stages.merging(tasks.stages) { _, new in new },
            fingerprint: WorkspaceHash.sha256(fingerprint + ":" + tasks.fingerprint))
    }

    private init(revision: String, stages: [String: String], fingerprint: String) {
        self.revision = revision; self.stages = stages; self.fingerprint = fingerprint
    }
}

public enum AnalysisPromptConfigurationError: Error { case invalidConfiguration }
