import Foundation
import XCTest
@testable import DailyCore

final class ResponseUsageTests: XCTestCase {
    func testRealUsageAndSubsetCounts() throws {
        let usage=try XCTUnwrap(ResponseUsage(json:JSONValue.parse(#"{"input_tokens":100,"output_tokens":40,"total_tokens":140,"input_tokens_details":{"cached_tokens":60},"output_tokens_details":{"reasoning_tokens":20}}"#)))
        XCTAssertEqual(usage.totalTokens,140)
        XCTAssertEqual(usage.cachedTokens,60)
        XCTAssertEqual(usage.reasoningTokens,20)
        XCTAssertNil(ResponseUsage(json:nil))
        XCTAssertNil(ResponseUsage(json:try JSONValue.parse(#"{"input_tokens":-1,"output_tokens":1.5}"#)))
    }
    func testTerminalUsageIsRetainedEvenForAnIncompleteResponse() throws {
        var stream=ResponsesStream()
        let event=#"data: {"type":"response.incomplete","response":{"usage":{"input_tokens":50,"output_tokens":10,"total_tokens":60},"incomplete_details":{"reason":"max_output_tokens"}}}"#+"\n\n"
        XCTAssertThrowsError(try stream.append(Data(event.utf8)))
        XCTAssertEqual(stream.usage?.totalTokens,60)
    }
    func testCompletedUsageDoesNotRequireDoneAndIsNotCountedFromDeltas() throws {
        var body=ResponsesBody(status:200,contentType:"text/event-stream")
        let event=#"data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":50,"output_tokens":10,"total_tokens":60},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}}"#+"\n\n"
        for byte in Data(event.utf8) { try body.append(byte) }
        XCTAssertEqual(try body.finish(),"OK")
        XCTAssertEqual(body.usage?.totalTokens,60)
    }
    func testLedgerScopesAndUpsertsAttemptsWithoutLosingReportedTokens() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let ledger=AIUsageLedger(root:root),usage=ResponseUsage(json:try JSONValue.parse(#"{"input_tokens":5,"output_tokens":3,"total_tokens":8}"#))
        let first=AIUsageEntry(id:"one",date:Date(),stage:"journal",model:"fixture",succeeded:true,duration:1,requestBytes:300,usage:usage)
        try await ledger.record(first,scope:"project/account-a")
        try await ledger.record(AIUsageEntry(id:"one",date:first.date,stage:"journal",model:"fixture",succeeded:false,duration:2,requestBytes:300,usage:nil),scope:"project/account-a")
        let rows=try await ledger.entries(scope:"project/account-a"),other=try await ledger.entries(scope:"project/account-b")
        XCTAssertEqual(rows.count,1);XCTAssertEqual(rows.first?.usage?.totalTokens,8)
        XCTAssertEqual(rows.first?.succeeded,false);XCTAssertTrue(other.isEmpty)
    }
}
