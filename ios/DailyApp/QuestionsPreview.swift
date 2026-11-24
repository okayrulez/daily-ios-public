#if DEBUG
import Foundation
import DailyCore

@MainActor
enum QuestionsPreview {
    static func records() throws -> [WorkspaceRecord] {
        let calendar = JournalCalendar.calendar()
        return try [-6, -4, -1, 0].map { offset in
            let date = JournalCalendar.key(calendar.date(byAdding: .day, value: offset, to: Date())!)
            return try record(date: date, answered: offset == -6 || offset == -1)
        }
    }

    private static func record(date: String, answered: Bool) throws -> WorkspaceRecord {
        let id = "preview-journal-\(date)", text = "Bugün proje üzerinde çalıştım ve akşam yürüyüş yaptım."
        let prompts = ["Bugün kendine ayırdığın zaman sana iyi geldi mi?", "Projedeki ilerleme beklediğin gibi oldu mu?", "Yarın için net bir önceliğin var mı?"]
        let questions = prompts.enumerated().map { index, prompt in JSONValue.object([
            "id": .string("preview-\(date)-\(index)"), "journal_id": .string(id), "kind": .string("boolean"), "position": .number(Double(index)),
            "prompt": .string(prompt), "rationale": .string("Günlüğünde anlattığın çalışma ve dinlenme dengesi üzerine."), "source_ref": .string(id),
            "answer_text": .null, "answer_boolean": answered ? .number(index == 1 ? 0 : 1) : .null
        ]) }
        return try WorkspaceRecord.make(key: "journal:\(date)", kind: .journal, payload: .object([
            "entry": .object(["id": .string(id), "local_date": .string(date), "raw_text": .string(text), "content_hash": .string(WorkspaceHash.sha256(text)),
                "saved_at": .string("2026-09-29T08:00:00.000Z"), "analysis_status": .string("complete"), "analysis_error": .null]),
            "questions": .array(questions), "analyses": .array([])
        ]))
    }
}
#endif
