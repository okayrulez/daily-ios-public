import XCTest

@MainActor final class JournalFlowUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-flow-preview"]
        app.launch()
        return app
    }

    func testEditorKeepsFocusAndBackgroundTapDismissesKeyboard() {
        let app = launch()
        let editor = app.descendants(matching: .any).matching(identifier: "journal-editor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText(" Bir not daha.")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Typing must retain focus before any second tap")
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Tapping the input must not dismiss its keyboard")
        app.staticTexts["journal-date"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Klavyeyi kapat"].exists)
    }

    func testFirstKeystrokeAndDeletingBackToEmptyKeepKeyboardOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-flow-preview", "-daily-writing-empty"]
        app.launch()
        let editor = app.textViews["journal-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "")
        XCTAssertFalse(app.buttons["journal-add-note"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["journal-view-changes"].exists)
        XCTAssertFalse(app.buttons["journal-view-reflection"].exists)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("a")
        XCTAssertEqual(editor.value as? String, "a")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "First character and placeholder removal must not dismiss the keyboard")
        // Wait for the draft-driven SwiftUI refresh before sending the next key.
        let draftStatus = app.staticTexts["Taslak bu cihazda korundu. Henüz günlük kaydına uygulanmadı."]
        XCTAssertTrue(draftStatus.waitForExistence(timeout: 5))
        app.typeText("b")
        XCTAssertEqual(editor.value as? String, "ab", "Keep typing without tapping the editor again")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
        XCTAssertEqual(editor.value as? String, "")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Restoring the empty placeholder must not dismiss the keyboard")
        app.typeText("c")
        XCTAssertEqual(editor.value as? String, "c")
        app.staticTexts["journal-date"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("d")
        // A fresh tap may place UIKit's caret on either side of this short text.
        // Refocusing must retain the draft; subsequent keys must follow that caret
        // without another tap or a SwiftUI refresh moving it.
        let resumed = editor.value as? String ?? ""
        XCTAssertTrue(resumed == "cd" || resumed == "dc", "Refocusing must preserve the existing character")
        app.typeText("e")
        XCTAssertEqual(editor.value as? String, resumed.replacingOccurrences(of: "d", with: "de"))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    func testEmotionsAppearOnTheRealMapNotes() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-flow-preview", "-daily-emotion-timeline-preview"]
        app.launch()
        app.tabBars.buttons["Haritalar"].tap()
        XCTAssertFalse(app.buttons["Duygu haritası"].exists)
        let map = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "atlas-open-map-")).firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 10))
        map.tap()
        let note = app.buttons["atlas-node-n0"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.tap()
        XCTAssertTrue(app.descendants(matching: .any)["atlas-note-emotions"].waitForExistence(timeout: 5))
    }

    func testLongJournalStaysEditableInABoundedViewport() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-flow-preview", "-daily-writing-long"]
        app.launch()
        let editor = app.textViews["journal-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertLessThan(editor.frame.height, 400)
        XCTAssertTrue((editor.value as? String ?? "").contains("Uzun günlüğün son satırı."))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("YeniNot")
        let edited = editor.value as? String ?? ""
        XCTAssertTrue(edited.contains("YeniNot"))
        XCTAssertTrue(edited.contains("Uzun günlüğün son satırı."))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.staticTexts["journal-date"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    func testLongWrittenAnswerRemainsEditableAndDoesNotGrowOffscreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-flow-preview", "-daily-answers-preview", "-daily-answer-long"]
        app.launch()
        app.tabBars.buttons["Sorular"].tap()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = app.buttons["questions-day-" + formatter.string(from: Date())]
        XCTAssertTrue(day.waitForExistence(timeout: 10)); day.tap()
        let editor = app.textViews["question-answer-preview-open"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertLessThan(editor.frame.height, 300)
        if !editor.isHittable { app.swipeUp() }
        editor.tap()
        app.typeText("YeniYanıt")
        let edited = editor.value as? String ?? ""
        XCTAssertTrue(edited.contains("YeniYanıt"))
        XCTAssertTrue(edited.contains("Yanıtın son satırı."))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    func testSavedFirstNoteOffersAddNoteBeforeAnalysisCompletes() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-flow-preview", "-daily-writing-saved"]
        app.launch()
        let addNote = app.buttons["journal-add-note"]
        XCTAssertTrue(addNote.waitForExistence(timeout: 10))
        XCTAssertFalse(app.textViews["journal-editor"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["journal-view-changes"].exists)
        XCTAssertFalse(app.buttons["journal-view-reflection"].exists)
        addNote.tap()
        XCTAssertTrue(app.textViews["journal-new-note-editor"].waitForExistence(timeout: 5))
    }

    func testAnalyzedJournalOpensReflectionAndNewNoteFromCompactActions() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-flow-preview", "-daily-emotion-timeline-preview"]
        app.launch()
        let reflection = app.buttons["journal-view-reflection"]
        let addNote = app.buttons["journal-add-note"]
        XCTAssertTrue(reflection.waitForExistence(timeout: 10))
        XCTAssertTrue(addNote.exists)
        XCTAssertTrue(app.descendants(matching: .any)["journal-view-changes"].exists)
        XCTAssertFalse(app.textViews["journal-editor"].exists)
        reflection.tap()
        XCTAssertTrue(app.staticTexts["Sunumdan sonra rahatladın."].waitForExistence(timeout: 5))
        app.buttons["Kapat"].tap()

        if !addNote.isHittable { app.swipeUp() }
        addNote.tap()
        let editor = app.textViews["journal-new-note-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(addNote.exists)
        XCTAssertTrue(app.staticTexts["journal-date"].exists)
        editor.tap()
        app.typeText("Ek bir not.")
        app.buttons["journal-close-note"].tap()
        XCTAssertTrue(addNote.waitForExistence(timeout: 5))
        XCTAssertEqual(addNote.label, "Yeni not ekle")
        addNote.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Ek bir not.")
        if !app.buttons["journal-append-note"].isHittable { app.swipeUp() }
        app.buttons["journal-append-note"].tap()
        XCTAssertTrue(addNote.waitForExistence(timeout: 5))
        XCTAssertFalse(editor.exists)
        addNote.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["journal-edit-existing"].exists)
        XCTAssertFalse((editor.value as? String ?? "").contains("Ek bir not."))
    }

    func testCompletedReflectionOpensOnceAndRemainsAvailableFromItsCard() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-flow-preview", "-daily-emotion-timeline-preview", "-daily-completed-reflection-preview"]
        app.launch()

        let comment = app.staticTexts["journal-reflection-text"]
        XCTAssertTrue(comment.waitForExistence(timeout: 10))
        XCTAssertEqual(comment.label, "Sunumdan sonra rahatladın.")
        app.buttons["Kapat"].tap()
        XCTAssertTrue(comment.waitForNonExistence(timeout: 5))

        let card = app.buttons["journal-view-reflection"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(comment.waitForExistence(timeout: 5))
    }

    func testDraggingWriterDismissesKeyboard() {
        let app = launch()
        let editor = app.descendants(matching: .any).matching(identifier: "journal-editor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        // The first ScrollView may be the keyboard's 44pt accessory strip.
        // Target the journal itself, in the visible area above the keyboard.
        let top = editor.frame.minY + 24
        let bottom = min(editor.frame.maxY, keyboard.frame.minY) - 24
        XCTAssertGreaterThan(bottom - top, 60, "The visible writer must have room to scroll")
        print("Writer drag: editor=\(editor.frame), keyboard=\(keyboard.frame), startY=\(bottom), endY=\(top)")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: editor.frame.midX, dy: bottom))
        let end = origin.withOffset(CGVector(dx: editor.frame.midX, dy: top))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    func testWriterRetainsFirstSentenceWhileTypingAndDismissingKeyboard() {
        let app=launch()
        let editor=app.textViews["journal-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout:10))
        let original=editor.value as? String ?? ""
        let firstSentence=String(original.prefix(80))
        XCTAssertFalse(firstSentence.isEmpty)
        XCTAssertTrue(editor.isHittable)
        editor.tap()
        app.typeText(" Bir devam notu.")
        XCTAssertTrue((editor.value as? String ?? "").contains(firstSentence))
        app.staticTexts["journal-date"].tap()
        app.swipeDown()
        XCTAssertTrue(editor.waitForExistence(timeout:5))
        XCTAssertTrue((editor.value as? String ?? "").contains(firstSentence))
    }

    func testWriterRetainsDraftAcrossNotificationsAndBackground() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-flow-preview", "-daily-writing-empty"]
        app.launch()
        let editor = app.textViews["journal-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        app.typeText("First line.\nSecond line.")
        let draft = "First line.\nSecond line."
        XCTAssertEqual(editor.value as? String, draft)

        app.buttons["workspace-notifications"].tap()
        XCTAssertTrue(app.buttons["Kapat"].waitForExistence(timeout: 5))
        app.buttons["Kapat"].tap()
        XCTAssertEqual(editor.value as? String, draft)

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, draft)
        editor.tap()
        app.typeText("Z")
        let continuedDraft = editor.value as? String ?? ""
        XCTAssertEqual(continuedDraft.replacingOccurrences(of: "Z", with: ""), draft)
        XCTAssertTrue(continuedDraft.contains("Z"))
    }

    func testCalendarOpensHistoricalJournalAndOnlyThatDaysChanges() {
        let app = launch()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let yesterday = formatter.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        XCTAssertFalse(app.buttons["journal-view-changes"].exists, "Unanalyzed writing must not offer a new result")
        app.tabBars.buttons["Ajanda"].tap()
        let day = app.buttons["calendar-day-" + yesterday]
        if !day.exists { app.buttons["Önceki ay"].tap() }
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        day.tap()
        XCTAssertTrue(app.scrollViews["agenda-day-detail"].waitForExistence(timeout: 5))
        let openJournal = app.buttons["agenda-day-open-journal"]
        XCTAssertTrue(openJournal.waitForExistence(timeout: 5))
        openJournal.tap()
        XCTAssertTrue(app.tabBars.buttons["Bugün"].isSelected)
        XCTAssertEqual(app.staticTexts["journal-date"].value as? String, yesterday)
        let changes = app.buttons["journal-view-changes"]
        // A NavigationLink can be exposed as a button or a link by SwiftUI.
        let result = changes.exists ? changes : app.descendants(matching: .any).matching(identifier: "journal-view-changes").firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let summaryDay = app.staticTexts["daily-summary-date"]
        XCTAssertTrue(summaryDay.waitForExistence(timeout: 5))
        XCTAssertEqual(summaryDay.value as? String, yesterday)
        XCTAssertEqual(app.staticTexts.matching(identifier: "daily-summary-date").count, 1)
    }

    func testCommittedMapTourAppearsWhileNextAnalysisStageIsStillRunning() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-maptour-busy-preview"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["analysis-map-tour-instruction"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Harita gezisini kapat"].isHittable)
        XCTAssertFalse(app.buttons["Duraklat"].exists)
        XCTAssertFalse(app.buttons["Oynat"].exists)
    }

    func testCommittedMapTourShowsOneMapWithoutPagingBetweenLinks() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-maptour-preview"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["analysis-map-tour-instruction"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["atlas-node-n0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["atlas-node-n5"].exists)
        XCTAssertFalse(app.buttons["Sonraki değişiklik"].exists)
        XCTAssertFalse(app.buttons["Önceki değişiklik"].exists)
        XCTAssertEqual(app.staticTexts["analysis-map-tour-position"].label, "Harita 1 / 1")
        app.buttons["Harita gezisini kapat"].tap()
        XCTAssertTrue(app.staticTexts["Zihin atlasın"].waitForExistence(timeout: 5))
    }

    func testLastChangedMapOpensTheAnalysisDaysQuestions() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-maptour-questions-preview"]
        app.launch()

        let position = app.staticTexts["analysis-map-tour-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        XCTAssertEqual(position.label, "Harita 1 / 2")
        XCTAssertFalse(app.buttons["analysis-map-tour-questions"].exists)
        app.buttons["Sonraki değişiklik"].tap()
        XCTAssertEqual(position.label, "Harita 2 / 2")

        let questions = app.buttons["analysis-map-tour-questions"]
        XCTAssertTrue(questions.waitForExistence(timeout: 5))
        questions.tap()
        XCTAssertTrue(app.staticTexts["Sunum öncesi sana ne iyi geldi?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Sorular"].isSelected)
        XCTAssertFalse(position.exists)
    }

    func testMindmapSharingIsVisibleFirstInSettings() {
        let app = launch()
        app.tabBars.buttons["Ayarlar"].tap()
        let share = app.descendants(matching: .any).matching(identifier: "settings-share-mindmaps").firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(share.isHittable)
        XCTAssertFalse(app.buttons["İşlerin"].exists)
        share.tap()
        let purpose = app.descendants(matching: .any).matching(identifier: "context-export-purpose").firstMatch
        XCTAssertTrue(purpose.waitForExistence(timeout: 5))
        XCTAssertTrue(purpose.isHittable)
        purpose.tap()
        purpose.typeText("Konuşma tarzımla bir yazı hazırlamak.")
        XCTAssertTrue((purpose.value as? String ?? "").contains("Konuşma tarzımla"))
    }

    func testCalendarReopensPreviousDaysDeviceOnlyDraftWithoutInventingAnAnalysis() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-flow-preview", "-daily-draft-history-preview"]
        app.launch()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let yesterday = formatter.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        app.tabBars.buttons["Ajanda"].tap()
        let day = app.buttons["calendar-day-" + yesterday]
        if !day.exists { app.buttons["Önceki ay"].tap() }
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        XCTAssertTrue(day.label.contains("cihazdaki taslak"))
        day.tap()
        XCTAssertTrue(app.staticTexts["Cihazdaki taslak"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["agenda-day-journal"].label, "Dün yazdığım günlük cihazda taslak olarak korunuyor.")
        app.buttons["agenda-day-open-journal"].tap()
        XCTAssertEqual(app.staticTexts["journal-date"].value as? String, yesterday)
        XCTAssertTrue((app.textViews["journal-editor"].value as? String ?? "").contains("Dün yazdığım günlük"))
        XCTAssertFalse(app.buttons["journal-read-reply"].exists)
        XCTAssertFalse(app.buttons["journal-view-changes"].exists)
    }

    func testWrittenAnswersUseOneDailyLogoAndRemainDraftsWhenLeaving() {
        let app = XCUIApplication()
        app.launchArguments = ["-daily-flow-preview", "-daily-answers-preview"]
        app.launch()
        app.tabBars.buttons["Sorular"].tap()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = app.buttons["questions-day-" + formatter.string(from: Date())]
        XCTAssertTrue(day.waitForExistence(timeout: 10)); day.tap()
        let logo = app.buttons["daily-analysis-play"]
        XCTAssertTrue(logo.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Yanıtla"].exists)
        let editor = app.textViews["question-answer-preview-open"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); app.typeText("Yürüyüş iyi geldi.")
        XCTAssertTrue(logo.isEnabled)
        app.navigationBars.buttons["Sorular"].tap()
        XCTAssertFalse(app.staticTexts["Analiz sürüyor…"].exists)
        day.tap()
        XCTAssertTrue((editor.value as? String ?? "").contains("Yürüyüş iyi geldi."))
        logo.tap()
        XCTAssertTrue(app.staticTexts["Analizin"].waitForExistence(timeout: 5))
        let read = app.buttons["analysis-read-reply"]
        XCTAssertTrue(read.isEnabled); read.tap()
        XCTAssertTrue(app.staticTexts["Örnek günün kaydedilmiş yansıması."].waitForExistence(timeout: 5))
    }
}
