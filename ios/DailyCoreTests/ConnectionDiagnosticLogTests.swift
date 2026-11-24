import Foundation
import XCTest
@testable import DailyCore

final class ConnectionDiagnosticLogTests: XCTestCase {
    func testStreamOutputCountersPersistWithoutOutputContents() {
        let progress = "bytes=6508 · events=10 · last=response.completed · done=false · item_done=1 · text_delta=2 · text_done=1 · terminal_items=0"
        let failure = ChatGPTServiceFailure(stage:"RESPONSES_STREAM",fallbackCode:"completed_without_text",streamDiagnostic:progress)
        let entry = ConnectionDiagnosticEntry(stage:"CONNECTION_PROBE",outcome:"failed",error:failure)
        XCTAssertEqual(entry.fields["stream"],progress)
        let unsafe = ChatGPTServiceFailure(stage:"RESPONSES_STREAM",streamDiagnostic:progress + " private diary")
        XCTAssertNil(ConnectionDiagnosticEntry(stage:"CONNECTION_PROBE",outcome:"failed",error:unsafe).fields["stream"])
    }
    func testServiceFailureRetainsActualCodeAndRequestButNoPrivateBody() {
        let body = Data(#"{"error":{"code":"insufficient_quota","type":"billing_error","param":"model","message":"private diary sk-secret"},"access_token":"secret_token"}"#.utf8)
        let error = ChatGPTServiceFailure(stage:"RESPONSES",status:429,body:body,requestID:"req_123",
            retryAfter:"120",contentType:"application/json",now:Date(timeIntervalSince1970:1000))
        let entry = ConnectionDiagnosticEntry(stage:"CONNECTION_PROBE",outcome:"failed",model:"test-model",build:"1.0.42",error:error)
        XCTAssertEqual(entry.fields["code"],"insufficient_quota")
        XCTAssertEqual(entry.fields["http_status"],"429")
        XCTAssertEqual(entry.fields["request_id"],"req_123")
        XCTAssertEqual(entry.fields["error_type"],"billing_error")
        XCTAssertEqual(entry.fields["parameter"],"model")
        XCTAssertNotNil(entry.fields["retry_at"])
        for secret in ["private diary","sk-secret","secret_token","access_token"] {
            XCTAssertFalse(entry.report.contains(secret))
        }
    }

    func testOAuthStringErrorAndNativeNetworkErrorDoNotLoseActualCodes() {
        let oauth = ChatGPTServiceFailure(stage:"TOKEN_REFRESH",status:400,
            body:Data(#"{"error":"invalid_grant","error_description":"secret_token"}"#.utf8))
        let tokenEntry = ConnectionDiagnosticEntry(stage:"MODEL_LIST",outcome:"failed",error:oauth)
        XCTAssertEqual(tokenEntry.fields["code"],"invalid_grant")
        XCTAssertEqual(tokenEntry.fields["provider_stage"],"TOKEN_REFRESH")
        XCTAssertFalse(tokenEntry.report.contains("secret_token"))
        let network = NSError(domain:NSURLErrorDomain,code:-1009,userInfo:[
            NSLocalizedDescriptionKey:"private diary",
            NSURLErrorFailingURLStringErrorKey:"https://example.com/?code=secret"])
        let entry = ConnectionDiagnosticEntry(stage:"CONNECTION_PROBE",outcome:"failed",error:network)
        XCTAssertEqual(entry.fields["native_code"],"-1009")
        XCTAssertEqual(entry.fields["error_domain"],NSURLErrorDomain)
        XCTAssertFalse(entry.report.contains("private"))
        XCTAssertFalse(entry.report.contains("secret"))
    }

    func testStreamErrorMetadataSurvivesWithoutServerMessage() throws {
        var body = ResponsesBody(status:200,contentType:"text/event-stream")
        let event = #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","type":"usage_limit","param":"model","message":"secret diary"}}}"# + "\n\n"
        XCTAssertThrowsError(try { for byte in event.utf8 { try body.append(byte) } }())
        XCTAssertEqual(body.errorType,"usage_limit")
        XCTAssertEqual(body.errorParameter,"model")
        let error = ChatGPTServiceFailure(stage:"RESPONSES_STREAM",status:200,
            fallbackCode:"subscription_sharing_usage_limit_exceeded",streamDiagnostic:body.streamDiagnostic,
            fallbackErrorType:body.errorType,fallbackParameter:body.errorParameter)
        let entry = ConnectionDiagnosticEntry(stage:"ANALYSIS_INFERENCE",outcome:"failed",error:error)
        XCTAssertEqual(entry.fields["error_type"],"usage_limit")
        XCTAssertTrue(entry.fields["stream"]?.contains("last=response.failed") ?? false)
        XCTAssertFalse(entry.report.contains("secret diary"))
    }

    func testBoundedHistorySurvivesRelaunchAndIsScopedAndClearable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var log = try ConnectionDiagnosticLog(directory:root,scope:"account-a")
        for index in 0..<55 {
            try log.append(ConnectionDiagnosticEntry(stage:"MODEL_LIST",outcome:"started",now:Date(timeIntervalSince1970:Double(index))))
        }
        XCTAssertEqual(log.entries.count,50)
        var restored = try ConnectionDiagnosticLog(directory:root,scope:"account-a")
        XCTAssertEqual(restored.report,log.report)
        XCTAssertEqual(restored.entries.first?.timestamp,Date(timeIntervalSince1970:5))
        XCTAssertTrue(try ConnectionDiagnosticLog(directory:root,scope:"account-b").entries.isEmpty)
        try restored.clear()
        XCTAssertTrue(try ConnectionDiagnosticLog(directory:root,scope:"account-a").entries.isEmpty)
    }

    func testCorruptLogIsReportedInsteadOfSilentlyErased() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        _ = try ConnectionDiagnosticLog(directory:root,scope:"account-a")
        let file = root.appendingPathComponent(WorkspaceHash.sha256("account-a") + ".json")
        try Data("invalid".utf8).write(to:file)
        XCTAssertThrowsError(try ConnectionDiagnosticLog(directory:root,scope:"account-a"))
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"invalid")
    }
}
