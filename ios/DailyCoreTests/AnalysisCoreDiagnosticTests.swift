import Foundation
import XCTest
@testable import DailyCore

final class AnalysisCoreDiagnosticTests: XCTestCase {
    func testCheckedBridgeRetainsSuccessfulResult() throws {
        let result = try AnalysisCore.invoke("emptyMemory", json: "{}")
        let memory = try PortableMemory(json: result)
        XCTAssertEqual(memory.revision, 0)
    }

    func testValidationMetadataSurvivesBridgeAndDiagnosticLog() throws {
        let input = #"{"rawText":"private-diary","result":{"reflection":123,"private-key":"secret"}}"#
        do {
            _ = try AnalysisCore.invoke("validateJournal", json: input)
            XCTFail("Invalid result must not be accepted")
        } catch let error as AnalysisValidationFailure {
            XCTAssertEqual(error.command, "validateJournal")
            XCTAssertEqual(error.code, "schema_validation")
            XCTAssertTrue(error.issues.contains("invalid_type:reflection"))
            let entry = ConnectionDiagnosticEntry(stage: "ANALYSIS_INFERENCE", outcome: "failed", error: error)
            XCTAssertEqual(entry.fields["analysis_command"], "validateJournal")
            XCTAssertEqual(entry.fields["code"], "schema_validation")
            XCTAssertTrue(entry.report.contains("invalid_type:reflection"))
            for secret in ["private-diary", "private-key", "secret"] {
                XCTAssertFalse(entry.report.contains(secret))
                XCTAssertFalse(error.diagnostic.contains(secret))
            }
        }
    }

    func testInvalidJSONHasStableCodeWithoutInput() throws {
        do {
            _ = try AnalysisCore.invoke("validateJournal", json: "{private-diary")
            XCTFail("Invalid JSON must fail")
        } catch let error as AnalysisValidationFailure {
            XCTAssertEqual(error.code, "invalid_json")
            XCTAssertTrue(error.issues.isEmpty)
            XCTAssertFalse(error.diagnostic.contains("private-diary"))
        }
    }

    func testFallbackCoreFailuresHaveExplicitNames() {
        let entry = ConnectionDiagnosticEntry(stage: "ANALYSIS_INFERENCE", outcome: "failed", error: AnalysisCoreError.invalidOutput)
        XCTAssertEqual(entry.fields["code"], "analysis_bridge_invalid_output")
        XCTAssertNil(entry.fields["native_code"])
    }
}
