import SwiftUI
import DailyCore

struct AgendaDayScreen: View {
    let date: String
    let items: [AgendaOccurrence]
    let agendaError: Bool
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEmotion: EmotionEpisodeSelection?
    private var draftText: String? {
        guard let draft = model.drafts[date]?.text, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return draft
    }
    private var text: String { draftText ?? model.journal(date: date)?.rawText ?? "" }
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var emotionDay: EmotionDay? { model.emotionDays.first { $0.date == date } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if hasText {
                    HStack {
                        Text("Günlük").font(.headline)
                        if draftText != nil {
                            Text("Cihazdaki taslak").font(.caption).foregroundStyle(DailyTheme.cobalt)
                        } else if model.isJournalSynced(date: date) {
                            Text("Firebase’e eşitlendi").font(.caption).foregroundStyle(DailyTheme.cobalt)
                        } else if model.isJournalSavedOnDevice(date: date) {
                            Text("Bu cihazda kayıtlı").font(.caption).foregroundStyle(DailyTheme.cobalt)
                        }
                    }
                    Text(text).lineSpacing(5).textSelection(.enabled)
                        .accessibilityIdentifier("agenda-day-journal")
                    Button("Günlüğü aç") { model.showJournal(date: date); dismiss() }
                        .buttonStyle(DailySecondaryButtonStyle())
                        .accessibilityIdentifier("agenda-day-open-journal")
                }
                if model.unreadableDraftDates.contains(date) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Taslak okunamadı", systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold))
                        Button("Taslağı yeniden oku") { model.open(date: date, retry: true) }
                            .buttonStyle(DailySecondaryButtonStyle())
                    }
                }
                ManagedAgendaSection(date: date, items: items, error: agendaError)
                if model.journal(date: date)?.awaitsDayReflectionQuestions == true {
                    NavigationLink {
                        JournalQuestionsScreen(date: date)
                    } label: {
                        Label("Sorulara geç", systemImage: "bubble.left.and.bubble.right")
                    }.buttonStyle(DailySecondaryButtonStyle())
                } else if let emotionDay {
                    EmotionReflectionCard(day: emotionDay, title: "Günün yorumu")
                        .accessibilityIdentifier("agenda-day-reflection")
                    if !emotionDay.observations.isEmpty {
                        DisclosureGroup("Duygu geçişlerini gör") {
                            EmotionDayFlow(day: emotionDay) { episode in
                                selectedEmotion = EmotionEpisodeSelection(day: emotionDay, episode: episode)
                            }.padding(.top, 12)
                        }
                    }
                } else if hasText {
                    Text("Bu günün yorumu analiz tamamlandığında burada görünür.")
                        .font(.footnote).foregroundStyle(DailyTheme.muted)
                }
            }.padding(20)
        }.navigationTitle(date).navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("agenda-day-detail")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
            .task(id: date) { model.open(date: date) }
            .onChange(of: model.navigation.journalRoute) { _, _ in dismiss() }
            .onChange(of: model.analysisMapTour?.id) { _, id in if id != nil { dismiss() } }
            .sheet(item: $selectedEmotion) { selection in
                NavigationStack { EmotionEpisodeDetail(day: selection.day, episode: selection.episode) }
                    .presentationDetents([.medium, .large])
            }
    }
}
