import Foundation
import XCTest
@testable import DailyCore

final class WorkspaceAuthDiagnosticTests: XCTestCase {
    func testInvalidCredentialsOfferRegistrationWithoutClaimingNetworkFailure() {
        let generic = WorkspaceConnectionDiagnostic.auth(NSError(domain: "FIRAuthErrorDomain", code: 17004))
        for code in [17004, 17009, 17011] {
            let message = WorkspaceConnectionDiagnostic.auth(NSError(domain: "FIRAuthErrorDomain", code: code))
            XCTAssertTrue(message.contains("Hesap oluştur"))
            XCTAssertFalse(message.contains("internet"))
            XCTAssertEqual(message, generic)
        }
    }

    func testProviderDisabledAndNetworkErrorsHaveDifferentActions() {
        XCTAssertTrue(WorkspaceConnectionDiagnostic.auth(NSError(domain: "FIRAuthErrorDomain", code: 17006)).contains("etkin değil"))
        XCTAssertTrue(WorkspaceConnectionDiagnostic.auth(NSError(domain: "FIRAuthErrorDomain", code: 17020)).contains("internet"))
    }

    func testUnknownAuthErrorDoesNotExposeServerOrCredentialDetails() {
        let error = NSError(domain: "SECRET_DOMAIN", code: 999, userInfo: [NSLocalizedDescriptionKey: "SECRET_TOKEN"])
        XCTAssertFalse(WorkspaceConnectionDiagnostic.auth(error).contains("SECRET"))
    }
}
