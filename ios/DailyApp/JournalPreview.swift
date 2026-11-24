#if DEBUG
import Foundation
import DailyCore

@MainActor enum JournalPreview {
    static func records() throws -> [WorkspaceRecord] {
        let date=WorkspaceModel.today,id="preview-writing"
        let sample="Bugün zihnimde kalanları toparlamak istiyorum.\n\nBir süredir üzerinde çalıştığım fikir sonunda netleşiyor. Her şeyi aynı anda çözmek yerine, gerçekten önemli olan parçaya odaklandım.\n\nYarın buradan devam etmek istiyorum."
        let arguments = ProcessInfo.processInfo.arguments
        let text: String
        if arguments.contains("-daily-writing-long") {
            text = String(repeating: sample + "\n\n", count: 120) + "Uzun günlüğün son satırı."
        } else if arguments.contains("-daily-writing-empty") {
            text = ""
        } else if arguments.contains("-daily-writing-full") {
            text = Array(repeating: sample, count: 7).joined(separator: "\n\n")
        } else {
            text = sample
        }
        return [try WorkspaceRecord.make(key:"journal:"+date,kind:.journal,payload:.object([
            "entry":.object(["id":.string(id),"local_date":.string(date),"raw_text":.string(text),
                "content_hash":.string(WorkspaceHash.sha256(text)),"saved_at":.string(ISO8601DateFormatter().string(from:Date())),
                "analysis_status":.string("pending"),"analysis_error":.null]),
            "analyses":.array([]),"questions":.array([])
        ]))]
    }
}
#endif
