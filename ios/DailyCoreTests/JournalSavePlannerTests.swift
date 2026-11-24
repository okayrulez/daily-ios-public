import Foundation
import XCTest
@testable import DailyCore

final class JournalSavePlannerTests: XCTestCase {
    func testFirstSaveCreatesRevisionOneAndInitialJob() throws {
        let plan = try JournalSavePlanner.plan(
            current: nil,
            localDate: "2026-08-30",
            rawText: "Bugün daha sakindim.",
            expectedRevision: 0,
            deviceID: "iphone-1",
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(plan.day.revision, 1)
        XCTAssertEqual(plan.day.answerRevision, 0)
        XCTAssertEqual(plan.day.status, .queued)
        XCTAssertEqual(plan.day.processingReason, .initial)
        XCTAssertEqual(plan.jobID, "2026-08-30-initial-r1-a0")
        XCTAssertEqual(plan.job.sourceRevision, 1)
    }

    func testStaleRevisionRaisesConflictInsteadOfOverwriting() {
        let current = DaySnapshot.fixture(localDate: "2026-08-30", revision: 3)

        XCTAssertThrowsError(
            try JournalSavePlanner.plan(
                current: current,
                localDate: "2026-08-30",
                rawText: "Yeni metin",
                expectedRevision: 2,
                deviceID: "iphone-1",
                now: Date(timeIntervalSince1970: 100)
            )
        ) { error in
            XCTAssertEqual(error as? JournalSaveError, .revisionConflict(serverRevision: 3))
        }
    }
}
