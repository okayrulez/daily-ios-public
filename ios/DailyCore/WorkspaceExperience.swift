import Foundation

public struct ExperienceEvent: Codable, Identifiable, Equatable, Sendable {
    public let id, kind, subjectID, title, text, value, createdAt: String
    public init(kind: String, subjectID: String, title: String, text: String = "", value: String, now: String = CompanionCard.timestamp(Date())) throws {
        guard ["agenda_checkin", "question_known"].contains(kind), !subjectID.isEmpty, subjectID.utf16.count <= 500,
              title.utf16.count <= 2000, text.utf16.count <= 2000, CompanionCard.date(now) != nil,
              (kind == "agenda_checkin" ? ["done", "postponed", "skipped"].contains(value) : value == "known") else { throw WorkspaceError.malformedRecord }
        self.id = WorkspaceHash.sha256(kind + ":" + subjectID)
        self.kind = kind; self.subjectID = subjectID; self.title = title; self.text = text; self.value = value; self.createdAt = now
    }
}
public struct WorkspaceExperience: Codable, Sendable {
    public static let key = "note:companion/experience.json"
    public var schemaVersion = 1
    public var items: [ExperienceEvent] = []
    public init() {}
    public init(record: WorkspaceRecord?) throws {
        guard let record else { self.init(); return }
        guard record.key == Self.key, let text = try record.payload().string else { throw WorkspaceError.malformedRecord }
        self = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard schemaVersion == 1, items.count <= 500, Set(items.map(\.id)).count == items.count else { throw WorkspaceError.malformedRecord }
        for item in items {
            guard try ExperienceEvent(kind: item.kind, subjectID: item.subjectID, title: item.title, text: item.text, value: item.value, now: item.createdAt) == item else { throw WorkspaceError.malformedRecord }
        }
    }
    public func recording(_ event: ExperienceEvent) throws -> Self {
        var next = self
        if let index = next.items.firstIndex(where: { $0.id == event.id }) { next.items[index] = event }
        else { next.items.append(event) }
        // Keep all explicit question preferences; older occurrence check-ins are bounded.
        if next.items.count > 500 {
            guard let index = next.items.enumerated().filter({ $0.element.kind == "agenda_checkin" })
                .min(by: { $0.element.createdAt < $1.element.createdAt })?.offset else { throw WorkspaceError.oversizedRecord }
            next.items.remove(at: index)
        }
        return next
    }
    public func record() throws -> WorkspaceRecord {
        let data = try JSONEncoder().encode(self)
        return try WorkspaceRecord.make(key: Self.key, kind: .note, payload: .string(JSONValue.parse(String(decoding:data,as:UTF8.self)).canonical()))
    }
    public var context: String {
        let selected = items.sorted { $0.createdAt > $1.createdAt }.prefix(60)
        var rows: [[String:String]] = []
        for item in selected {
            let row = ["kind":item.kind,"subject":item.subjectID,"questionOrActivity":item.title,"answer":item.text,"value":item.value,"at":item.createdAt]
            guard let data=try? JSONEncoder().encode(rows+[row]),data.count <= 12000 else { continue }
            rows.append(row)
        }
        return String(decoding:(try? JSONEncoder().encode(rows)) ?? Data("[]".utf8),as:UTF8.self)
    }
}

public struct WorkspaceChangeReceipt: Decodable, Identifiable, Sendable {
    public let id, date, createdAt, resultHash, memoryHash, sourceHash: String
    public let priorManifest: JSONValue
    public let changes: AnalysisChanges
    public let agenda: [String]
    public let undone: Bool?
    public static func decode(_ record: WorkspaceRecord) throws -> Self {
        guard record.key.hasPrefix("note:companion/changes/"), let text=try record.payload().string else { throw WorkspaceError.malformedRecord }
        let value=try JSONDecoder().decode(Self.self,from:Data(text.utf8))
        guard record.key == "note:companion/changes/"+value.id+".json", WorkspaceIdentity.validDate(value.date),
              WorkspaceHash.valid(value.resultHash), WorkspaceHash.valid(value.memoryHash), WorkspaceHash.valid(value.sourceHash) else { throw WorkspaceError.malformedRecord }
        return value
    }
}
