import Foundation
import XCTest
@testable import DailyCore

final class ChatGPTServiceFailureTests: XCTestCase {
    func testPlanLimitAndUnspecifiedQuotaHaveDifferentExplanations() {
        let plan = ChatGPTServiceFailure(stage: "RESPONSES", status: 429,
            fallbackCode: "subscription_sharing_usage_limit_exceeded")
        let unspecified = ChatGPTServiceFailure(stage: "RESPONSES", status: 429,
            fallbackCode: "insufficient_quota")
        XCTAssertTrue(plan.isUsageLimit)
        XCTAssertTrue(unspecified.isUsageLimit)
        XCTAssertNotEqual(plan.summary, unspecified.summary)
        XCTAssertTrue(plan.summary.contains("uygulamalarda kullanım"))
        XCTAssertTrue(plan.summary.contains("Ayarlar → Kullanım"))
        XCTAssertTrue(plan.summary.contains("Metin istekleri de"))
        XCTAssertTrue(unspecified.summary.contains("insufficient_quota"))
        for failure in [plan, unspecified] {
            XCTAssertNil(failure.retryAt)
            XCTAssertFalse(failure.summary.contains("hakkın doldu"))
        }
    }
    func testPreservesProtocolCodeButNotPrivateErrorText() {
        let data = Data(#"{"error":{"code":"subscription_sharing_unsupported_capability","param":"model","message":"private diary and token"}}"#.utf8)
        let error = ChatGPTServiceFailure(stage: "RESPONSES", status: 400, body: data, requestID: "req_123")
        XCTAssertTrue(error.userMessage.contains("HTTP 400"))
        XCTAssertTrue(error.userMessage.contains("subscription_sharing_unsupported_capability"))
        XCTAssertTrue(error.userMessage.contains("req_123"))
        XCTAssertFalse(error.userMessage.contains("private diary"))
    }
    func testAdmissionDetailAndInvalidMetadataStayPrivate() {
        let data = Data(#"{"detail":"private account description"}"#.utf8)
        let error = ChatGPTServiceFailure(stage: "MODEL_LIST", status: 403, body: data, requestID: "Bearer secret token")
        XCTAssertEqual(error.shape, "detail")
        XCTAssertNil(error.requestID)
        XCTAssertFalse(error.userMessage.contains("private account"))
        XCTAssertTrue(error.userMessage.contains("HTTP 403"))
    }
    func testStreamingErrorRetainsCodeAndNeverCommitsDraft() throws {
        var stream = ResponsesStream()
        let event = #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"private"}}}"# + "\n\n"
        XCTAssertThrowsError(try stream.append(Data(event.utf8))) {
            XCTAssertEqual($0 as? ResponsesStreamError, .providerCode("subscription_sharing_usage_limit_exceeded"))
        }
        XCTAssertThrowsError(try stream.finish())
    }
    func testIncompleteFailuresAreActionableAndDoNotInventQuotaOrResetTime() {
        let codes = ["stream_ended_before_completion", "completed_without_text",
            "response_incomplete_max_output_tokens", "response_incomplete_content_filter",
            "response_incomplete_unknown", "stream_timeout", "stream_connection_lost"]
        for code in codes {
            let error = ChatGPTServiceFailure(stage: "RESPONSES_STREAM", status: 200,
                requestID: "req_123", fallbackCode: code, contentType: "text/event-stream",
                streamDiagnostic: "events=1 · last=response.in_progress")
            XCTAssertFalse(error.isUsageLimit)
            XCTAssertFalse(error.isRateLimited)
            XCTAssertNil(error.retryAt)
            XCTAssertNotEqual(error.summary, "ChatGPT bağlantısının bu adımı tamamlanamadı.")
            XCTAssertTrue(error.diagnostic.contains("req_123"))
            XCTAssertTrue(error.diagnostic.contains("last=response.in_progress"))
        }
    }
}
