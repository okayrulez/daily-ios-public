import Foundation

/// A failed local identity check is not a network timeout. Never attach account IDs or text.
public struct AnalysisScopeGuardFailure: Error, Equatable, Sendable {
    public enum Reason: String, Sendable { case sessionChanged = "analysis_session_changed"
        case workspaceChanged = "analysis_workspace_changed", aiAccountChanged = "analysis_ai_account_changed"
        case aiUnavailable = "analysis_ai_unavailable" }
    public enum Phase: String, Sendable { case beforePreparation = "before_preparation", beforeInference = "before_inference"
        case afterInference = "after_inference", beforeCommit = "before_commit", afterCommit = "after_commit" }
    public let reason: Reason
    public let phase: Phase
}

public enum AnalysisScopeGuard {
    public static func check(sessionMatches: Bool, workspaceMatches: Bool, accountMatches: Bool = true,
                             aiReady: Bool = true, phase: AnalysisScopeGuardFailure.Phase) throws {
        let reason: AnalysisScopeGuardFailure.Reason?
        if !sessionMatches { reason = .sessionChanged }
        else if !workspaceMatches { reason = .workspaceChanged }
        else if !accountMatches { reason = .aiAccountChanged }
        else if !aiReady { reason = .aiUnavailable }
        else { reason = nil }
        if let reason { throw AnalysisScopeGuardFailure(reason:reason,phase:phase) }
    }
}
