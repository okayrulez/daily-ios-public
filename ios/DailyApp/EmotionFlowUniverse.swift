import SwiftUI
import DailyCore

/// A readable overview of the current day, with detailed evidence one tap away.
struct EmotionDaySummary: View {
    let day: EmotionDay
    var showsDisclosure = true
    var body: some View {
        let stages = day.chronologicalEmotionStages
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(day.date).font(.subheadline.weight(.semibold)).foregroundStyle(DailyTheme.muted)
                Spacer(minLength: 8)
                EmotionBadges(day: day, compact: true)
                if showsDisclosure { Image(systemName: "chevron.right").font(.caption).foregroundStyle(DailyTheme.cobalt) }
            }
            if !day.reflection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(day.reflection).font(.body).lineSpacing(4).lineLimit(3)
            }
            if !stages.isEmpty {
                Text(stages.map { stage in stage.map { DailyLanguage.saved.text($0.label) }.joined(separator: " + ") }.joined(separator: " → "))
                    .font(.subheadline.weight(.medium)).foregroundStyle(DailyTheme.cobalt).lineLimit(2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmotionEpisodeSelection: Identifiable {
    let day: EmotionDay
    let episode: EmotionEpisode
    var id: String { episode.id }
}

struct EmotionDayFlow: View {
    let day: EmotionDay
    let onSelect: (EmotionEpisode) -> Void
    @AppStorage("daily.emotion.emojis") private var preferences = "{}"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var episodes: [EmotionEpisode] { EmotionPatterns.episodes(for: day) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                if index > 0 {
                    let previous = episodes[index - 1]
                    let comparable = episode.orderKnown && previous.orderKnown && episode.orderGroup == previous.orderGroup
                    let follows = comparable && episode.sequence != previous.sequence
                    Label(LocalizedStringKey(follows ? "Sonrasında" : comparable ? "Aynı anda" : "Zaman sırası belirtilmedi"), systemImage: follows ? "arrow.down" : "ellipsis")
                        .font(.caption2).foregroundStyle(DailyTheme.muted).padding(.leading, 12)
                }
                Button { onSelect(episode) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Circle().fill(EmotionStyle.color(episode.observations.first?.key ?? ""))
                                .frame(width: 8, height: 8).padding(.top, 6)
                            Text(episode.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        ForEach(episode.emotions) { item in observationLabel(item) }
                        ForEach(episode.energy) { item in
                            HStack { Text("Enerji").font(.caption2).foregroundStyle(DailyTheme.muted); observationLabel(item) }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [EmotionStyle.color(episode.observations.first?.key ?? "").opacity(0.09), .white.opacity(0.9)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 18))
                        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(DailyTheme.cobalt.opacity(0.16), lineWidth: 0.8) }
                }
                    // Annotate the native Button. Creating a separate accessibility
                    // element here produces an Other wrapper around the real action.
                    .accessibilityLabel(Text(episode.title))
                    .accessibilityValue(accessibleObservations(episode))
                    .accessibilityIdentifier("emotion-event-" + episode.id)
                    .buttonStyle(.plain)
            }
            if episodes.isEmpty { Text("Bu günün duygu işaretlerini kaldırdın.").font(.caption).foregroundStyle(DailyTheme.muted) }
        }.accessibilityElement(children: .contain)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: day.observations)
    }
    private func accessibleObservations(_ episode: EmotionEpisode) -> Text {
        episode.observations.enumerated().reduce(Text("")) { result, pair in
            let item = pair.element
            var value = Text(LocalizedStringKey(item.label))
            if let intensity = item.intensity { value = value + Text(" · AI: \(intensity) / 5") }
            if item.userSelected { value = value + Text(" · ") + Text("Senin seçimin") }
            return result + Text(pair.offset == 0 ? "" : ", ") + value
        }
    }
    private func observationLabel(_ item: EmotionObservation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(EmotionStyle.emoji(item.key, preferences: preferences))
            Text(LocalizedStringKey(item.label)).font(.caption)
            if item.userSelected { Image(systemName: "person.fill").font(.caption2) }
            if let intensity = item.intensity { Text("AI: \(intensity) / 5").font(.caption2).foregroundStyle(DailyTheme.muted) }
        }.foregroundStyle(EmotionStyle.color(item.key))
    }
}

struct EmotionEpisodeDetail: View {
    let day: EmotionDay
    let episode: EmotionEpisode
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var correcting: EmotionObservation?
    private var currentDay: EmotionDay { model.emotionDays.first { $0.date == day.date } ?? day }
    private var currentEpisode: EmotionEpisode? { EmotionPatterns.episodes(for: currentDay).first { $0.id == episode.id } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(episode.title).font(.title3.weight(.semibold))
                ForEach(currentEpisode?.observations ?? []) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(LocalizedStringKey(item.label)).font(.headline).foregroundStyle(EmotionStyle.color(item.key))
                        if !item.conditions.isEmpty { Text(item.conditions.joined(separator: " · ")).font(.caption).foregroundStyle(DailyTheme.muted) }
                        if !item.quote.isEmpty { Text("“" + item.quote + "”").textSelection(.enabled) }
                        Text(LocalizedStringKey(item.userSelected ? "Senin seçimin" : "Günlükten yorumlandı")).font(.caption).foregroundStyle(DailyTheme.muted)
                        if let original = item.originalLabel, item.userSelected {
                            Text("AI'ın ilk yorumu: \(original)").font(.caption).foregroundStyle(DailyTheme.muted)
                        }
                        if item.intensity == nil { Text("Yoğunluk belirtilmedi").font(.caption).foregroundStyle(DailyTheme.muted) }
                        if !item.orderKnown { Text("Zaman sırası belirtilmedi").font(.caption).foregroundStyle(DailyTheme.muted) }
                        Button("Bu gözlemi düzelt") { correcting = item }.font(.subheadline)
                    }.padding(16).dailyGlass(cornerRadius: 20, accent: EmotionStyle.color(item.key))
                }
                if currentEpisode == nil { Text("Bu olayın duygu işaretleri kaldırıldı.").font(.subheadline) }
                ForEach(currentDay.helpfulEvidence) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(item.action, systemImage: "leaf").foregroundStyle(.teal)
                        Text(item.quote).font(.caption).foregroundStyle(DailyTheme.muted)
                    }
                }
                ForEach(currentDay.connections) { link in
                    VStack(alignment: .leading, spacing: 5) {
                        Button(link.date) { dismiss(); model.showJournal(date: link.date) }
                        Text(EmotionStyle.connectionReason(link)).font(.subheadline).foregroundStyle(DailyTheme.muted)
                    }
                }
            }.padding(20)
        }.background(DailyTheme.canvas).navigationTitle(day.date).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
            .sheet(item: $correcting) { item in NavigationStack { EmotionCorrectionScreen(day: currentDay, observation: item) } }
            .onChange(of: model.analysisMapTour?.id) { _, id in if id != nil { dismiss() } }
    }
}
