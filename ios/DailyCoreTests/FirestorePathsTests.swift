import XCTest
@testable import DailyCore

final class FirestorePathsTests: XCTestCase {
    func testBuildsOwnerScopedDayAndQuestionPaths() {
        XCTAssertEqual(
            FirestorePaths.day(uid: "user-42", localDate: "2026-08-30"),
            "users/user-42/days/2026-08-30"
        )
        XCTAssertEqual(
            FirestorePaths.questions(uid: "user-42", localDate: "2026-08-30"),
            "users/user-42/days/2026-08-30/questions"
        )
        XCTAssertEqual(
            FirestorePaths.processingJob(uid: "user-42", jobID: "job-1"),
            "users/user-42/processingJobs/job-1"
        )
    }

    func testRejectsPathSegmentsThatCouldEscapeTheOwnerScope() {
        XCTAssertThrowsError(try FirestorePaths.validatedSegment("../other-user"))
        XCTAssertThrowsError(try FirestorePaths.validatedSegment("contains/slash"))
        XCTAssertNoThrow(try FirestorePaths.validatedSegment("user_42-okay"))
    }
}
