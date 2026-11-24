import Foundation
import XCTest
@testable import DailyCore

final class AnalysisScopeGuardTests: XCTestCase {
    func testWorkspaceChangeIsDistinctFromTimeoutAndAccountChange() throws {
        XCTAssertNoThrow(try AnalysisScopeGuard.check(sessionMatches:true,workspaceMatches:true,phase:.afterInference))
        XCTAssertThrowsError(try AnalysisScopeGuard.check(sessionMatches:true,workspaceMatches:false,phase:.afterInference)) { error in
            let entry=ConnectionDiagnosticEntry(stage:"TASK_ROUTE",outcome:"failed",error:error)
            XCTAssertEqual(entry.fields["code"],"analysis_workspace_changed")
            XCTAssertEqual(entry.fields["guard_phase"],"after_inference")
            XCTAssertNotEqual(entry.fields["code"],"network_timeout")
        }
        XCTAssertThrowsError(try AnalysisScopeGuard.check(sessionMatches:true,workspaceMatches:true,
            accountMatches:false,phase:.beforeInference)) { error in
            XCTAssertEqual(ConnectionDiagnosticEntry(stage:"ANALYSIS_PREPARE",outcome:"failed",error:error).fields["code"],"analysis_ai_account_changed")
        }
    }
    func testLegacyWorkspaceErrorsHaveExplicitStableReasons() {
        for (error,code) in [(WorkspaceRequestError.malformed,"workspace_request_malformed"),
                             (.sourceChanged,"workspace_source_changed"),(.accountChanged,"workspace_account_changed")] {
            XCTAssertEqual(ConnectionDiagnosticEntry(stage:"TASK_ROUTE",outcome:"failed",error:error).fields["code"],code)
        }
    }
    func testNetworkTimeoutAndSafeRequestMetricsAreVisibleWithoutPrivateErrorText() {
        let error=NSError(domain:NSURLErrorDomain,code:URLError.timedOut.rawValue,userInfo:[NSLocalizedDescriptionKey:"private diary"])
        let entry=ConnectionDiagnosticEntry(stage:"routeTask",outcome:"failed",error:error,promptBytes:3456,elapsedMilliseconds:23000)
        XCTAssertEqual(entry.fields["code"],"network_timeout")
        XCTAssertEqual(entry.fields["prompt_bytes"],"3456")
        XCTAssertEqual(entry.fields["elapsed_ms"],"23000")
        XCTAssertFalse(entry.report.contains("private diary"))
    }
}
