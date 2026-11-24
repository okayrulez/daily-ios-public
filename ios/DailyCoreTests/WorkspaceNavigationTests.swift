import XCTest
@testable import DailyCore

final class WorkspaceNavigationTests: XCTestCase {
    func testCalendarOpensExactHistoricalDayInTodayAndCanReturnToToday() {
        var navigation = WorkspaceNavigation(today: "2026-11-04")
        navigation.tab = .agenda
        XCTAssertTrue(navigation.showJournal(date: "2026-09-28"))
        XCTAssertEqual(navigation.tab, .today)
        XCTAssertEqual(navigation.journalDate, "2026-09-28")
        let priorRoute = navigation.journalRoute
        XCTAssertTrue(navigation.showJournal(date: "2026-11-04"))
        XCTAssertEqual(navigation.journalDate, "2026-11-04")
        XCTAssertGreaterThan(navigation.journalRoute, priorRoute)
    }

    func testInvalidCalendarDestinationDoesNotChangeVisibleJournal() {
        var navigation = WorkspaceNavigation(today: "2026-11-04")
        navigation.tab = .agenda
        let before = navigation
        XCTAssertFalse(navigation.showJournal(date: "2026-02-31"))
        XCTAssertEqual(navigation, before)
        XCTAssertFalse(navigation.showJournal(date: "journal:2026-11-04"))
        XCTAssertEqual(navigation, before)
    }

    func testAccountResetDoesNotRetainAnotherAccountsHistoricalDay() {
        var navigation = WorkspaceNavigation(today: "2026-11-04")
        navigation.showJournal(date: "2026-09-28")
        navigation = WorkspaceNavigation(today: "2026-11-04")
        XCTAssertEqual(navigation.tab, .today)
        XCTAssertEqual(navigation.journalDate, "2026-11-04")
        XCTAssertEqual(navigation.journalRoute, 0)
    }
}
