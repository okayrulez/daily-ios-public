import Foundation

public struct PhoneCommand: Codable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id, intent, text, createdAt: String
    public init(id: String = UUID().uuidString.lowercased(), intent: String, text: String, createdAt: String = CompanionCard.timestamp(Date())) throws {
        guard UUID(uuidString: id) != nil, id == id.lowercased(), ["reflect","improve_daily"].contains(intent),
              !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.utf16.count <= 10000,
              CompanionCard.date(createdAt) != nil else { throw WorkspaceError.malformedRecord }
        self.schemaVersion = 1; self.id = id; self.intent = intent; self.text = text; self.createdAt = createdAt
    }
    public static func decode(_ record: WorkspaceRecord) throws -> Self {
        guard record.kind == .note, let text = try record.payload().string else { throw WorkspaceError.malformedRecord }
        let command = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard command.schemaVersion == 1, record.key == "note:companion/commands/\(command.id).md" else { throw WorkspaceError.malformedRecord }
        return try Self(id:command.id,intent:command.intent,text:command.text,createdAt:command.createdAt)
    }
    public func record() throws -> WorkspaceRecord {
        let json = try JSONValue.parse(String(data: JSONEncoder().encode(self), encoding:.utf8)!).canonical()
        return try WorkspaceRecord.make(key:"note:companion/commands/\(id).md",kind:.note,payload:.string(json))
    }
}
public struct PhoneCommandResult: Decodable, Sendable {
    public let schemaVersion: Int
    public let id, sourceHash, status, message, updatedAt: String
    public static func decode(_ record: WorkspaceRecord, command: WorkspaceRecord) throws -> Self {
        guard record.kind == .note, let text = try record.payload().string else { throw WorkspaceError.malformedRecord }
        let result = try JSONDecoder().decode(Self.self, from:Data(text.utf8))
        guard result.schemaVersion == 1, result.id == (try PhoneCommand.decode(command)).id,
              result.sourceHash == command.hash, record.key == "note:companion/command-results/\(result.id).md",
              ["received","processing","complete","failed","awaiting_pc"].contains(result.status), result.message.utf16.count <= 12000 else { throw WorkspaceError.malformedRecord }
        return result
    }
    public var statusLabel: String {
        switch status {
        case "received": "PC’ye ulaştı"
        case "processing": "Codex sırasında"
        case "complete": "Değerlendirildi"
        case "failed": "Yeniden deneme gerekiyor"
        default: "PC’de geliştirme bekliyor"
        }
    }
}
