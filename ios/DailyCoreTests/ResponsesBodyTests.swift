import Foundation
import XCTest
@testable import DailyCore

final class ResponsesBodyTests: XCTestCase {
    func testFinishedStreamItemCanSupplyTextWhenTerminalOutputIsEmpty() throws {
        var body = ResponsesBody(status: 200, contentType: nil)
        let wire = #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"OK"}]}}"# + "\n\n" +
            #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"# + "\n\n"
        for byte in wire.utf8 { try body.append(byte) }
        XCTAssertEqual(try body.finish(),"OK")
    }
    let completed = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"OK\"}]}]}}\n\n"
    func testValidCompletedStreamWithMissingMIMEIsAccepted() throws {
        var body = ResponsesBody(status: 200, contentType: nil)
        for byte in completed.utf8 { try body.append(byte) }
        XCTAssertEqual(try body.finish(), "OK")
    }
    func testBOMAndCRBodyIsRecognizedAndDecoded() throws {
        var body = ResponsesBody(status: 200, contentType: "text/event-stream")
        let wire = "\u{feff}event: response.completed\r" + completed.replacingOccurrences(of: "\n", with: "\r")
        for byte in wire.utf8 { try body.append(byte) }
        XCTAssertEqual(try body.finish(), "OK")
    }
    func testTruncatedBodyPreservesSafeStreamProgress() throws {
        var body = ResponsesBody(status: 200, contentType: "text/event-stream")
        for byte in "data: {\"type\":\"response.in_progress\"}\n\n".utf8 { try body.append(byte) }
        XCTAssertThrowsError(try body.finish())
        XCTAssertTrue(body.streamDiagnostic?.contains("last=response.in_progress") ?? false)
    }
    func testHTML200IsNotAnAnalysisOrAQuotaError() throws {
        var body = ResponsesBody(status: 200, contentType: "text/html")
        for byte in "<html>private gateway page</html>".utf8 { try body.append(byte) }
        XCTAssertThrowsError(try body.finish()) {
            let failure = $0 as? ChatGPTServiceFailure
            XCTAssertEqual(failure?.code, "expected_event_stream")
            XCTAssertEqual(failure?.isUsageLimit, false)
            XCTAssertFalse(failure?.userMessage.contains("private gateway") ?? true)
        }
    }
    func testJSONQuotaOn200RemainsQuotaWithServerRetryTime() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var body = ResponsesBody(status: 200, contentType: "application/json", retryAfter: "120", now: now)
        for byte in #"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#.utf8 { try body.append(byte) }
        XCTAssertThrowsError(try body.finish()) {
            let failure = $0 as? ChatGPTServiceFailure
            XCTAssertEqual(failure?.isUsageLimit, true)
            XCTAssertEqual(failure?.retryAt, Date(timeIntervalSince1970: 1120))
        }
    }
    func testTruncatedStreamNeverProducesAnAnalysis() throws {
        var body = ResponsesBody(status: 200, contentType: "text/plain")
        for byte in "data: {\"type\":\"response.output_text.delta\",\"delta\":\"draft\"}\n\n".utf8 { try body.append(byte) }
        XCTAssertThrowsError(try body.finish())
    }
    func testLargeValidFirstEventDoesNotHitDiagnosticBodyLimit() throws {
        let output=String(repeating:"a",count:9000)
        var body=ResponsesBody(status:200,contentType:nil)
        for byte in completed.replacingOccurrences(of:"OK",with:output).utf8 { try body.append(byte) }
        XCTAssertEqual(try body.finish(),output)
    }
    func testJSONCompletedObjectCannotBypassTerminalEventRequirement() throws {
        var body=ResponsesBody(status:200,contentType:"application/json")
        for byte in #"{"status":"completed","output_text":"unverified"}"#.utf8 { try body.append(byte) }
        XCTAssertThrowsError(try body.finish())
    }
    func testQuotaCodeAloneDoesNotInventResetTime() {
        let failure = ChatGPTServiceFailure(stage: "RESPONSES_STREAM", fallbackCode: "subscription_sharing_usage_limit_exceeded")
        XCTAssertTrue(failure.isUsageLimit)
        XCTAssertNil(failure.retryAt)
    }
    func testRateLimitAndServiceOverloadAreNotPlanQuota() {
        XCTAssertFalse(ChatGPTServiceFailure(stage: "RESPONSES", status: 429).isUsageLimit)
        XCTAssertFalse(ChatGPTServiceFailure(stage: "RESPONSES", status: 503, fallbackCode: "subscription_sharing_usage_unavailable").isUsageLimit)
    }
    func testRetryAfterHTTPDateAndInvalidValues() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ChatGPTServiceFailure(stage: "RESPONSES", retryAfter: "Thu, 01 Jan 1970 00:02:00 GMT", now: now).retryAt, Date(timeIntervalSince1970: 120))
        for value in ["-3", "NaN", "Infinity", "unknown"] {
            XCTAssertNil(ChatGPTServiceFailure(stage: "RESPONSES", retryAfter: value, now: now).retryAt)
        }
    }
}
