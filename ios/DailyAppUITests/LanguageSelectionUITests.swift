import XCTest

@MainActor final class LanguageSelectionUITests: XCTestCase {
    func testLanguageSelectionPrecedesTourAndPersistsAcrossLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-language-preview"]
        app.launch()
        let english = app.buttons["language-option-en"]
        XCTAssertTrue(english.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["guided-tour-overlay"].exists)
        english.tap()
        app.buttons["language-confirm"].tap()
        XCTAssertTrue(app.staticTexts["Try a sample journal."].waitForExistence(timeout: 5))
        app.buttons["guided-tour-skip"].tap()
        XCTAssertTrue(app.buttons["tour-connect-chatgpt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["guided-tour-skip"].exists)
        app.buttons["guided-tour-next"].tap()
        XCTAssertTrue(app.buttons["chatgpt-connect-account"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(english.waitForExistence(timeout: 10))
        XCTAssertTrue(english.isSelected)
        app.buttons["language-option-tr"].tap()
        app.buttons["language-confirm"].tap()
        XCTAssertTrue(app.staticTexts["Örnek bir günlükle dene."].waitForExistence(timeout: 5))
        app.buttons["guided-tour-skip"].tap()
        XCTAssertTrue(app.buttons["tour-connect-chatgpt"].waitForExistence(timeout: 5))
    }
}
