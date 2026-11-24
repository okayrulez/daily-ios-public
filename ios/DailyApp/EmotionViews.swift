import SwiftUI
import DailyCore

enum EmotionStyle {
    static func connectionReason(_ connection: EmotionConnection) -> String {
        guard let context = connection.automaticContext else { return connection.reason }
        return String(format: DailyLanguage.saved.text("%@ bağlamında başka bir kaynak gün. Hislerin ve sonuçların aynı olduğunu varsaymadan karşılaştır."), context)
    }
    static func sequenceLabel(_ pattern: EmotionPattern) -> String {
        guard let day = pattern.matching.first else { return pattern.sequence }
        let observations = day.observations.filter { EmotionPatterns.context(of: $0) == pattern.id && !$0.isEnergy }
        let grouped = Dictionary(grouping: observations, by: \.sequence)
        return grouped.keys.sorted().map { index in
            Set((grouped[index] ?? []).map { DailyLanguage.saved.text($0.label) }).sorted().joined(separator: " + ")
        }.joined(separator: " → ")
    }
    static func color(_ key: String) -> Color {
        switch EmotionDefinition.canonical(key) {
        case "joy", "hope": .orange
        case "calm", "relief": .teal
        case "excitement", "pride": .purple
        case "anxiety", "tension": DailyTheme.coral
        case "anger": .red
        case "sadness", "loneliness": .indigo
        case "fatigue": .gray
        default: DailyTheme.cobalt
        }
    }
    static func emoji(_ key: String, preferences: String) -> String {
        let custom = preferences.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        return custom?[EmotionDefinition.canonical(key)] ?? EmotionDefinition.find(key)?.emoji ?? "🔹"
    }
}

struct EmotionBadges: View {
    let day: EmotionDay
    var compact = false
    @AppStorage("daily.emotion.emojis") private var preferences = "{}"
    var body: some View {
        HStack(spacing: compact ? 1 : 8) {
            ForEach(Array(day.keys.prefix(compact ? 2 : day.keys.count)), id: \.self) { key in
                let label = day.observations.first { $0.key == key }?.label ?? EmotionDefinition.find(key)?.title ?? key
                if compact {
                    Text(EmotionStyle.emoji(key, preferences: preferences))
                        .font(.system(size: 14)).accessibilityLabel(label)
                } else {
                    Label(LocalizedStringKey(label), systemImage: day.calendarKeys != nil || day.observations.contains(where: { $0.key == key && $0.userSelected }) ? "person.fill" : "sparkles")
                        .font(.caption).foregroundStyle(EmotionStyle.color(key))
                        .padding(8).background(EmotionStyle.color(key).opacity(0.08), in: Capsule())
                }
            }
        }
    }
}

struct EmotionReflectionCard: View {
    let day: EmotionDay
    var title = "Yansıma"
    @EnvironmentObject private var model: WorkspaceModel
    @State private var correcting = false
    @Environment(\.dismiss) private var dismiss
    private var priorHelpful: [EmotionHelpfulAction] {
        let current = model.emotionDays.first { $0.date == day.date } ?? day
        let dates = Set(current.connections.map(\.date))
        return model.emotionDays.filter { dates.contains($0.date) }.flatMap(\.helpfulEvidence)
    }
    var body: some View {
        let day = model.emotionDays.first { $0.date == self.day.date } ?? self.day
        VStack(alignment: .leading, spacing: 14) {
            if !day.observations.isEmpty || !day.originalObservations.isEmpty {
                GuidedTourTip(kind: .emotion)
            }
            HStack {
                Label(LocalizedStringKey(day.reflection.isEmpty ? "Duygu izleri" : title), systemImage: "sparkles").font(.headline)
                Spacer()
                Button { correcting = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                    .accessibilityLabel("Bu günün duygularını düzelt")
            }
            if !day.reflection.isEmpty {
                Text(day.reflection).lineSpacing(5).textSelection(.enabled)
            }
            if !day.keys.isEmpty {
                ScrollView(.horizontal) { EmotionBadges(day: day) }.scrollIndicators(.hidden)
                Text(LocalizedStringKey(day.observations.contains(where: \.userSelected) && day.observations.contains(where: { !$0.userSelected })
                    ? "Senin seçimlerin ve AI yorumları" : day.userSelected || day.calendarKeys != nil ? "Senin seçimin" : "Günlükten yorumlandı"))
                    .font(.caption2).foregroundStyle(DailyTheme.muted)
            }
            ForEach(day.connections) { connection in
                VStack(alignment: .leading, spacing: 4) {
                    Button(connection.date) { dismiss(); model.showJournal(date: connection.date) }
                        .font(.subheadline.weight(.semibold))
                    Text(EmotionStyle.connectionReason(connection)).font(.subheadline).foregroundStyle(DailyTheme.muted)
                }
            }
            ForEach(day.helpful, id: \.self) { action in
                Label(action, systemImage: "leaf").font(.subheadline).foregroundStyle(.teal)
            }
            if !priorHelpful.isEmpty {
                Label("Daha önce iyi geldiğini söylediklerin", systemImage: "leaf").font(.subheadline.weight(.semibold))
                ForEach(priorHelpful) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.action).font(.subheadline).foregroundStyle(.teal)
                        Text(item.quote).font(.caption).foregroundStyle(DailyTheme.muted)
                        Button(item.date) { dismiss(); model.showJournal(date: item.date) }.font(.caption)
                    }
                }
            }
        }.padding(18).dailyGlass(cornerRadius: 24, accent: DailyTheme.cobalt)
            .sheet(isPresented: $correcting) {
                NavigationStack { EmotionCorrectionScreen(day: day) }
                    .presentationDetents([.medium, .large])
            }
    }
}

struct EmotionCorrectionScreen: View {
    let day: EmotionDay
    var observation: EmotionObservation? = nil
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var observationID = ""
    @State private var saving = false
    @State private var error = ""
    private var originals: [EmotionObservation] { day.originalObservations.isEmpty ? day.observations : day.originalObservations }
    private var original: EmotionObservation? { originals.first { $0.id == observationID } }
    private var choices: [String] { Array(Set(EmotionDefinition.defaults.map(\.id) + day.observations.map(\.key))).sorted() }
    var body: some View {
        Form {
            if observation == nil {
                Section("Düzelteceğin gözlem") {
                    Picker("Gözlem", selection: $observationID) {
                        ForEach(originals) { item in Text(item.label + " · " + item.event).tag(item.id) }
                    }
                }
            }
            if let original {
                Section("Günlükteki ifade") {
                    Text(original.quote).textSelection(.enabled)
                    Text("AI'ın ilk yorumu: \(original.label)").font(.caption).foregroundStyle(DailyTheme.muted)
                }
            }
            Section("Bu anda nasıl hissettin?") {
                ForEach(choices, id: \.self) { key in
                    Button {
                        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
                    } label: {
                        HStack {
                            Text(LocalizedStringKey(EmotionDefinition.find(key)?.title ?? originals.first(where: { $0.key == key })?.label ?? key)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selected.contains(key) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
            Section {
                Text("Yalnız bu gözlem değişir. Diğer olaylar ve zaman sırası korunur. Boş seçim bu gözlemin işaretini kaldırır.").font(.footnote)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Button("Seçimimi kaydet") {
                    guard let original else { return }
                    Task {
                        saving = true
                        if await model.saveEmotionCorrection(date: day.date, observation: original, choices: selected.sorted()) { dismiss() }
                        else { error = model.experienceNotice }
                        saving = false
                    }
                }.disabled(saving || !model.canEdit || original == nil || model.isDirty(date: day.date)
                    || model.phoneAnalysisBusy || model.phoneMemoryBusy || model.mapLinkBusy || model.experienceBusy)
            }
        }.navigationTitle("Duygu gözlemini düzelt")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } } }
            .onAppear {
                let proposed = observation?.correctionID
                observationID = originals.first(where: { $0.id == proposed })?.id ?? originals.first?.id ?? ""
                loadSelection()
            }
            .onChange(of: observationID) { _, _ in loadSelection() }
            .onChange(of: model.analysisMapTour?.id) { _, id in if id != nil { dismiss() } }
    }
    private func loadSelection() {
        selected = Set(day.observations.filter { $0.correctionID == observationID }.map(\.key))
    }
}

struct EmotionSettingsScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @AppStorage("daily.emotion.emojis") private var preferences = "{}"
    private var definitions: [EmotionDefinition] { EmotionDefinition.defaults }
    private var extra: [EmotionObservation] {
        var seen = Set(definitions.map(\.id))
        return model.emotionDays.flatMap(\.observations).filter { seen.insert($0.key).inserted }
    }
    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { EmotionStyle.emoji(key, preferences: preferences) }, set: { value in
            guard value.count == 1, value.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) else { return }
            var entries = preferences.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            entries[key] = value
            if let data = try? JSONEncoder().encode(entries), let text = String(data: data, encoding: .utf8) { preferences = text }
        })
    }
    var body: some View {
        Form {
            Section {
                Text("Analiz sonunda duyguların ajandaya eklenir. Buradaki simge seçimin kaydedilmiş günlere de uygulanır.")
            }
            Section("Duygular ve emojiler") {
                ForEach(definitions) { definition in
                    row(key: definition.id, title: definition.title, meaning: definition.meaning)
                }
            }
            if !extra.isEmpty {
                Section("Günlüklerinde bulunan yeni duygular") {
                    ForEach(extra) { observation in
                        row(key: observation.key, title: observation.label, meaning: observation.definition)
                    }
                }
            }
            Section("Geçmiş günlükler") {
                Text("Kaydedilmiş analizlerin otomatik gösterilir. Ayrıntılı duygu geçişleri eksik günleri ChatGPT hesabınla değerlendirebilirsin. İlerleme her günün ardından kaydedilir.")
                    .font(.footnote)
                if model.emotionBackfillRunning {
                    ProgressView(model.emotionBackfillStatus)
                    Button("Geçmiş analizini durdur") { model.cancelPhoneAnalysis() }
                } else {
                    Button("Eksik duygu geçmişini değerlendir") { model.startEmotionBackfill() }
                        .disabled(model.phoneAnalysisBusy || model.phoneMemoryBusy)
                }
                if !model.emotionBackfillStatus.isEmpty {
                    Text(model.emotionBackfillStatus).font(.caption)
                }
            }
            Section { Button("Varsayılan emojileri kullan") { preferences = "{}" } }
        }.navigationTitle("Duygular ve emojiler")
    }
    private func row(key: String, title: String, meaning: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title))
                Text(LocalizedStringKey(meaning)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Emoji", text: binding(key)).multilineTextAlignment(.center)
                .frame(width: 50).font(.title2).accessibilityLabel("\(title) emojisi")
        }.padding(.vertical, 4)
    }
}
