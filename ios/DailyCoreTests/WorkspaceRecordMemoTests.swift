import XCTest
@testable import DailyCore

final class WorkspaceRecordMemoTests: XCTestCase {
    func testRepeatedRenderingDecodesUnchangedRecordsOnlyOnce() throws {
        let memo = WorkspaceRecordMemo<String>()
        let first = try WorkspaceRecord.make(key: "note:example", kind: .note, payload: .string("first"))
        let changed = try WorkspaceRecord.make(key: first.key, kind: .note, payload: .string("changed"))
        var decodes = 0
        func decode(_ record: WorkspaceRecord) throws -> String {
            decodes += 1
            return try XCTUnwrap(record.payload().string)
        }
        for _ in 0..<100 {
            XCTAssertEqual(memo.value(for: first, decode: decode), "first")
        }
        XCTAssertEqual(decodes, 1)
        XCTAssertEqual(memo.value(for: changed, decode: decode), "changed")
        XCTAssertEqual(decodes, 2)
        memo.reset()
        XCTAssertEqual(memo.value(for: changed, decode: decode), "changed")
        XCTAssertEqual(decodes, 3)
    }

    func testMissingAndRejectedRecordsDoNotRepeatFailedDecodes() throws {
        enum Rejected: Error { case record }
        let memo = WorkspaceRecordMemo<String>()
        let record = try WorkspaceRecord.make(key: "note:example", kind: .note, payload: .string("bad"))
        var decodes = 0
        func decode(_ record: WorkspaceRecord) throws -> String {
            decodes += 1
            throw Rejected.record
        }
        XCTAssertNil(memo.value(for: nil, decode: decode))
        XCTAssertEqual(decodes, 0)
        for _ in 0..<100 { XCTAssertNil(memo.value(for: record, decode: decode)) }
        XCTAssertEqual(decodes, 1)
        memo.reset()
        XCTAssertNil(memo.value(for: record, decode: decode))
        XCTAssertEqual(decodes, 2)
    }
}
