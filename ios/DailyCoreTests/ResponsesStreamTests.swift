import Foundation
import XCTest
@testable import DailyCore

final class ResponsesStreamTests: XCTestCase {
    private let emptyCompleted = #"data: {"type":"response.completed","response":{"status":"completed","error":null,"output":[]}}"# + "\n\n"
    private func doneMessage(_ text: String = "OK", index: Int = 0) -> String {
        // Synthetic protocol fixture; this is not a captured user response.
        "data: {\"type\":\"response.output_item.done\",\"output_index\":\(index),\"item\":{\"id\":\"msg_\(index)\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"\(text)\"}]}}\n\n"
    }
    private let complete = #"data: {"type":"response.completed","response":{"status":"completed","error":null,"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"İyi 🌿"}]}]}}"# + "\r\n\r\n"

    func testArbitraryUTF8ChunkBoundariesAndCRLF() throws {
        var stream = ResponsesStream()
        for byte in Data(complete.utf8) { try stream.append(byte) }
        XCTAssertEqual(try stream.finish(), "İyi 🌿")
    }

    func testDeltasAndDoneNeverMeanSuccess() throws {
        var stream = ResponsesStream()
        try stream.append(Data(#"data: {"type":"response.output_text.delta","delta":"looks complete"}"#.utf8))
        try stream.append(Data("\n\ndata: [DONE]\n\n".utf8))
        XCTAssertThrowsError(try stream.finish()) { XCTAssertEqual($0 as? ResponsesStreamError, .incomplete) }
    }

    func testQuotaFailureAfterDeltasIsNotCommitted() throws {
        var stream = ResponsesStream()
        try stream.append(Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"draft\"}\n\n".utf8))
        XCTAssertThrowsError(try stream.append(Data("data: {\"type\":\"response.failed\"}\n\n".utf8)))
        XCTAssertThrowsError(try stream.finish())
    }

    func testLateErrorInvalidatesCompletedOutput() throws {
        var stream = ResponsesStream()
        try stream.append(Data(complete.utf8))
        XCTAssertThrowsError(try stream.append(Data("data: {\"type\":\"error\"}\n\n".utf8)))
        XCTAssertThrowsError(try stream.finish())
    }

    func testTruncatedUTF8AndMalformedJSONFail() throws {
        var stream = ResponsesStream()
        try stream.append(Data([0x64, 0x61, 0x74, 0x61, 0x3a, 0xc4]))
        XCTAssertThrowsError(try stream.finish())
        stream = ResponsesStream()
        XCTAssertThrowsError(try stream.append(Data("data: {broken}\n\n".utf8)))
    }

    func testBOMAndAllSSELineEndings() throws {
        for ending in ["\r", "\n", "\r\n"] {
            var stream = ResponsesStream()
            let wire = "\u{feff}: keepalive" + ending + ending +
                "event: response.completed" + ending +
                complete.replacingOccurrences(of: "\r\n", with: ending)
            for byte in wire.utf8 { try stream.append(byte) }
            XCTAssertEqual(try stream.finish(), "İyi 🌿")
        }
    }

    func testIncompleteReasonsAreDistinctFromTruncationAndQuota() {
        for reason in ["max_output_tokens", "content_filter", "private diary words"] {
            var stream = ResponsesStream()
            let event = "data: {\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"\(reason)\"}}}\n\n"
            let expected = ResponsesStreamError.providerIncomplete(reason == "private diary words" ? "unknown" : reason)
            XCTAssertThrowsError(try stream.append(Data(event.utf8))) {
                XCTAssertEqual($0 as? ResponsesStreamError, expected)
            }
            XCTAssertThrowsError(try stream.finish())
            XCTAssertFalse(expected.diagnostic.contains("private diary"))
            XCTAssertFalse(ChatGPTServiceFailure(stage: "RESPONSES_STREAM", fallbackCode: expected.code).isUsageLimit)
        }
    }

    func testCompletedReasoningOnlyIsEmptyOutput() {
        var stream = ResponsesStream()
        let event = #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning"}]}}"# + "\n\n"
        XCTAssertThrowsError(try stream.append(Data(event.utf8))) {
            XCTAssertEqual($0 as? ResponsesStreamError, .emptyOutput)
        }
        XCTAssertThrowsError(try stream.finish())
    }

    func testProgressHasEventMetadataButNoGeneratedText() throws {
        var stream = ResponsesStream()
        let wire = #"data: {"type":"response.output_text.delta","delta":"private diary"}"# + "\n\ndata: [DONE]\n\n"
        try stream.append(Data(wire.utf8))
        XCTAssertThrowsError(try stream.finish())
        XCTAssertTrue(stream.diagnostic.contains("events=1"))
        XCTAssertTrue(stream.diagnostic.contains("last=response.output_text.delta"))
        XCTAssertTrue(stream.diagnostic.contains("done=true"))
        XCTAssertFalse(stream.diagnostic.contains("private"))
    }

    func testUnknownEventNameNeverLeaksIntoDiagnostics() throws {
        var stream = ResponsesStream()
        try stream.append(Data(#"data: {"type":"private_diary_words"}"#.utf8))
        XCTAssertThrowsError(try stream.finish())
        XCTAssertTrue(stream.diagnostic.contains("last=other"))
        XCTAssertFalse(stream.diagnostic.contains("private"))
    }

    func testFinishedMessageSurvivesEmptyTerminalOutput() throws {
        var stream = ResponsesStream()
        let wire = #"data: {"type":"response.created","response":{"status":"in_progress"}}"# + "\n\n" +
            #"data: {"type":"response.output_text.delta","delta":"O"}"# + "\n\n" +
            #"data: {"type":"response.output_text.done","text":"OK"}"# + "\n\n" +
            doneMessage() + emptyCompleted
        for byte in wire.utf8 { try stream.append(byte) }
        XCTAssertEqual(try stream.finish(),"OK")
        XCTAssertTrue(stream.diagnostic.contains("item_done=1"))
        XCTAssertTrue(stream.diagnostic.contains("text_delta=1"))
        XCTAssertTrue(stream.diagnostic.contains("text_done=1"))
        XCTAssertTrue(stream.diagnostic.contains("terminal_items=0"))
    }

    func testFinishedItemAndDoneMarkerAreNotSuccessfulWithoutResponseCompleted() throws {
        var stream = ResponsesStream()
        try stream.append(Data((doneMessage() + "data: [DONE]\n\n").utf8))
        XCTAssertThrowsError(try stream.finish()) { XCTAssertEqual($0 as? ResponsesStreamError,.incomplete) }
    }

    func testFullTerminalOutputIsAuthoritativeAndNotDuplicated() throws {
        var stream = ResponsesStream()
        try stream.append(Data((doneMessage("İyi 🌿") + complete).utf8))
        XCTAssertEqual(try stream.finish(),"İyi 🌿")
    }

    func testMultipleFinishedItemsAreOrderedAndReasoningIsSkipped() throws {
        var stream = ResponsesStream()
        let reasoning = #"data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","summary":[]}}"# + "\n\n"
        try stream.append(Data((reasoning + doneMessage("B",index:2) + doneMessage("A",index:1) + emptyCompleted).utf8))
        XCTAssertEqual(try stream.finish(),"AB")
    }

    func testFailureOrIncompleteAfterFinishedItemNeverProducesOutput() throws {
        for terminal in [
            #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#,
            #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#
        ] {
            var stream = ResponsesStream()
            try stream.append(Data(doneMessage().utf8))
            XCTAssertThrowsError(try stream.append(Data((terminal + "\n\n").utf8)))
            XCTAssertThrowsError(try stream.finish())
        }
    }

    func testRefusalToolAndUnfinishedItemsCannotBeUsedAsFallback() {
        for item in [
            #"{"type":"message","role":"assistant","status":"completed","content":[{"type":"refusal","refusal":"no"}]}"#,
            #"{"type":"function_call","name":"unexpected","arguments":"{}"}"#,
            #"{"type":"message","role":"assistant","status":"incomplete","content":[{"type":"output_text","text":"partial"}]}"#
        ] {
            var stream = ResponsesStream()
            let wire = "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":\(item)}\n\n"
            XCTAssertThrowsError(try stream.append(Data(wire.utf8)))
            XCTAssertThrowsError(try stream.finish())
        }
    }

    func testTextFragmentsAloneCannotReplaceFinishedMessage() throws {
        var stream = ResponsesStream()
        try stream.append(Data((#"data: {"type":"response.output_text.done","text":"partial"}"# + "\n\n").utf8))
        XCTAssertThrowsError(try stream.append(Data(emptyCompleted.utf8))) {
            XCTAssertEqual($0 as? ResponsesStreamError,.emptyOutput)
        }
    }

    func testConflictingFinishedItemsAtSameIndexFail() throws {
        var stream = ResponsesStream()
        try stream.append(Data(doneMessage("first").utf8))
        XCTAssertThrowsError(try stream.append(Data(doneMessage("different").utf8))) {
            XCTAssertEqual($0 as? ResponsesStreamError,.malformedEvent)
        }
    }

    func testTerminalRefusalOverridesBufferedFinishedText() throws {
        var stream = ResponsesStream()
        try stream.append(Data(doneMessage().utf8))
        let terminal = #"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"no"}]}]}}"# + "\n\n"
        XCTAssertThrowsError(try stream.append(Data(terminal.utf8))) {
            XCTAssertEqual($0 as? ResponsesStreamError,.refusal)
        }
    }
    func testLateErrorInvalidatesBufferedFallbackAfterCompletion() throws {
        var stream = ResponsesStream()
        try stream.append(Data((doneMessage() + emptyCompleted).utf8))
        XCTAssertThrowsError(try stream.append(Data("data: {\"type\":\"error\"}\n\n".utf8)))
        XCTAssertThrowsError(try stream.finish())
    }
}
