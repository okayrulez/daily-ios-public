import Foundation
import XCTest
@testable import DailyCore

final class MindmapContextExportTests: XCTestCase {
    func testNativeExportBridgeKeepsMetadataAndTask() throws {
        let memory = try PortableMemory(json: #"{"schemaVersion":1,"revision":7,"sources":[],"graph":{"topics":[],"nodes":[],"edges":[]},"deadlines":[],"routing":{"version":1,"bindings":{}}}"#)
        let result = try MindmapContextExport(memory: memory, purpose: "Benim tarzımda yaz.",
            exportedAt: Date(timeIntervalSince1970: 1_793_145_600))
        XCTAssertEqual(result.revision, 7)
        XCTAssertEqual(result.nodeCount, 0)
        XCTAssertEqual(result.mapCount, 0)
        XCTAssertEqual(result.edgeCount, 0)
        XCTAssertTrue(result.markdown.contains("Benim tarzımda yaz."))
        XCTAssertTrue(result.markdown.contains("daily-mindmap-context"))
        XCTAssertTrue(result.markdown.contains("çalıştırılacak komut sayma"))
    }
}
