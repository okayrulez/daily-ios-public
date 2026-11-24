import DailyCore
import Foundation
import WidgetKit

enum DailyAppleRoute: Equatable {
    case newNote
    case reflection(String)
    case agenda(String)

    init?(url: URL) {
        guard url.scheme == "dailyx" else { return nil }
        if url.host == "new-note" { self = .newNote; return }
        guard let date = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "date" })?.value,
            WorkspaceIdentity.validDate(date) else { return nil }
        switch url.host {
        case "reflection": self = .reflection(date)
        case "agenda": self = .agenda(date)
        default: return nil
        }
    }
}

extension WorkspaceModel {
    func openAppleSurface(_ url: URL) -> Bool {
        guard let route = DailyAppleRoute(url: url) else { return false }
        pendingAppleRoute = route
        return true
    }

    func refreshJournalWidget() {
        let date = Self.today
        let snapshot = uid.flatMap { _ in journal(date: date)?.dayReflection }
            .map { DailyWidgetSnapshot(date: date, reflection: $0) }
        if DailyWidgetSnapshot.publish(snapshot) {
            WidgetCenter.shared.reloadTimelines(ofKind: "DailyReflection")
        }
    }
}
