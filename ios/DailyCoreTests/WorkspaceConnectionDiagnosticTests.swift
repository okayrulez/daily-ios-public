import Foundation
import XCTest
@testable import DailyCore

final class WorkspaceConnectionDiagnosticTests: XCTestCase {
    func testPermissionDeniedIsNotReportedAsAnInternetFailure() {
        let message = WorkspaceConnectionDiagnostic.firestore(NSError(domain: "FIRFirestoreErrorDomain", code: 7))
        XCTAssertTrue(message.contains("FIRESTORE_7"))
        XCTAssertTrue(message.contains("erişim reddedildi"))
        XCTAssertFalse(message.contains("ağ veya servis"))
    }

    func testUnavailableIsDistinguishedFromMissingSession() {
        let unavailable = WorkspaceConnectionDiagnostic.firestore(NSError(domain: "FIRFirestoreErrorDomain", code: 14))
        let unauthenticated = WorkspaceConnectionDiagnostic.firestore(NSError(domain: "FIRFirestoreErrorDomain", code: 16))
        XCTAssertTrue(unavailable.contains("ağ veya servis"))
        XCTAssertTrue(unauthenticated.contains("oturumu doğrulanamadı"))
        XCTAssertNotEqual(unavailable, unauthenticated)
    }

    func testDoesNotExposeUserInfoOrUnknownDomain() {
        let marker = "secret-password-token-journal"
        let error = NSError(domain: marker, code: 7, userInfo: [NSLocalizedDescriptionKey: marker])
        let message = WorkspaceConnectionDiagnostic.firestore(error)
        XCTAssertFalse(message.contains(marker))
        XCTAssertFalse(message.contains("FIRESTORE_7"))
    }

    func testValidationAndAbsentSnapshotAreNotClaimedAsNetworkErrors() {
        XCTAssertTrue(WorkspaceConnectionDiagnostic.firestore(WorkspaceError.invalidHash).contains("WORKSPACE_VALIDATION"))
        XCTAssertTrue(WorkspaceConnectionDiagnostic.firestore(nil).contains("FIRESTORE_SNAPSHOT"))
    }
}
