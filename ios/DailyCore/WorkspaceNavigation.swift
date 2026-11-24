import Foundation

public enum WorkspaceTab: Int, Sendable {
    case today, agenda, questions, maps, settings
}

/// An explicit journal destination opens the existing writer instead of stacking another editor.
public struct WorkspaceNavigation: Equatable, Sendable {
    public var tab: WorkspaceTab = .today
    public private(set) var journalDate: String
    public private(set) var journalRoute = 0

    public init(today: String) { journalDate = today }

    @discardableResult public mutating func showJournal(date: String) -> Bool {
        guard WorkspaceIdentity.validDate(date) else { return false }
        journalDate = date
        journalRoute += 1
        tab = .today
        return true
    }
}
