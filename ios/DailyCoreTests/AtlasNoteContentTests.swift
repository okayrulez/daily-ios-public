import XCTest
@testable import DailyCore

final class AtlasNoteContentTests: XCTestCase {
    private func note(_ json: String) throws -> MobileAtlas.Note {
        try JSONDecoder().decode(MobileAtlas.Note.self, from: Data(json.utf8))
    }
    private func node() throws -> MobileAtlas.Node {
        try JSONDecoder().decode(MobileAtlas.Node.self, from: Data(#"{"id":"n","label":"Not","status":"observation","summary":"Kısa önizleme","updatedAt":"2026-11-17","topicPath":[]}"#.utf8))
    }
    func testShowsOneCompleteCurrentNoteWithoutDuplicatingDatedEvidence() throws {
        let notes = try [note(#"{"nodeId":"n","kind":"description","date":"","text":"Güncel uzun not","contentID":"current","part":0}"#),
            note(#"{"nodeId":"n","kind":"description","date":"","text":" devamı","contentID":"current","part":1}"#),
            note(#"{"nodeId":"n","kind":"observation","date":"2026-11-17","text":"Güncel uzun not devamı","quote":"ham günlük"}"#)]
        XCTAssertEqual(AtlasNoteContent.text(for: try node(), notes: notes), "Güncel uzun not devamı")
    }
    func testContextUsesKnownJournalQuotesAndDatesWithoutAttributingUnknownSourcesToUser() throws {
        let notes = try [
            note(#"{"nodeId":"n","kind":"inference","date":"2026-11-10","text":"Çıkarım","quote":"Söyledim","sourceTitle":"Günlük","sourceKind":"journal"}"#),
            note(#"{"nodeId":"n","kind":"observation","date":"2026-11-11","text":"Yorum","quote":"Yazı","sourceTitle":"Araştırma","sourceKind":"research"}"#),
            note(#"{"nodeId":"n","kind":"correction","date":"2026-11-13T11:22:00Z","text":"Düzeltmem"}"#)]
        let context = AtlasNoteContent.context(for: try node(), notes: notes)
        XCTAssertEqual(context.kind, "correction")
        XCTAssertEqual(context.dates, ["2026-11-10", "2026-11-11", "2026-11-13", "2026-11-17"])
        XCTAssertEqual(context.journalQuote, "Söyledim")
        XCTAssertEqual(context.quoteDate, "2026-11-10")
        XCTAssertEqual(context.sourceTitle, "Araştırma")
        let legacy = try note(#"{"nodeId":"n","kind":"observation","date":"","text":"Not","quote":"Kaynağı belirtilmemiş"}"#)
        XCTAssertNil(AtlasNoteContent.context(for: try node(), notes: [legacy]).journalQuote)
    }

    func testLatestCorrectionWinsButOtherNodesAndOldObservationsDoNotLeakIn() throws {
        let notes = try [note(#"{"nodeId":"n","kind":"description","date":"","text":"Eski içerik"}"#),
            note(#"{"nodeId":"n","kind":"correction","date":"2026-11-16","text":"Önceki düzeltme"}"#),
            note(#"{"nodeId":"n","kind":"correction","date":"2026-11-17","text":"Kendi düzeltmem"}"#),
            note(#"{"nodeId":"other","kind":"correction","date":"2026-11-18","text":"Başkasının notu"}"#)]
        XCTAssertEqual(AtlasNoteContent.text(for: try node(), notes: notes), "Kendi düzeltmem")
        XCTAssertEqual(AtlasNoteContent.text(for: try node(), notes: []), "Kısa önizleme")
    }
}
