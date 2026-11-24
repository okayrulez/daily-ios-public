import SwiftUI
import DailyCore

/// Uses the production emotion badges and flow renderer with prepared, read-only example data.
struct GuidedTourEmotionExperience: View {
    var showsFlow = false
    @EnvironmentObject private var tour: GuidedTourController
    @State private var selected: EmotionEpisodeSelection?
    private var calendar: Calendar { JournalCalendar.calendar() }
    private var sampleDate: Date {
        calendar.nextDate(after: calendar.startOfDay(for: Date()).addingTimeInterval(-1),
                          matching: DateComponents(weekday: 3), matchingPolicy: .nextTime) ?? Date()
    }
    private var sample: EmotionDay {
        GuidedTourExample.emotionDay(date: JournalCalendar.key(sampleDate),
            previousDate: JournalCalendar.key(calendar.date(byAdding: .day, value: -7, to: sampleDate) ?? sampleDate),
            language: tour.language.rawValue)
    }
    var body: some View {
        let sampleDay = sample
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if showsFlow {
                    Label("Akış", systemImage: "waveform.path").font(.subheadline.weight(.semibold)).foregroundStyle(DailyTheme.cobalt)
                        .accessibilityIdentifier("tour-emotion-flow")
                    EmotionDaySummary(day: sampleDay, showsDisclosure: false)
                        .padding(14).dailyGlass(cornerRadius: 22)
                    // The sample event cards open a read-only excerpt from the demo journal.
                    EmotionDayFlow(day: sampleDay) { episode in
                        selected = EmotionEpisodeSelection(day: sampleDay, episode: episode)
                    }.padding(14).dailyGlass(cornerRadius: 24)
                        // An identifier on the composite flow can propagate to its buttons.
                        // Keep the tour marker on the heading, not on actionable descendants.
                        .tourHighlight("emotion-flow")
                    Text("Bir olaya dokunarak günlükteki cümleyi oku.").font(.footnote).foregroundStyle(DailyTheme.muted)
                } else {
                    DailySectionHeading(eyebrow: "Örnek duygu verileri", title: "Duygu izlerin",
                        detail: "Günlüğündeki anlatım sırasıyla.")
                    VStack(alignment: .leading, spacing: 12) {
                        Text(sampleDate, format: .dateTime.month(.wide).year()).font(.headline)
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { offset in
                                let date = calendar.date(byAdding: .day, value: offset - 1, to: sampleDate) ?? sampleDate
                                let active = offset == 1
                                VStack(spacing: 6) {
                                    Text("\(calendar.component(.day, from: date))").font(.subheadline.weight(active ? .bold : .regular))
                                    if active {
                                        Text(tour.simulation.reminder == true ? "2" : "1")
                                            .font(.caption.bold()).frame(width: 20, height: 20)
                                            .background(DailyTheme.energy.opacity(0.24), in: Circle())
                                        EmotionBadges(day: sampleDay, compact: true)
                                    } else { Spacer(minLength: 0) }
                                }.frame(maxWidth: .infinity).frame(height: 82)
                                    .background(active ? DailyTheme.paleBlue : .white.opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
                                    .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(active ? DailyTheme.mint : DailyTheme.line.opacity(0.4)) }
                            }
                        }
                    }.padding(14).dailyGlass(cornerRadius: 24)
                        .tourHighlight("emotion-day").accessibilityIdentifier("tour-emotion-day")
                    reflection(sampleDay)
                    Text("Emojilerini Ayarlar → Duygular ve emojiler bölümünden seçebilirsin.")
                        .font(.footnote).foregroundStyle(DailyTheme.muted)
                }
            }.padding(20).padding(.bottom, 320)
        }.background { DailyCanvas { Color.clear } }
            .navigationTitle("Ajanda").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(item: $selected) { selection in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(selection.episode.title).font(.title3.weight(.semibold))
                            ForEach(selection.episode.observations) { observation in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(LocalizedStringKey(observation.label)).font(.headline)
                                        .foregroundStyle(EmotionStyle.color(observation.key))
                                    Text("“" + observation.quote + "”").font(.subheadline)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            reflection(selection.day)
                        }.padding(20)
                    }.accessibilityIdentifier("tour-emotion-detail")
                        .navigationTitle(selection.day.date).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { selected = nil } } }
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
    }
    private func reflection(_ day: EmotionDay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Yansıma", systemImage: "sparkles").font(.headline)
            Text(day.reflection).font(.subheadline).lineSpacing(4)
            ScrollView(.horizontal) { EmotionBadges(day: day) }.scrollIndicators(.hidden)
            Text("Günlükten yorumlandı · Örnek").font(.caption).foregroundStyle(DailyTheme.muted)
            ForEach(day.connections) { connection in
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.date).font(.caption.bold()).foregroundStyle(DailyTheme.cobalt)
                    Text(connection.reason).font(.subheadline)
                }
            }
            ForEach(day.helpful, id: \.self) { action in
                Label(action, systemImage: "leaf").font(.subheadline).foregroundStyle(.teal)
            }
        }.padding(18).dailyGlass(cornerRadius: 24).accessibilityIdentifier("tour-emotion-reflection")
    }
}
