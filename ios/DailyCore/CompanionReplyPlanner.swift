import Foundation

public enum CompanionReplyPlanner {
    public static func date(_ event: CompanionEvent) throws -> String {
        guard let at=CompanionCard.date(event.at) else { throw WorkspaceError.malformedRecord }
        let formatter=DateFormatter()
        formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.calendar=Calendar(identifier:.gregorian)
        formatter.timeZone=TimeZone(identifier:"Europe/Istanbul")
        formatter.dateFormat="yyyy-MM-dd"
        return formatter.string(from:at)
    }
    public static func plan(current: WorkspaceRecord?, card: CompanionCard, event: CompanionEvent) throws -> WorkspaceRecord {
        guard event.action=="answer",event.cardId==card.id else { throw WorkspaceError.malformedRecord }
        let date=try date(event)
        guard current == nil || current?.key=="journal:"+date else { throw WorkspaceError.invalidAddress }
        var payload: [String:JSONValue]
        if let current { payload=try current.journal().payload.object! }
        else {
            let created=try WorkspaceSavePlanner.plan(current:nil,expectedHash:nil,date:date,
                text:"Takip yanıtım:\n"+event.text,answers:[:],now:event.at,newID:event.id).record
            payload=try created.journal().payload.object!
        }
        var replies=payload["supplemental_answers"]?.array ?? []
        if replies.contains(where:{$0.object?["id"]?.string==event.id}) {
            return try WorkspaceRecord.make(key:"journal:"+date,kind:.journal,payload:.object(payload))
        }
        replies.append(.object(["id":.string(event.id),"question":.string(card.question),"answer":.string(event.text)]))
        payload["supplemental_answers"] = .array(replies)
        var entry=payload["entry"]!.object!
        entry["analysis_status"] = .string("pending");entry["analysis_error"] = .null
        payload["entry"] = .object(entry)
        return try WorkspaceRecord.make(key:"journal:"+date,kind:.journal,payload:.object(payload))
    }
}
