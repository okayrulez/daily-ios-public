import SwiftUI
import DailyCore

/// Calendar badges and selected-day details share one local agenda projection.
struct JournalCalendarView: View {
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.locale) private var locale
    @Binding var month: Date
    @Binding var selectedDate: String
    let activityCounts: [String: Int]
    let availableHeight: CGFloat
    var onSelect: ((String) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
    private var cells: [Date?] { JournalCalendar.cells(in: month) }
    private var firstJournalDate: String? {
        model.dates.last { date in
            let state = JournalDayState.resolve(date: date, today: WorkspaceModel.today, firstDate: nil,
                journal: model.journal(date: date), draftText: model.drafts[date]?.text)
            return state != .empty
        }
    }
    private var rowHeight: CGFloat {
        min(108, max(64, (availableHeight * 0.72 - 94) / CGFloat(max(1, cells.count / 7))))
    }
    private var title: String {
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = JournalCalendar.calendar()
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: month).capitalized(with: locale)
    }
    var body: some View {
        let firstDate = firstJournalDate
        let today = WorkspaceModel.today
        let monthCells = cells
        let height = rowHeight
        VStack(spacing: 16) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 24, weight: .semibold))
                    .minimumScaleFactor(0.7).lineLimit(1)
                Spacer(minLength: 4)
                Button("Bugün") {
                    month = Date(); selectedDate = WorkspaceModel.today
                }.font(.caption.bold()).padding(.horizontal, 12).frame(minHeight: 44)
                    .background(DailyTheme.paper, in: Capsule())
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("Önceki ay")
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .accessibilityLabel("Sonraki ay")
            }.buttonStyle(.plain)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(["Pzt", "Sal", "Çar", "Per", "Cum", "Cmt", "Paz"], id: \.self) {
                    Text(LocalizedStringKey($0)).font(.caption.weight(.semibold)).foregroundStyle(DailyTheme.muted).padding(.bottom, 5)
                }
                ForEach(monthCells.indices, id: \.self) { index in
                    if let date = monthCells[index] { day(date, firstDate: firstDate, today: today, height: height) }
                    else { Color.clear.frame(height: height).accessibilityHidden(true) }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { legend }
                VStack(alignment: .leading, spacing: 6) { legend }
            }.font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private var legend: some View {
        Label("Aktivite sayısı", systemImage: "number.circle.fill").foregroundStyle(DailyTheme.mint)
        Label("Duygu izleri", systemImage: "face.smiling").foregroundStyle(DailyTheme.cobalt)
        Label("Günlük yazılmadı", systemImage: "circle.fill").foregroundStyle(DailyTheme.orange)
    }
    private func move(_ offset: Int) {
        let calendar = JournalCalendar.calendar()
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let next = calendar.date(byAdding: .month, value: offset, to: start) else { return }
        month = next
        selectedDate = calendar.isDate(next, equalTo: Date(), toGranularity: .month)
            ? WorkspaceModel.today : JournalCalendar.key(next)
    }
    private func day(_ date: Date, firstDate: String?, today todayKey: String, height: CGFloat) -> some View {
        let key = JournalCalendar.key(date)
        let count = activityCounts[key, default: 0]
        let selected = selectedDate == key
        let today = key == todayKey
        let state = JournalDayState.resolve(date: key, today: todayKey, firstDate: firstDate,
            journal: model.journal(date: key), draftText: model.drafts[key]?.text)
        let missed = state == .missed

        let background: Color = missed ? .yellow.opacity(0.25)
            : selected || state == .answered || state == .written || state == .draft ? DailyTheme.paleBlue : DailyTheme.paper
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selectedDate = key }
            onSelect?(key)
        } label: {
            VStack(spacing: 4) {
                Text("\(JournalCalendar.calendar().component(.day, from: date))")
                    .font(.system(size: 17, weight: today || selected ? .bold : .medium, design: .rounded))
                if count > 0 {
                    Text("\(count)").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.6).lineLimit(1)
                        .frame(minWidth: 20, minHeight: 20).padding(.horizontal, 2)
                        .foregroundStyle(DailyTheme.navy)
                        .background(DailyTheme.energy.opacity(0.24), in: Capsule())
                } else { Color.clear.frame(height: 20).accessibilityHidden(true) }
                if model.unreadableDraftDates.contains(key) {
                    Image(systemName: "exclamationmark.triangle").font(.caption2)
                        .foregroundStyle(DailyTheme.orange).accessibilityHidden(true)
                } else if state == .draft {
                    Text("Taslak").font(.caption2).foregroundStyle(DailyTheme.cobalt)
                }
                if let day = model.emotionDays.first(where: { $0.date == key }), !day.keys.isEmpty {
                    EmotionBadges(day: day, compact: true)
                }
            }.frame(maxWidth: .infinity).frame(height: max(82, height))
                .foregroundStyle(DailyTheme.ink)
                .background(background,
                            in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(selected || today ? DailyTheme.mint : DailyTheme.line.opacity(0.4), lineWidth: selected ? 1.8 : today ? 1.2 : 0.5))
        }.buttonStyle(.plain)
            .accessibilityIdentifier("calendar-day-\(key)")
            .accessibilityLabel("\(key)\(today ? ", bugün" : ""), \(count > 0 ? "\(count) aktivite" : "aktivite yok")\(model.unreadableDraftDates.contains(key) ? ", taslak okunamadı" : state == .draft ? ", cihazdaki taslak" : missed ? ", günlük yazılmadı" : "")")
            .accessibilityHint("Bu günün kaydını, aktivitelerini ve yorumunu açar")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
