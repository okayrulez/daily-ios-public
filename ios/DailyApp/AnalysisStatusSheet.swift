import SwiftUI

struct AnalysisStatusSheet: View {
    let date: String
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var hostID = UUID()
    @State private var reflection: CompletedDayReflection?

    private var readyReflectionID: String? {
        guard scenePhase == .active, reflection == nil, model.analysisMapTour == nil,
              model.pendingDayReflection?.date == date else { return nil }
        return model.pendingDayReflection?.id
    }

    var body: some View {
        NavigationStack {
            if let reflection {
                JournalReflectionPage(date: reflection.date, reflection: reflection.reflection, advice: reflection.advice,
                    previousReflection: reflection.previousReflection)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        DailySectionHeading(eyebrow: model.phoneAnalysisDate ?? date, title: "Analizin",
                            detail: "Yazın ve yanıtların üzerinden soruların ve haritaların güncellenir.")
                        JournalAnalysisControl(date: date)
                    }.padding(24)
                }
                .background(DailyTheme.canvas)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() } }
                }
            }
        }
        .onAppear { model.setAnalysisStatusHost(hostID, visible: true) }
        .onDisappear {
            if let reflection { model.closeDayReflection(id: reflection.id) }
            model.setAnalysisStatusHost(hostID, visible: false)
        }
        .onChange(of: readyReflectionID, initial: true) { _, id in
            if id != nil { reflection = model.takePendingDayReflection(date: date) }
        }
        .onChange(of: model.companionScope) { _, _ in
            if reflection != nil { dismiss() }
        }
        .onChange(of: model.analysisMapTour?.id) { _, id in
            if id != nil { dismiss() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct QuestionsAnalysisButton: View {
    let date: String
    @EnvironmentObject private var model: WorkspaceModel
    @ObservedObject private var connection = ChatGPTConnection.shared
    @State private var statusOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if !model.phoneAnalysisBusy { model.startPhoneAnalysis(date: date) }
                statusOpen = true
            } label: {
                Label(model.phoneAnalysisBusy ? "Analizin durumunu göster" : "Analize başla",
                      systemImage: model.phoneAnalysisBusy ? "hourglass" : "play.fill")
            }
            .buttonStyle(DailyPrimaryButtonStyle())
            .disabled(!model.phoneAnalysisBusy && (!model.canEdit || connection.busy || model.busyDates.contains(date)))
            .accessibilityIdentifier("questions-start-analysis")
            Text("Bu günün yazısı ve cevapladığın sorular birlikte kaydedilip analiz edilir.")
                .font(.footnote).foregroundStyle(DailyTheme.muted)
        }
        .sheet(isPresented: $statusOpen) { AnalysisStatusSheet(date: date) }
    }
}
