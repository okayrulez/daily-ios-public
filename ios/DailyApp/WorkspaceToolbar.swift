import SwiftUI
import DailyCore

struct WorkspaceToolbar: ViewModifier {
    var date: String?
    var allowsAnalysis = false
    var questionAnalysis = false
    @EnvironmentObject private var model: WorkspaceModel
    private var questionCount: Int { model.pendingQuestionCount }
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background { DailyCanvas(writingEnergy: allowsAnalysis ? writingProgress : 0) { Color.clear } }
            .toolbarBackground(.hidden, for: .navigationBar).toolbar {
            if allowsAnalysis || questionAnalysis {
                ToolbarItem(id: "daily-analysis", placement: .principal) {
                    DailyAnalysisLogo(date: date ?? WorkspaceModel.today, questionAnalysis: questionAnalysis)

                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.notificationsSheet = true } label: {
                    Image(systemName: questionCount > 0 ? "bell.badge" : "bell").foregroundStyle(DailyTheme.cobalt)
                }.accessibilityLabel("Bildirimler, \(questionCount) soru yanıt bekliyor")
                    .accessibilityIdentifier("workspace-notifications")

            }
        }
    }
    private var writingProgress: Double {
        let count = DailyWritingProgress.characterCount(in: model.text(date: date ?? WorkspaceModel.today), upTo: 1_200)
        // The ambient light can advance in steps without restarting its animation on each keystroke.
        return Double(count / 24) / 50
    }
}

extension View { func workspaceToolbar(date: String? = nil, allowsAnalysis: Bool = false, questionAnalysis: Bool = false) -> some View { modifier(WorkspaceToolbar(date: date, allowsAnalysis: allowsAnalysis, questionAnalysis: questionAnalysis)) } }

private struct DailyAnalysisLogo: View {
    let date: String
    var questionAnalysis = false
    @EnvironmentObject private var model: WorkspaceModel
    @ObservedObject private var connection = ChatGPTConnection.shared
    @State private var statusOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var questions: [JournalQuestion] { (model.journal(date: date)?.questions ?? []).filter { !questionAnalysis || !$0.isFunctional } }
    private var answeredCount: Int {
        questions.filter { question in
            guard let pending = model.pendingAnswer(date: date, id: question.id) else { return question.isAnswered }
            switch pending {
            case .text(let text): return !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .boolean(let value): return value != nil
            }
        }.count
    }
    private var answerProgress: Double {
        guard !questions.isEmpty else { return 0 }
        if questionAnalysis && !canStart { return 0 }
        return Double(answeredCount) / Double(questions.count)
    }

    private var writingProgress: Double {
        guard !questionAnalysis else { return 0 }
        return Double(DailyWritingProgress.characterCount(in: model.text(date: date), upTo: 1_200)) / 1_200
    }
    private var canStart: Bool { questionAnalysis ? model.canStartQuestionAnalysis(date:date) : model.canStartDailyAnalysis(date:date) }
    private var hasReply: Bool {
        guard let journal = model.journal(date: date) else { return false }
        return !journal.analyses.isEmpty || journal.payload.object?["daily_task"]?.object != nil
    }
    private var emphasis: Double { model.phoneAnalysisBusy ? 1 : questionAnalysis ? answerProgress : max(writingProgress, answerProgress) }
    private var logoScale: CGFloat { CGFloat(1 + emphasis * 0.12) }

    var body: some View {
        Button {
            if !model.phoneAnalysisBusy && canStart { model.startPhoneAnalysis(date: date, requiresNewInput:true) }
            statusOpen = true
        } label: {
            logo
                .scaleEffect(logoScale)
                .frame(width:108,height:44)
                .background {
                    Circle().fill(DailyTheme.energy.opacity(emphasis * 0.28))
                        .frame(width: 48, height: 48).blur(radius: 7)
                }
                .shadow(color: DailyTheme.energy.opacity(emphasis * 0.65), radius: CGFloat(3 + emphasis * 9))
                .shadow(color: DailyTheme.cobalt.opacity(emphasis * 0.3), radius: CGFloat(emphasis * 5))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: answeredCount)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: writingProgress)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: answerProgress)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.phoneAnalysisBusy)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.phoneAnalysisBusy && (!(canStart || (questionAnalysis && hasReply)) || !model.canEdit || connection.busy || model.phoneMemoryBusy || model.mapLinkBusy || model.busyDates.contains(date)))
        .accessibilityLabel(model.phoneAnalysisBusy ? "Analizin durumunu göster" : "Daily butonu")
        .accessibilityValue(model.phoneAnalysisBusy ? "Analiz çalışıyor" : "\(questions.count) sorunun \(answeredCount) tanesi yanıtlandı")
        .accessibilityHint(canStart ? "Yeni yazını ve yanıtlarını kaydedip analizi başlatır." : questionAnalysis && hasReply ? "Kaydedilmiş yanıtını açar." : "Yeni yazı veya yanıt eklediğinde etkinleşir.")
        .accessibilityIdentifier("daily-analysis-play")
        .sheet(isPresented: $statusOpen) {
            AnalysisStatusSheet(date: model.phoneAnalysisBusy ? (model.phoneAnalysisDate ?? date) : date)
        }
    }

    private var logo: some View {
        DailyFormingMark(progress: emphasis, isRunning: model.phoneAnalysisBusy, reduceMotion: reduceMotion)
            .frame(width:86,height:40)
            .accessibilityHidden(true)
    }
}

/// The same mark resolves from a dispersed light silhouette as the entry grows.
/// Visual progress is independent of request eligibility; saved writing stays solid.
private struct DailyFormingMark: View {
    var progress: Double
    let isRunning: Bool
    let reduceMotion: Bool
    private var clarity: Double { min(1, max(0, progress)) }
    var body: some View {
        ZStack {
            if !reduceMotion {
                DailyFlowMark().blur(radius: 3.5)
                    .offset(x: CGFloat(-7 * (1 - clarity)), y: CGFloat(2 * (1 - clarity)))
                    .opacity(0.22 * (1 - clarity))
                DailyFlowMark().blur(radius: 2)
                    .offset(x: CGFloat(6 * (1 - clarity)), y: CGFloat(-2 * (1 - clarity)))
                    .opacity(0.18 * (1 - clarity))
            }
            DailyFlowMark(isRunning: isRunning, showsControl: true)
                .blur(radius: reduceMotion ? 0 : 2.8 * (1 - clarity))
                .opacity(0.32 + 0.68 * clarity)
            // Keep the action legible even while the surrounding silhouette is abstract.
            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                .font(.system(size: isRunning ? 15 : 16, weight: .bold))
                .foregroundStyle(DailyTheme.navy.opacity(0.72 * (1 - clarity)))
                .offset(x: -9, y: 0)
        }
    }
}

/// Transparent Akış mark: the control lives in the open center, not on the ribbon.
/// Drawing it as paths keeps it sharp at toolbar sizes without a white image tile.
struct DailyFlowMark: View {
    var isRunning = false
    var showsControl = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                FlowRibbonShape().fill(LinearGradient(
                    colors: [Color(red: 0.04, green: 0.13, blue: 0.29), Color(red: 0.10, green: 0.28, blue: 0.47)],
                    startPoint: .bottomLeading, endPoint: .topTrailing))
                FlowLightShape().fill(LinearGradient(
                    colors: [.cyan, Color(red: 0.24, green: 1, blue: 0.94)],
                    startPoint: .leading, endPoint: .trailing))
                    .shadow(color: .cyan.opacity(0.7), radius: 3)
                if showsControl {
                    // Both states share a larger box, left of the cyan edges.
                    ZStack {
                        Image(systemName: "play.fill").font(.system(size: 16, weight: .bold))
                            .offset(x: 1).opacity(isRunning ? 0 : 1)
                        RoundedRectangle(cornerRadius: 2.5).frame(width: 15, height: 15)
                            .opacity(isRunning ? 1 : 0)
                    }
                    .foregroundStyle(Color(red: 0.04, green: 0.13, blue: 0.29))
                    .frame(width: 18, height: 18)
                    .position(x: width * 0.39, y: height * 0.5)
                }
            }
        }
    }
}

private struct FlowRibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 44, y: 0))
        path.addCurve(to: CGPoint(x: 61, y: 8), control1: CGPoint(x: 52, y: 0), control2: CGPoint(x: 55, y: 1))
        path.addLine(to: CGPoint(x: 72, y: 19))
        path.addCurve(to: CGPoint(x: 86, y: 23), control1: CGPoint(x: 76, y: 22), control2: CGPoint(x: 81, y: 22))
        path.addQuadCurve(to: CGPoint(x: 90, y: 25), control: CGPoint(x: 89, y: 23))
        path.addLine(to: CGPoint(x: 97, y: 30))
        path.addQuadCurve(to: CGPoint(x: 97, y: 34), control: CGPoint(x: 100, y: 32))
        path.addLine(to: CGPoint(x: 90, y: 39))
        path.addQuadCurve(to: CGPoint(x: 86, y: 41), control: CGPoint(x: 89, y: 41))
        path.addCurve(to: CGPoint(x: 72, y: 45), control1: CGPoint(x: 81, y: 42), control2: CGPoint(x: 76, y: 42))
        path.addLine(to: CGPoint(x: 61, y: 56))
        path.addCurve(to: CGPoint(x: 44, y: 64), control1: CGPoint(x: 55, y: 63), control2: CGPoint(x: 52, y: 64))
        path.addLine(to: CGPoint(x: 0, y: 64))
        path.addLine(to: CGPoint(x: 0, y: 60))
        path.addCurve(to: CGPoint(x: 13, y: 48), control1: CGPoint(x: 0, y: 53), control2: CGPoint(x: 5, y: 48))
        path.addLine(to: CGPoint(x: 43, y: 48))
        path.addCurve(to: CGPoint(x: 59, y: 42), control1: CGPoint(x: 51, y: 48), control2: CGPoint(x: 54, y: 48))
        path.addLine(to: CGPoint(x: 70, y: 32))
        path.addLine(to: CGPoint(x: 59, y: 22))
        path.addCurve(to: CGPoint(x: 43, y: 16), control1: CGPoint(x: 54, y: 16), control2: CGPoint(x: 51, y: 16))
        path.addLine(to: CGPoint(x: 13, y: 16))
        path.addCurve(to: CGPoint(x: 0, y: 4), control1: CGPoint(x: 5, y: 16), control2: CGPoint(x: 0, y: 11))
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width / 100, y: rect.height / 64))
    }
}

private struct FlowLightShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for lower in [false, true] {
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: lower ? 64 - y : y) }
            path.move(to: point(43, 16))
            path.addLine(to: point(57, 17))
            path.addQuadCurve(to: point(64, 20), control: point(61, 17))
            path.addLine(to: point(77, 32))
            path.addLine(to: point(68, 31))
            path.addQuadCurve(to: point(61, 28), control: point(64, 31))
            path.addLine(to: point(53, 20))
            path.addQuadCurve(to: point(43, 16), control: point(49, 16))
            path.closeSubpath()
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 100, y: rect.height / 64))
    }
}

struct ConnectionStatusScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DailySectionHeading(eyebrow: "DailyX · Telefon · Firebase", title: "Bağlantın", detail: model.email)
                Label(model.cloudConnected ? "Kendi Firebase projen bağlı" : "Kayıtların bu cihazda", systemImage: model.cloudConnected ? "checkmark.icloud" : "iphone")
                    .font(.headline).foregroundStyle(DailyTheme.mint)
                if model.cloudConnected {
                    Text(model.firebaseProjectID).font(.caption).textSelection(.enabled)
                    Text("Bekleyen eşitleme: \(model.pendingCloudWrites)").font(.caption)
                    Button("Şimdi eşitle") { Task { await model.syncCloudNow() } }.buttonStyle(DailySecondaryButtonStyle()).disabled(model.cloudBusy)
                }
                if !model.cloudSyncNotice.isEmpty { Text(model.cloudSyncNotice).font(.footnote).foregroundStyle(DailyTheme.orange) }
                if !model.cloudNotice.isEmpty { Text(model.cloudNotice).font(.footnote) }
                NavigationLink { PersonalSetupScreen(firebaseOnly: true) } label: { Label("Eşitleme ayarları", systemImage: "arrow.triangle.2.circlepath") }

            }.padding(20)
        }.navigationTitle("Bağlantı").navigationBarTitleDisplayMode(.inline)
    }
}

struct NotificationCenterScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    var body: some View {
        List {
            Section("Yanıtını bekleyen sorular") {
                let journals = model.dates.compactMap { model.journal(date: $0) }.filter { !$0.pendingQuestions.isEmpty }
                if journals.isEmpty { Text("Şimdilik yeni soru yok.").foregroundStyle(DailyTheme.muted) }
                ForEach(journals, id: \.date) { journal in
                    NavigationLink { JournalQuestionsScreen(date: journal.date) } label: {
                        Label("\(journal.date) · \(journal.pendingQuestions.count) soru", systemImage: "questionmark.bubble")
                    }
                }
            }
            Section {
                NavigationLink("Takip bildirimleri") { CompanionInboxScreen() }
            }
        }.navigationTitle("Bildirimler").navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.refreshFromFirebase() }
    }
}
