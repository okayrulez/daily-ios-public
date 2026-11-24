import SwiftUI
import DailyCore

struct ManagedAgendaSection: View {
    @EnvironmentObject private var model: WorkspaceModel
    let date: String
    let items: [AgendaOccurrence]
    let error: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayLabel).font(.title3.bold())
                Spacer()
                if !error { Text("\(items.count) aktivite").font(.subheadline).foregroundStyle(DailyTheme.muted) }
            }
            if error {
                Text("Ajanda kaydı okunamadı. Yenilemek için aşağı çek; kayıtların korunuyor.")
                    .font(.subheadline).dailyCard()
            } else if items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bu gün boş.").font(.headline)
                    Text("Planını Bugün’e yazıp Daily butonuna dokun. Ajandaya kaydedilince burada görünür.")
                        .font(.subheadline).foregroundStyle(DailyTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18).dailyGlass(cornerRadius: 20)
            }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 8) {
                        Text(item.time ?? "Tüm gün").font(.subheadline.bold().monospacedDigit())
                        Circle().strokeBorder(DailyTheme.mint, lineWidth: 2).frame(width: 10, height: 10)
                        Capsule().fill(DailyTheme.energy.opacity(0.35)).frame(width: 2, height: 24)
                    }.frame(width: 66)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.title).font(.headline)
                        if !item.details.isEmpty { Text(item.details).font(.subheadline).foregroundStyle(DailyTheme.muted) }
                        if item.frequency != "once" {
                            Label(recurrence(item.frequency), systemImage: "repeat").font(.caption).foregroundStyle(DailyTheme.muted)
                        }
                        if let result = model.appleAgendaResults[item.eventID] {
                            Label(result.message, systemImage: result.saved ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(result.saved ? Color.green : DailyTheme.orange)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(18).dailyGlass(cornerRadius: 22, accent: DailyTheme.energy)
            }
            if date <= WorkspaceModel.today {
                Button { model.showJournal(date: date) } label: {
                    Label("Bu günün günlüğünü aç", systemImage: "book.closed").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.plain)
            }
        }
    }
    private var dayLabel: String {
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = JournalCalendar.calendar(); parser.dateFormat = "yyyy-MM-dd"
        guard let day = parser.date(from: date) else { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM EEEE"
        return formatter.string(from: day)
    }
    private func recurrence(_ value: String) -> String {
        switch value {
        case "daily": return "Günlük düzen"
        case "weekly": return "Haftalık düzen"
        case "monthly": return "Aylık düzen"
        default: return ""
        }
    }
}
