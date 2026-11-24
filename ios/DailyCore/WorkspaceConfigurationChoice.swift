import Foundation

public enum WorkspaceConfigurationChoice: Equatable {
    case personal, ownerBuild, unconfigured

    public static func select(hasPersonalFile: Bool, personalValid: Bool,
                              declaredProject: String?, bundledProject: String?) -> Self {
        // A broken saved selection must never switch the user to another database.
        if hasPersonalFile { return personalValid ? .personal : .unconfigured }
        guard let declaredProject, !declaredProject.isEmpty,
              declaredProject == bundledProject else { return .unconfigured }
        return .ownerBuild
    }
}
