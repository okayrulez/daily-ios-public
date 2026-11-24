import XCTest
@testable import DailyCore

final class GoogleProjectSetupTests: XCTestCase {
    func testDisplayNameAcceptsTurkishInputWithoutSendingInvalidCharacters() {
        XCTAssertEqual(GoogleProjectSetup.displayName("dAIly kişisel alanım"), "dAIly kisisel alanim")
        XCTAssertEqual(GoogleProjectSetup.displayName("  İşi şıkça örgütle 😊  "), "Isi sikca orgutle")
        XCTAssertEqual(GoogleProjectSetup.displayName("😊"), "dAIly Personal")
        XCTAssertEqual(GoogleProjectSetup.displayName("abc"), "dAIly abc")
        XCTAssertEqual(GoogleProjectSetup.displayName(String(repeating: "a", count: 50)).count, 30)
    }

    func testEnableServiceUsesNumericProjectResource() throws {
        XCTAssertEqual(try GoogleProjectSetup.serviceEnableURL(projectNumber: "123456789012"),
                       "https://serviceusage.googleapis.com/v1/projects/123456789012/services/firestore.googleapis.com:enable")
        XCTAssertThrowsError(try GoogleProjectSetup.serviceEnableURL(projectNumber: "daily-project"))
        XCTAssertThrowsError(try GoogleProjectSetup.serviceEnableURL(projectNumber: ""))
        XCTAssertThrowsError(try GoogleProjectSetup.serviceEnableURL(projectNumber: "123/other"))
    }
}
