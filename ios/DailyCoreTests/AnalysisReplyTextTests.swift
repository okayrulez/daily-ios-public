import XCTest
@testable import DailyCore

final class AnalysisReplyTextTests: XCTestCase {
    func testTaskReplyHasReadableReportAndSafeProviderLinks() {
        let value = AnalysisReplyText(raw: #"{"kind":"daily_task","reply":"Araştırma raporu","sources":[{"url":"https://example.com/post","title":"Gönderi"},{"url":"javascript:alert(1)","title":"Unsafe"}]}"#)
        XCTAssertEqual(value.text, "Araştırma raporu")
        XCTAssertEqual(value.sources.count, 1)
        XCTAssertEqual(value.sources.first?.url, "https://example.com/post")
    }
    func testShowsReflectionAndAdditionalAnswerSections() {
        let reply = AnalysisReplyText(raw: #"{"reflection":"Ana yanıt","living_memory":{"summary":"Özet metni","next_step":"Bir adım"}}"#)
        XCTAssertTrue(reply.text.contains("Ana yanıt"))
        XCTAssertTrue(reply.text.contains("Özet metni"))
        XCTAssertTrue(reply.text.contains("Bir adım"))
        XCTAssertNotNil(reply.fullText)
    }
    func testEmptyReflectionDoesNotHideSummary() {
        let reply = AnalysisReplyText(raw: #"{"reflection":"  ","living_memory":{"summary":"Okunabilir yanıt"}}"#)
        XCTAssertTrue(reply.text.contains("Okunabilir yanıt"))
    }
    func testUnknownJSONAndPlainTextRemainReadable() {
        XCTAssertTrue(AnalysisReplyText(raw: #"{"result":"Yanıt"}"#).text.contains("Yanıt"))
        XCTAssertEqual(AnalysisReplyText(raw: "  Düz yanıt  ").text, "Düz yanıt")
        XCTAssertFalse(AnalysisReplyText(raw: "").text.isEmpty)
    }
    func testDuplicateSummaryIsShownOnce() {
        let reply = AnalysisReplyText(raw: #"{"reflection":"Aynı yanıt","living_memory":{"summary":"Aynı yanıt"}}"#)
        XCTAssertEqual(reply.text, "Aynı yanıt")
    }
}
