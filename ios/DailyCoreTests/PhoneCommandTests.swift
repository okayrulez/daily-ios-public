import XCTest
@testable import DailyCore
final class PhoneCommandTests: XCTestCase {
    func testImmutableIDSurvivesRoundtripAndRejectsInvalidRequests() throws {
        let command = try PhoneCommand(intent:"improve_daily",text:"Ajandayı genişlet")
        let record = try command.record()
        let restored = try PhoneCommand.decode(record)
        XCTAssertEqual(restored.id,command.id)
        XCTAssertEqual(try restored.record(),record)
        XCTAssertThrowsError(try PhoneCommand(intent:"shell",text:"execute"))
        XCTAssertThrowsError(try PhoneCommand(intent:"reflect",text:"  "))
        let wrong = try WorkspaceRecord.make(key:"note:companion/commands/other.md",kind:.note,payload:record.payload())
        XCTAssertThrowsError(try PhoneCommand.decode(wrong))
    }
    func testResultsAreBoundToExactPrompt() throws {
        let command = try PhoneCommand(intent:"reflect",text:"Bir düşünce")
        let source = try command.record()
        let fields: [String:Any] = ["schemaVersion":1,"id":command.id,"sourceHash":source.hash,"status":"complete","message":"Bir yorum","updatedAt":command.createdAt]
        let text = String(data:try JSONSerialization.data(withJSONObject:fields),encoding:.utf8)!
        let result = try WorkspaceRecord.make(key:"note:companion/command-results/\(command.id).md",kind:.note,payload:.string(text))
        XCTAssertEqual(try PhoneCommandResult.decode(result,command:source).status,"complete")
        let other = try PhoneCommand(id:command.id,intent:"reflect",text:"Değişmiş düşünce",createdAt:command.createdAt).record()
        XCTAssertThrowsError(try PhoneCommandResult.decode(result,command:other))
    }
}
