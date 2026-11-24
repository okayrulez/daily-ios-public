import XCTest
@testable import DailyCore

final class ResearchStreamTests: XCTestCase {
    private let message = #"{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"A report","annotations":[{"type":"url_citation","url":"https://example.com/post","title":"Post","start_index":0,"end_index":8}]}]}"#
    private let search = #"{"id":"ws_1","type":"web_search_call","status":"completed","action":{"type":"search"}}"#
    private func terminal(_ items: String) -> Data {
        Data(("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[" + items + "]}}\n\n").utf8)
    }
    func testResearchPreservesProviderCitationsAndCompletedSearches() throws {
        var stream = ResponsesStream(allowWebSearch: true)
        try stream.append(terminal(search + "," + message))
        XCTAssertEqual(try stream.finish(), "A report")
        XCTAssertEqual(stream.webSearchCalls, 1)
        XCTAssertEqual(stream.citations.first?.url, "https://example.com/post")
    }
    func testOrdinaryInferenceStillRejectsTools() {
        var stream = ResponsesStream()
        XCTAssertThrowsError(try stream.append(terminal(search + "," + message)))
    }
    func testInterruptedStreamCannotPublishResearchEvidence() throws {
        var stream = ResponsesStream(allowWebSearch: true)
        try stream.append(Data(("data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":" + search + "}\n\n").utf8))
        XCTAssertThrowsError(try stream.finish())
        XCTAssertEqual(stream.webSearchCalls, 0)
        XCTAssertTrue(stream.citations.isEmpty)
    }
    func testDoneItemsArePreservedWhenTerminalOutputIsEmpty() throws {
        var stream = ResponsesStream(allowWebSearch: true)
        for (i,item) in [search,message].enumerated() {
            try stream.append(Data(("data: {\"type\":\"response.output_item.done\",\"output_index\":\(i),\"item\":" + item + "}\n\n").utf8))
        }
        try stream.append(terminal(""))
        XCTAssertEqual(try stream.finish(), "A report")
        XCTAssertEqual(stream.webSearchCalls, 1)
        XCTAssertEqual(stream.citations.count, 1)
    }
}
