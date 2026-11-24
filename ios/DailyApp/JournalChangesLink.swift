import SwiftUI
import DailyCore

/// The result has one contextual entry point, with motion confined to its lettering.
struct JournalChangesLink: View {
    let date: String
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    private let blue = Color(red: 0.02, green: 0.34, blue: 0.75)
    private let red = Color(red: 0.80, green: 0.16, blue: 0.25)

    var body: some View {
        NavigationLink { WorkspaceChangesScreen(date: date) } label: {
            TimelineView(.animation(minimumInterval: 1 / 24,
                paused: reduceMotion || model.navigation.tab != .today || scenePhase != .active)) { context in
                let travel = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
                HStack(spacing: 9) {
                    Text("Ne değiştiğini gör").font(.headline)
                    Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(LinearGradient(colors: [blue, blue, red, red, blue],
                    startPoint: UnitPoint(x: travel * 2 - 1, y: 0.5),
                    endPoint: UnitPoint(x: travel * 2, y: 0.5)))
            }
            .journalActionCard(accent: DailyTheme.coral)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(reduceMotion || appeared ? 1 : 0)
        .offset(y: reduceMotion || appeared ? 0 : 9)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) { appeared = true } }
        .accessibilityLabel("Ne değiştiğini gör")
        .accessibilityHint("Bu günün kaydedilmiş analiz değişikliklerini açar")
        .accessibilityIdentifier("journal-view-changes")
    }
}

extension View {
    func journalActionCard(accent: Color) -> some View {
        self
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 54)
            .dailyGlass(cornerRadius: 16, accent: accent)
    }
}

struct JournalReflectionButton: View {
    let date: String
    let reflection: String
    var advice: [String] = []
    var previousReflection: String? = nil
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presented = false
    @State private var visible = false

    var body: some View {
        Button { presented = true } label: {
            TimelineView(.animation(minimumInterval: 1 / 24,
                paused: reduceMotion || !visible || presented || scenePhase != .active)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
                Label("Günün yorumunu gör", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(reduceMotion ? AnyShapeStyle(DailyTheme.cobalt) : AnyShapeStyle(
                        LinearGradient(colors: [DailyTheme.cobalt, Color(red: 0.03, green: 0.42, blue: 0.65), DailyTheme.cobalt],
                            startPoint: UnitPoint(x: phase * 1.6 - 0.6, y: 0.5),
                            endPoint: UnitPoint(x: phase * 1.6, y: 0.5))))
            }
            .journalActionCard(accent: DailyTheme.energy)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("journal-view-reflection")
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .sheet(isPresented: $presented) {
            JournalReflectionSheet(date: date, reflection: reflection, advice: advice, previousReflection: previousReflection)
        }
    }
}

private struct JournalReflectionContent: View {
    let reflection: String
    let advice: [String]

    var body: some View {
        Text(reflection).lineSpacing(5).textSelection(.enabled)
            .accessibilityIdentifier("journal-reflection-text")
        if !advice.isEmpty {
            Text("Tavsiyeler").font(.headline)
            ForEach(Array(advice.enumerated()), id: \.offset) { _, item in
                Text(item).lineSpacing(4).textSelection(.enabled)
            }
        }
    }
}

struct JournalReflectionSheet: View {
    let date: String
    let reflection: String
    let advice: [String]
    var previousReflection: String? = nil

    var body: some View {
        NavigationStack {
            JournalReflectionPage(date: date, reflection: reflection, advice: advice, previousReflection: previousReflection)
        }
    }
}

struct JournalReflectionPage: View {
    @EnvironmentObject private var model: WorkspaceModel
    let date: String
    let reflection: String
    let advice: [String]
    var previousReflection: String? = nil
    @Environment(\.dismiss) private var dismiss

    private var publishedHistory: [JournalAnalysis] {
        guard let journal = model.journal(date: date) else { return [] }
        let ids = Set(journal.payload.object?["previous_day_reflection_ids"]?.array?.compactMap(\.string) ?? [])
        return journal.analyses.filter { ids.contains($0.id) }.sorted { $0.version > $1.version }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                JournalReflectionContent(reflection: reflection, advice: advice)
                let earlier = publishedHistory
                if !earlier.isEmpty {
                    DisclosureGroup("Önceki değerlendirmeler") {
                        ForEach(earlier) { item in
                            Text(item.reflection).lineSpacing(5).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }
                    }
                } else if let previousReflection {
                    DisclosureGroup("Önceki yorum") {
                        Text(previousReflection).lineSpacing(5).textSelection(.enabled).padding(.top, 8)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
        }
        .background(DailyTheme.canvas)
        .navigationTitle("Yorum ve tavsiyeler")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } } }
    }
}

struct CompletedDayReflection: Identifiable {
    let id: String
    let date: String
    let reflection: String
    let advice: [String]
    var previousReflection: String? = nil
}

/// A fallback when the analysis status sheet has already been closed.
struct AutomaticDayReflectionSheet: ViewModifier {
    let enabled: Bool
    var date: String? = nil
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var reflection: CompletedDayReflection?
    @State private var presentedID: String?

    private var readyID: String? {
        guard enabled, scenePhase == .active, model.analysisMapTour == nil,
              model.analysisStatusHosts.isEmpty, !model.dayReflectionIsOpen,
              let pending = model.pendingDayReflection, date == nil || date == pending.date else { return nil }
        return pending.id
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: readyID, initial: true) { _, id in
                guard id != nil, let next = model.takePendingDayReflection(date: date) else { return }
                presentedID = next.id
                reflection = next
            }
            .onChange(of: model.companionScope) { _, _ in reflection = nil }
            .sheet(item: $reflection, onDismiss: {
                if let presentedID { model.closeDayReflection(id: presentedID) }
                presentedID = nil
            }) { item in
                JournalReflectionSheet(date: item.date, reflection: item.reflection, advice: item.advice,
                    previousReflection: item.previousReflection)
            }
    }
}

struct JournalAnalysisResultButton: View {
    let date: String
    var changes: AnalysisChanges? = nil
    @EnvironmentObject private var model: WorkspaceModel

    var body: some View {
        let receipt = model.changeReceipts.first { $0.date == date }
        let journal = model.journal(date: date)
        let counts = changes ?? receipt?.changes
        let task = journal?.payload.object?["daily_task"]?.object
        let report = task?["reply"]?.string
            ?? journal?.payload.object?["map_link_session"]?.object?["reflection"]?.string
        let reminders = journal?.payload.object?["reminder_results"]?.array?.compactMap(\.string) ?? []
        if counts != nil || report != nil || !reminders.isEmpty {
            JournalDetailButton(title: "Analizin sonucunu gör", heading: "Analizin sonucu",
                                symbol: "doc.text", identifier: "journal-view-analysis-result") {
                if let report, !report.isEmpty { Text(report).lineSpacing(5).textSelection(.enabled) }
                if let counts, receipt?.undone != true {
                    Label("\(counts.newNotes) yeni not · \(counts.newLinks) yeni bağlantı", systemImage: "point.3.connected.trianglepath.dotted")
                    if counts.updatedNotes > 0 { Text("\(counts.updatedNotes) not güncellendi.") }
                }
                if report == nil && receipt?.undone != true {
                    ForEach(Array((receipt?.agenda ?? []).enumerated()), id: \.offset) { _, item in
                        Label(item, systemImage: "calendar")
                    }
                }
                ForEach(Array(reminders.enumerated()), id: \.offset) { _, item in
                    Label(item, systemImage: "bell")
                }
                if receipt?.undone == true { Text("Son işlem geri alındı") }
            }
        }
    }
}

private struct JournalDetailButton<Content: View>: View {
    let title: LocalizedStringKey
    let heading: LocalizedStringKey
    let symbol: String
    let identifier: String
    @ViewBuilder let content: () -> Content
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Label(title, systemImage: symbol)
                .font(.headline).foregroundStyle(DailyTheme.cobalt)
                .journalActionCard(accent: DailyTheme.energy)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .sheet(isPresented: $presented) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16, content: content)
                        .frame(maxWidth: .infinity, alignment: .leading).dailyCard().padding(20)
                }
                .background(DailyTheme.canvas)
                .navigationTitle(heading)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Kapat") { presented = false }
                    }
                }
            }
        }
    }
}
