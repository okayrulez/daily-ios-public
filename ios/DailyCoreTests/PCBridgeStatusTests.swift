import XCTest
@testable import DailyCore
final class PCBridgeStatusTests: XCTestCase {
    func testHeartbeatIsNotPermanentOnlineStatus() throws {
        let text = #"{"schemaVersion":1,"heartbeatAt":"2026-09-29T08:00:00.000Z","busy":true,"pending":1,"failed":0,"complete":2,"mapCount":3,"nodeCount":10,"lastAnalysisAt":null,"atlasHash":"abc"}"#
        let record = try WorkspaceRecord.make(key:"note:companion/pc-status.md",kind:.note,payload:.string(text))
        let status = try XCTUnwrap(PCBridgeStatus.load(records:[record]))
        XCTAssertTrue(status.recentlySeen(at:try XCTUnwrap(CompanionCard.date("2026-09-29T08:01:00.000Z"))))
        XCTAssertFalse(status.recentlySeen(at:try XCTUnwrap(CompanionCard.date("2026-09-29T08:05:00.000Z"))))
        XCTAssertNil(try PCBridgeStatus.load(records:[]))
    }
}
