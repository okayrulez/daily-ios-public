#if DEBUG
import Foundation
import DailyCore
@MainActor enum ExperiencePreview {
    static func records(for requestedDate: String? = nil) throws -> [WorkspaceRecord] {
        var records=try AgendaPreview.records()+AtlasPreview.records()
        let date=requestedDate ?? WorkspaceModel.today,id="preview-task",text="Üzerinde çalıştığım projeyle ilgili kaynaklı bir araştırma istiyorum."
        let task:JSONValue = .object(["goal":.string("Proje için kaynakları karşılaştır"),"status":.string("needs_input"),
            "reply":.string("Hangi iki yaklaşımı karşılaştıracağımızı netleştirelim. Kaynak araması bu yanıttan sonra başlayacak."),
            "inputHash":.string("preview"),"rawTextHash":.string(WorkspaceHash.sha256(text)),"round":.number(1)])
        let journal=try WorkspaceRecord.make(key:"journal:"+date,kind:.journal,payload:.object([
            "entry":.object(["id":.string(id),"local_date":.string(date),"raw_text":.string(text),"content_hash":.string(WorkspaceHash.sha256(text)),
                "saved_at":.string("2026-11-03T10:00:00Z"),"analysis_status":.string("complete"),"analysis_error":.null]),
            "questions":.array([]),"analyses":.array([]),"daily_task":task]))
        records.removeAll {$0.key == journal.key};records.append(journal)
        let changes=try AnalysisChanges(before:JSONValue.parse(#"{"nodes":[],"edges":[]}"#),
            after:JSONValue.parse(#"{"nodes":[{"id":"n1"},{"id":"n2"},{"id":"n3"}],"edges":[{"id":"e1"},{"id":"e2"}]}"#),questionCount:2)
        let receipt=try WorkspaceRecord.make(key:"note:companion/changes/preview.json",kind:.note,payload:.string(JSONValue.object([
            "id":.string("preview"),"date":.string(date),"createdAt":.string("2026-11-03T10:00:00Z"),"sourceHash":.string(journal.hash),"resultHash":.string(journal.hash),
            "memoryHash":.string(String(repeating:"a",count:64)),"priorManifest":.null,
            "changes":try JSONValue.parse(String(decoding:JSONEncoder().encode(changes),as:UTF8.self)),"agenda":.array([.string("Kaydedildi: Yüzme · Salı / Perşembe 18.00")])]).canonical()))
        records.append(receipt)
        return records
    }
    static func emotionTimelineRecords() throws -> [WorkspaceRecord] {
        let yesterday = JournalCalendar.calendar().date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let dates = [JournalCalendar.key(yesterday), WorkspaceModel.today]
        let quote = "Sunumdan önce gerildim"
        let reflection = "Sunumdan sonra rahatladın."
        var records = try AtlasPreview.records()
        let today = WorkspaceModel.today
        for date in dates {
            let id = "emotion-preview-" + date
            let raw = date + " · " + quote + ", sonra rahatladım."
            let at = date + "T12:00:00Z"
            let observations: [JSONValue] = [
                .object(["key": .string("tension"), "label": .string("Gerilim"), "sequence": .number(0),
                         "event": .string("Sunum öncesi"), "context_key": .string("presentation"), "context_label": .string("Sunum"), "quote": .string(quote)]),
                .object(["key": .string("relief"), "label": .string("Rahatlama"), "sequence": .number(1),
                         "event": .string("Sunum sonrası"), "context_key": .string("presentation"), "context_label": .string("Sunum"), "quote": .string("sonra rahatladım")])
            ]
            records.append(try WorkspaceRecord.make(key: "journal:" + date, kind: .journal, payload: .object([
                "entry": .object(["id": .string(id), "local_date": .string(date), "raw_text": .string(raw),
                    "content_hash": .string(WorkspaceHash.sha256(raw)), "saved_at": .string(at), "analysis_status": .string("complete"), "analysis_error": .null]),
                "analyses": .array([.object(["id": .string("analysis-" + date), "journal_id": .string(id), "version": .number(1),
                    "provider": .string("fixture"), "reflection": .string(reflection), "confidence": .string("medium"), "created_at": .string(at)])]),
                "questions": .array([]), "emotional_memory": .object(["observations": .array(observations)])
            ])))
        }
        let index = try records.first { $0.key == "note:companion/atlas/index.md" }!.payload().string!
        var indexFields = try JSONValue.parse(index).object!
        var map = indexFields["maps"]!.array![0].object!
        let mapID = map["id"]!.string!
        let detail = try WorkspaceRecord.make(key: "note:companion/atlas/" + mapID + "-notes-0.md", kind: .note,
            payload: .string(JSONValue.object(["schemaVersion": .number(1), "mapId": .string(mapID), "kind": .string("notes"),
                "items": .array([.object(["nodeId": .string("n0"), "kind": .string("observation"), "date": .string(today),
                    "text": .string(reflection), "quote": .string(quote), "sourceId": .string("emotion-preview-" + today)])])]).canonical()))
        map["detailPages"] = .array([.object(["key": .string(detail.key), "hash": .string(detail.hash)])])
        indexFields["maps"] = .array([.object(map)])
        records.removeAll { $0.key == "note:companion/atlas/index.md" }
        records.append(detail)
        records.append(try WorkspaceRecord.make(key: "note:companion/atlas/index.md", kind: .note,
            payload: .string(JSONValue.object(indexFields).canonical())))
        return records
    }
}
#endif
