import Foundation
import DailyCore
@preconcurrency import FirebaseAuth
@preconcurrency import FirebaseFirestore

extension FirebaseWorkspace {
    func fetchAnalysisPrompts(scope: WorkspaceRequestScope) async throws -> AnalysisPromptConfiguration {
        guard requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else {
            throw WorkspaceRequestError.accountChanged
        }
        async let journalDocument = promptDocument(AnalysisPromptConfiguration.documentPath, scope: scope)
        async let taskDocument = promptDocument(AnalysisPromptConfiguration.taskDocumentPath, scope: scope)
        let (journal, tasks) = try await (journalDocument, taskDocument)
        var configuration = AnalysisPromptConfiguration.bundled
        if let journal { configuration = try AnalysisPromptConfiguration(json: journal) }
        if let tasks { configuration = try configuration.addingTaskInstructions(json: tasks) }
        return configuration
    }

    private func promptDocument(_ path: String, scope: WorkspaceRequestScope) async throws -> String? {
        let snapshot = try await database.document(path).getDocument(source: .server)
        guard requestGate.accepts(scope, authenticatedUID: Auth.auth().currentUser?.uid) else {
            throw WorkspaceRequestError.accountChanged
        }
        guard let fields = snapshot.data() else { return nil }
        guard JSONSerialization.isValidJSONObject(fields) else { throw AnalysisPromptConfigurationError.invalidConfiguration }
        return String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }
}
