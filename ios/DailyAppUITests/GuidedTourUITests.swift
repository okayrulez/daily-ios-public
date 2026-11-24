import XCTest

@MainActor final class GuidedTourUITests: XCTestCase {
    private func launch(holdsAnalysis: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-tour-preview"]
        if holdsAnalysis { app.launchArguments.append("-daily-tour-hold-analysis") }
        app.launch()
        XCTAssertTrue(app.staticTexts["guided-tour-title"].waitForExistence(timeout: 10))
        return app
    }
    private func expect(_ title: String, in app: XCUIApplication, timeout: TimeInterval = 5) {
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch.waitForExistence(timeout: timeout), app.debugDescription)
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testActiveRehearsalUsesLogoAnimatedMapNoteAndAnswerDependentAgenda() {
        let app = launch()
        let next = app.buttons["guided-tour-next"]
        // The live workspace stays mounted behind the tutorial's own tab bar.
        let tour = app.descendants(matching: .any)["guided-tour-overlay"]
        let originalButtonPosition = next.frame.origin
        capture("tour-01-example-writer", app: app)
        next.tap()
        expect("Şimdi Daily logosuna dokun.", in: app)
        XCTAssertEqual(next.frame.minX, originalButtonPosition.x, accuracy: 1)
        XCTAssertEqual(next.frame.minY, originalButtonPosition.y, accuracy: 1)
        let logo = app.buttons["tour-daily-logo"]
        XCTAssertTrue(logo.isHittable)
        logo.tap()
        expect("Yeni bağlantıların oluştu.", in: app, timeout: 8)
        expect("Haritalar · Hareket", in: app)
        XCTAssertTrue(tour.tabBars.buttons["Haritalar"].isSelected)
        capture("tour-03-growing-map", app: app)
        let node = app.buttons["tour-map-node-tour-swimming"]
        guard node.wait(for: \.isHittable, toEqual: true, timeout: 5) else {
            XCTFail("The highlighted note must become tappable above the coach.\n" + app.debugDescription)
            return
        }
        XCTAssertGreaterThanOrEqual(node.frame.height, 44)
        node.tap()
        expect("Bir notun içini keşfet.", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "tour-note-window").firstMatch.exists)
        expect("Kaynak: Örnek günlük", in: app)
        capture("tour-04-linked-note", app: app)
        next.tap()
        expect("Hatırlatmayı sen seç.", in: app)
        XCTAssertTrue(tour.tabBars.buttons["Sorular"].isSelected)
        XCTAssertEqual(app.staticTexts["guided-tour-location"].label, "SORULAR · HATIRLATMAYI SEÇ")
        XCTAssertFalse(next.isEnabled)
        app.buttons["Örnek yanıt: Hayır"].tap()
        XCTAssertTrue(app.buttons["Örnek yanıt: Hayır"].isSelected)
        XCTAssertTrue(next.isEnabled)
        next.tap()
        expect("Planın ajandada.", in: app)
        expect("Örnek salı · 1 aktivite", in: app)
        XCTAssertTrue(tour.tabBars.buttons["Ajanda"].isSelected)
        capture("tour-05-agenda-no-reminder", app: app)
        app.buttons["guided-tour-back"].tap()
        expect("Hatırlatmayı sen seç.", in: app)
        app.buttons["Örnek yanıt: Evet"].tap()
        XCTAssertTrue(app.buttons["Örnek yanıt: Evet"].isSelected)
        next.tap()
        expect("Örnek salı · 2 aktivite", in: app)
        next.tap()
        expect("Günün duyguları da burada.", in: app)
        XCTAssertTrue(tour.tabBars.buttons["Ajanda"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["tour-emotion-day"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["tour-emotion-reflection"].exists)
        capture("tour-06-emotion-calendar", app: app)
        next.tap()
        expect("Duygularının akışını keşfet.", in: app)
        XCTAssertTrue(tour.tabBars.buttons["Ajanda"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["tour-emotion-flow"].exists)
        // Select by the language-independent event identity; verify its visible meaning separately.
        let events = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "emotion-event-tour-emotion-"))
        let feeling = events.matching(NSPredicate(format: "identifier ENDSWITH %@", ":0:workload")).firstMatch
        guard feeling.waitForExistence(timeout: 5) else {
            capture("tour-emotion-missing-event", app: app)
            XCTFail("The flow must expose its event buttons independently.\n" + app.debugDescription)
            return
        }
        XCTAssertEqual(events.count, 3, app.debugDescription)
        XCTAssertEqual(feeling.label, "İş yükü")
        XCTAssertTrue((feeling.value as? String ?? "").contains("Gerilim"))
        // SwiftUI may attach view metadata to a wrapper; the action must still be a
        // real native Button. Never substitute a coordinate tap on a generic view.
        let action = feeling.elementType == .button ? feeling : feeling.buttons.firstMatch
        guard action.waitForExistence(timeout: 2), action.isHittable else {
            capture("tour-emotion-blocked-event", app: app)
            XCTFail("The event must remain tappable above the coach.\n" + app.debugDescription)
            return
        }
        action.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tour-emotion-detail"].waitForExistence(timeout: 5))
        expect("“Bugün işte gerildim”", in: app)
        XCTAssertFalse(app.buttons["Bu gözlemi düzelt"].exists)
        XCTAssertTrue(app.buttons["Kapat"].waitForExistence(timeout: 5))
        app.buttons["Kapat"].tap()
        capture("tour-07-emotion-flow", app: app)
        next.tap()
        expect("Aynı güne geri dön.", in: app)
        XCTAssertTrue(tour.tabBars.buttons["Bugün"].isSelected)
        tour.buttons["Yeni not ekle"].tap()
        tour.buttons["Kapat"].tap()
        tour.buttons["Yeni not ekle"].tap()
        tour.buttons["Notu ekle"].tap()
        expect("Örnek not güne eklendi.", in: app)
        tour.buttons["Günün yorumunu gör"].tap()
        expect("Tavsiyeler", in: app)
        app.buttons["Kapat"].tap()
        tour.buttons["Ne değiştiğini gör"].tap()
        expect("17.30 · Yüzme hatırlatması", in: app)
        app.buttons["Kapat"].tap()
        next.tap()
        expect("Hafızanı yanında taşı.", in: app)
        XCTAssertTrue(tour.tabBars.buttons["Ayarlar"].isSelected)
        XCTAssertEqual(app.staticTexts["guided-tour-location"].label, "AYARLAR · HAFIZANI PAYLAŞ")
        capture("tour-settings-tab-highlight", app: app)
        app.buttons["tour-export-card"].tap()
        expect("Önce dosyanı yükle, sonra görevini ver.", in: app)
        expect("Ne için kullanacaksın?", in: app)
        XCTAssertFalse(app.staticTexts["daily-kisisel-baglam.md"].exists)
        capture("tour-06-context-export", app: app)
        next.tap()
        expect("İstersen cihazlarını eşitle.", in: app)
        let firebase = app.buttons["tour-connect-firebase"]
        XCTAssertTrue(firebase.isHittable)
        firebase.tap()
        XCTAssertTrue(app.buttons["setup-google-firebase"].waitForExistence(timeout: 5))
        app.buttons["tour-connection-return"].tap()
        expect("İstersen cihazlarını eşitle.", in: app)
        XCTAssertTrue(next.isEnabled)
        capture("tour-07-own-firebase", app: app)
        next.tap()
        expect("AI hesabın da senin.", in: app)
        capture("tour-08-own-chatgpt", app: app)
        app.buttons["guided-tour-back"].tap()
        expect("İstersen cihazlarını eşitle.", in: app)
        next.tap()
        expect("AI hesabın da senin.", in: app)
        XCTAssertFalse(next.isEnabled)
        XCTAssertFalse(app.buttons["guided-tour-skip"].exists)
        let chatGPT = app.buttons["tour-connect-chatgpt"]
        XCTAssertTrue(chatGPT.isHittable)
        chatGPT.tap()
        XCTAssertTrue(app.buttons["chatgpt-connect-account"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Bağlantı hata günlüğü"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Hesap: ")).firstMatch.exists)
        let help = app.buttons["chatgpt-diagnostics"]
        XCTAssertTrue(help.isHittable)
        help.tap()
        expect("Bağlantı hata günlüğü", in: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["chatgpt-manage-accounts"].waitForExistence(timeout: 5))
        app.buttons["tour-connection-return"].tap()
        expect("AI hesabın da senin.", in: app)
        XCTAssertFalse(next.isEnabled)
    }

    func testSocialProfileUsesOneFreeformFieldAndRequiresOptIn() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-social-preview"]
        app.launch()
        let editor = app.descendants(matching: .any).matching(identifier: "social-profile-introduction").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let consent = app.switches["social-research-consent"]
        XCTAssertEqual(consent.value as? String, "0")
        editor.tap()
        editor.typeText("Adim Deniz. Insta: @deniz, GitHub: deniz-dev.")
        XCTAssertTrue((editor.value as? String ?? "").contains("GitHub: deniz-dev"))
        XCTAssertEqual(consent.value as? String, "0")
    }

    func testSkipKeepsRealJournalAndDoesNotStartAnalysis() {
        let app = launch()
        app.buttons["guided-tour-next"].tap()
        app.buttons["guided-tour-skip"].tap()
        XCTAssertFalse(app.otherElements["guided-tour-overlay"].exists)
        let editor = app.descendants(matching: .any).matching(identifier: "journal-editor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse((editor.value as? String ?? "").contains("Salı ve perşembe 18.00’de yüzmek"))
        XCTAssertFalse(app.buttons["Analizi durdur"].exists)
    }

    func testSkipDuringSymbolicAnalysisCancelsTheRemainingRoute() {
        let app = launch(holdsAnalysis: true)
        app.buttons["guided-tour-next"].tap()
        app.buttons["tour-daily-logo"].tap()
        let analysis = app.descendants(matching: .any).matching(identifier: "guided-tour-analysis-window").firstMatch
        XCTAssertTrue(analysis.waitForExistence(timeout: 5))
        let skip = app.buttons["guided-tour-analysis-skip"]
        guard skip.wait(for: \.isHittable, toEqual: true, timeout: 5) else {
            XCTFail("The example analysis must offer a tappable skip button.\n" + app.debugDescription)
            return
        }
        capture("tour-02-symbolic-analysis", app: app)
        skip.tap()
        let editor = app.descendants(matching: .any).matching(identifier: "journal-editor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Haritalar · Hareket"].exists)
        XCTAssertFalse(app.otherElements["guided-tour-overlay"].exists)
    }
}
