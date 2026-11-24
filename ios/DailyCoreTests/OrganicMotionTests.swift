import XCTest
@testable import DailyCore

final class OrganicMotionTests: XCTestCase {
    func testBranchesMoveWithoutMovingTheirAnchors() {
        let a = CGPoint(x: 10, y: 200), b = CGPoint(x: 260, y: 30)
        let first = OrganicMotion.branch(from: a, to: b, key: "node", channels: OrganicMotion.defaults, time: 0)
        let next = OrganicMotion.branch(from: a, to: b, key: "node", channels: OrganicMotion.defaults, time: 5)
        XCTAssertEqual(first.stem.first, a); XCTAssertEqual(first.stem.last, b)
        XCTAssertEqual(next.stem.first, a); XCTAssertEqual(next.stem.last, b)
        XCTAssertNotEqual(first.segments, next.segments)
        XCTAssertEqual(next.segments, OrganicMotion.branch(from: a, to: b, key: "node", channels: OrganicMotion.defaults, time: 5).segments)
    }
    func testChannelsAreBoundedAndDensePlantsHaveFiniteBudget() {
        XCTAssertEqual(OrganicMotion.normalized([.nan, -4, 9000, 620, 384, 690]), [674, 0, 1023, 620, 384, 690, 694, 512])
        let a = CGPoint.zero, b = CGPoint(x: 100, y: -200)
        let base = OrganicMotion.branch(from: a, to: b, key: "n", channels: OrganicMotion.defaults, time: 3)
        for i in 0..<8 {
            var controls = OrganicMotion.defaults; controls[i] = controls[i] < 512 ? 950 : 50
            XCTAssertNotEqual(base.segments, OrganicMotion.branch(from: a, to: b, key: "n", channels: controls, time: 3).segments)
        }
        let dense = OrganicMotion.branch(from: a, to: b, key: "n", channels: Array(repeating: 1023, count: 6), time: 3, budget: 600)
        XCTAssertLessThanOrEqual(dense.segments.count, 600)
        XCTAssertTrue(dense.segments.allSatisfy { $0.a.x.isFinite && $0.b.y.isFinite && $0.width.isFinite })
        XCTAssertTrue(OrganicMotion.branch(from: a, to: a, key: "n", channels: [], time: 0).segments.isEmpty)
    }
}
