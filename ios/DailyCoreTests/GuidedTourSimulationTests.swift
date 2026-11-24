import XCTest
@testable import DailyCore

final class GuidedTourSimulationTests: XCTestCase {
    func testIntroductionReturnsToSavedDayBeforeAccount() {
        var flow = GuidedTourSimulation(isIntroduction: true)
        XCTAssertEqual(flow.totalSteps, 5)
        flow.advance()
        flow.startAnalysis()
        flow.analysisFinished()
        flow.openNote(GuidedTourExample.focusNodeID)
        flow.advance()
        XCTAssertEqual(flow.stage, .savedDay)
        XCTAssertEqual(flow.stage.tab, .today)
        XCTAssertEqual(flow.progress, 4)
        flow.advance()
        XCTAssertEqual(flow.stage, .account)
        XCTAssertEqual(flow.progress, flow.totalSteps)
        flow.back()
        XCTAssertEqual(flow.stage, .savedDay)
    }

    func testSkippingIntroductionExampleStillOpensRequiredAccountStep() {
        var flow = GuidedTourSimulation(isIntroduction: true)
        flow.skipExample()
        XCTAssertEqual(flow.stage, .account)
        flow.advance()
        XCTAssertEqual(flow.stage, .account)
        flow.back()
        XCTAssertEqual(flow.stage, .writing)
    }

    func testAnalysisAndExportRequireTheirOwnActions() {
        var flow = GuidedTourSimulation()
        flow.analysisFinished()
        XCTAssertEqual(flow.stage, .writing)
        flow.advance()
        XCTAssertEqual(flow.stage, .daily)
        flow.advance()
        XCTAssertEqual(flow.stage, .daily)
        flow.startAnalysis()
        XCTAssertEqual(flow.stage, .analysing)
        flow.advance(); flow.back(); flow.startAnalysis()
        XCTAssertEqual(flow.stage, .analysing)
        flow.analysisFinished()
        XCTAssertEqual(flow.stage, .map)
        XCTAssertEqual(flow.stage.tab, .maps)
        flow.analysisFinished()
        XCTAssertEqual(flow.stage, .map)
        flow.openNote("not-in-example")
        XCTAssertEqual(flow.stage, .map)
        flow.openNote(GuidedTourExample.focusNodeID)
        XCTAssertEqual(flow.stage, .note)
        flow.advance()
        XCTAssertEqual(flow.stage, .questions)
        flow.advance()
        XCTAssertEqual(flow.stage, .questions)
        flow.answer(false); flow.advance()
        XCTAssertEqual(flow.stage, .agenda)
        flow.advance()
        XCTAssertEqual(flow.stage, .emotionDay)
        XCTAssertEqual(flow.stage.tab, .agenda)
        flow.advance()
        XCTAssertEqual(flow.stage, .emotionFlow)
        XCTAssertEqual(flow.stage.tab, .agenda)
        flow.back()
        XCTAssertEqual(flow.stage, .emotionDay)
        flow.advance(); flow.advance()
        XCTAssertEqual(flow.stage, .savedDay)
        flow.back()
        XCTAssertEqual(flow.stage, .emotionFlow)
        flow.advance(); flow.advance()
        XCTAssertEqual(flow.stage, .export)
        flow.openExport()
        XCTAssertEqual(flow.stage, .exportPreview)
        flow.advance()
        XCTAssertEqual(flow.stage, .firebase)
        XCTAssertEqual(flow.stage.progress, 10)
        flow.advance()
        XCTAssertEqual(flow.stage, .firebase)
        flow.advance(firebaseConnected: true)
        XCTAssertEqual(flow.stage, .account)
        XCTAssertEqual(flow.stage.progress, 11)
        flow.back()
        XCTAssertEqual(flow.stage, .firebase)
        flow.back()
        XCTAssertEqual(flow.stage, .exportPreview)
    }

    func testOptionalFirebaseStepCanContinueLocallyWithoutPretendingToConnect() {
        var flow = GuidedTourSimulation()
        flow.advance(); flow.startAnalysis(); flow.analysisFinished()
        flow.openNote(GuidedTourExample.focusNodeID); flow.advance(); flow.answer(false); flow.advance()
        flow.advance(); flow.advance(); flow.advance(); flow.advance(); flow.openExport(); flow.advance()
        XCTAssertEqual(flow.stage, .firebase)
        flow.advance(firebaseConnected: false, continueLocally: true)
        XCTAssertEqual(flow.stage, .account)
    }

    func testAnswerSurvivesGoingBackButNewTourResetsIt() {
        var flow = GuidedTourSimulation()
        flow.advance(); flow.startAnalysis(); flow.analysisFinished()
        flow.openNote(GuidedTourExample.focusNodeID); flow.advance(); flow.answer(false); flow.advance()
        flow.back()
        XCTAssertEqual(flow.stage, .questions)
        XCTAssertEqual(flow.reminder, false)
        flow.answer(true); flow.advance()
        XCTAssertEqual(flow.reminder, true)
        flow = GuidedTourSimulation()
        XCTAssertNil(flow.reminder)
        XCTAssertEqual(flow.stage, .writing)
    }

    func testExampleGraphCanBeOpenedWithoutWorkspaceRecords() throws {
        let graph = GuidedTourExample.graph
        XCTAssertEqual(graph.nodes.count, 4)
        XCTAssertEqual(graph.edges.count, 3)
        let ids = Set(graph.nodes.map(\.id))
        XCTAssertTrue(graph.edges.allSatisfy { ids.contains($0.source) && ids.contains($0.target) })
        XCTAssertEqual(graph.focused(on: GuidedTourExample.focusNodeID).nodes.count, 3)
        let data = try JSONEncoder().encode(graph)
        XCTAssertEqual(try JSONDecoder().decode(MobileAtlas.Graph.self, from: data), graph)
    }

    func testEmotionDemoHasOrderedObservationsAndReadOnlySourceDates() {
        let tr = GuidedTourExample.emotionDay(date: "2026-11-07", previousDate: "2026-10-31", language: "tr")
        let en = GuidedTourExample.emotionDay(date: "2026-11-07", previousDate: "2026-10-31", language: "en")
        XCTAssertEqual(tr.keys, ["tension", "relief", "fatigue"])
        XCTAssertEqual(tr.observations.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(tr.sequenceSignature, "tension|relief|fatigue")
        XCTAssertEqual(tr.connections.first?.date, "2026-10-31")
        XCTAssertFalse(tr.userSelected)
        XCTAssertEqual(tr.keys, en.keys)
        XCTAssertEqual(tr.observations.map(\.id), en.observations.map(\.id))
        XCTAssertTrue(en.reflection.contains("swimming"))
        XCTAssertTrue(tr.observations.allSatisfy { !$0.quote.isEmpty })
        // Demo actions must retain the real renderer's event/quote identity in both languages.
        let trEvents = EmotionPatterns.episodes(for: tr), enEvents = EmotionPatterns.episodes(for: en)
        XCTAssertEqual(trEvents.count, 3)
        XCTAssertEqual(trEvents.map(\.id), enEvents.map(\.id))
        XCTAssertEqual(trEvents.map(\.title), ["İş yükü", "Yüzme sonrası", "Akşam"])
        XCTAssertEqual(trEvents.first?.observations.first?.quote, "Bugün işte gerildim")
        XCTAssertEqual(enEvents.first?.observations.first?.quote, "I felt tense at work today")
    }

    func testEnglishExamplePreservesNoteIDsAndConnections() {
        let original = GuidedTourExample.graph
        let english = GuidedTourExample.graph(language: "en")
        XCTAssertEqual(original.nodes.map(\.id), english.nodes.map(\.id))
        XCTAssertEqual(original.edges.map(\.id), english.edges.map(\.id))
        XCTAssertEqual(english.nodes.first { $0.id == GuidedTourExample.focusNodeID }?.label, "Swimming")
        XCTAssertEqual(GuidedTourExample.graph(language: "tr"), original)
    }
}
