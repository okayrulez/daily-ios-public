import SwiftUI
import DailyCore

enum GuidedTourConnectionDestination: String, Identifiable {
    case firebase, chatGPT
    var id: String { rawValue }
}

@MainActor final class GuidedTourController: ObservableObject {
    private static let introductionKey = "daily-first-introduction-completed"

    @Published var active = false
    @Published var profileOpen = false
    @Published var connectionSetup: GuidedTourConnectionDestination?
    @Published private(set) var simulation = GuidedTourSimulation()
    @Published var exampleText = ""
    @Published private(set) var language = DailyLanguage.turkish
    var sampleText: String { language.text(GuidedTourExample.text) }
    var samplePrompt: String { language.text(GuidedTourExample.prompt) }
    var exampleGraph: MobileAtlas.Graph { GuidedTourExample.graph(language: language.rawValue) }
    @Published var analysisReady = false
    @Published private(set) var runID = UUID()
    let spotlight = TourSpotlightRegistry()

    var stage: GuidedTourSimulation.Stage { simulation.stage }
    var isMap: Bool { stage == .map || stage == .note }
    var target: String {
        switch stage {
        case .savedDay: "saved-day"
        case .writing: "writer"
        case .daily, .analysing: "daily"
        case .map: "map-node"
        case .note: "note"
        case .questions: "question"
        case .agenda: "agenda"
        case .emotionDay: "emotion-day"
        case .emotionFlow: "emotion-flow"
        case .export: "export"
        case .exportPreview: "export-preview"
        case .firebase: "firebase"
        case .account: "account"
        }
    }
    var title: String {
        let key = switch stage {
        case .savedDay: "Aynı güne geri dön."
        case .writing: "Örnek bir günlükle dene."
        case .daily: "Şimdi Daily logosuna dokun."
        case .analysing: "Örnek analiz çalışıyor."
        case .map: "Yeni bağlantıların oluştu."
        case .note: "Bir notun içini keşfet."
        case .questions: "Hatırlatmayı sen seç."
        case .agenda: "Planın ajandada."
        case .emotionDay: "Günün duyguları da burada."
        case .emotionFlow: "Duygularının akışını keşfet."
        case .export: "Hafızanı yanında taşı."
        case .exportPreview: "Önce dosyanı yükle, sonra görevini ver."
        case .firebase: "İstersen cihazlarını eşitle."
        case .account: "AI hesabın da senin."
        }
        return language.text(key)
    }
    var detail: String {
        let key = switch stage {
        case .savedDay: "Akşam notunu aynı güne eklemeyi dene. Sorular ekranında yazılı yanıtlarını Daily logosuyla birlikte gönder. Yorum hazır olunca açılır ve burada saklanır."
        case .writing: "Yüzmenin sana iyi geldiğini ve yeniden gitmek istediğini yazdığını düşün. Bu örnekle ilerleyelim."
        case .daily: "Gerçek günlükte bu logo yazını kaydeder ve analizi başlatır. Şimdi yüzme örneğinde dene."
        case .analysing: "Bu örnek AI kullanım hakkı harcamaz."
        case .map: "Kırmızı bağlar yeni eklenenleri gösterir. Notların çevresindeki renkler ilgili duyguları yansıtır. Yüzme notuna dokun."
        case .note: "Notun güncel içeriğini oku. Bağlı diğer notlara dokunarak aralarında gezebilirsin."
        case .questions: "Salı günü yüzmeden önce haber almak ister misin? Seçimini uygula, ardından Ajanda’da sonucunu gör."
        case .agenda: simulation.reminder == true ? "Yüzme 18.00’de; onayladığın hatırlatma 17.30’da. Günün rozeti iki kaydı gösteriyor." : "Yüzme 18.00’de. Hatırlatmayı onaylamadığın için yalnız plan eklendi."
        case .emotionDay: "Ajandada plan sayısının altında duygu emojileri görünür. Günün yansıması ve ilgili geçmiş günler otomatik hazırlanır. Kendi duygu seçimin AI yorumundan ayrı tutulur."
        case .emotionFlow: "Ajandada bir gün açıp duygu geçişlerine bakabilirsin. Örnek akıştan bir olaya dokunup günlükteki ifadeyi aç."
        case .export: "Ayarlar’ın en üstündeki paylaşım kartına dokun."
        case .exportPreview: "Ne yaptıracağını yaz; haritaların kişisel bağlam dosyana eklensin. Dosyayı ChatGPT'ye veya başka bir AI aracına yükle, ardından görevini yaz. AI, işle ilgili notlarından seni tanıyarak başlasın."
        case .firebase: "Masaüstüyle eşitlemek için orada kullandığın Firebase projesini Google hesabınla seç. Ayrıca yeni bir proje oluşturabilir veya kayıtlarını yalnız bu cihazda saklayabilirsin."
        case .account: "Analiz için kendi ChatGPT hesabını bağla. Günlüklerin cihazında saklanabilir. Masaüstüyle eşitlemek istersen Ayarlar’dan Firebase’i bağlayabilirsin."
        }
        return language.text(key)
    }
    var actionTitle: String {
        let key = switch stage {
        case .writing: "Devam et"
        case .daily: "Daily logosunu dene"
        case .analysing: "Analiz çalışıyor…"
        case .map: "Örnek notu aç"
        case .note: simulation.isIntroduction ? "Bugün’e dön" : "Sorulara geç"
        case .questions: "Onayı uygula"
        case .agenda: "Duygu izlerini gör"
        case .emotionDay: "Duygu geçişlerini gör"
        case .emotionFlow: "Bugün’e dön"
        case .savedDay: simulation.isIntroduction ? "ChatGPT hesabına geç" : "Paylaşımı keşfet"
        case .export: "Paylaşım kartını aç"
        case .exportPreview: "Devam et"
        case .firebase: "ChatGPT adımına geç"
        case .account: "Kendini tanıt"
        }
        return language.text(key)
    }
    var tabLabel: String {
        let key = switch stage.tab {
        case .today: "Bugün"
        case .agenda: "Ajanda"
        case .questions: "Sorular"
        case .maps: "Haritalar"
        case .settings: "Ayarlar"
        }
        return language.text(key)
    }
    var location: String {
        let section = switch stage {
        case .writing, .daily, .analysing: "YAZINI ANALİZ ET"
        case .map, .note: "BAĞLANTILARINI KEŞFET"
        case .savedDay: "KAYITLI GÜNÜN"
        case .questions: "HATIRLATMAYI SEÇ"
        case .agenda: "PLANINI GÖR"
        case .emotionDay: "DUYGU İZLERİNİ GÖR"
        case .emotionFlow: "DUYGU AKIŞINI KEŞFET"
        case .export, .exportPreview: "HAFIZANI PAYLAŞ"
        case .firebase: "KENDİ VERİTABANIN"
        case .account: "KENDİ AI HESABIN"
        }
        return tabLabel.uppercased(with: language.locale) + " · " + language.text(section)
    }
    var accent: Color {
        switch stage {
        case .firebase: DailySettingsKind.firebase.color
        case .account: DailySettingsKind.chatGPT.color
        case .questions: DailySettingsKind.notifications.color
        default: DailyTheme.mint
        }
    }
    var canContinue: Bool { stage != .analysing && (stage != .questions || simulation.reminder != nil) }

    func introductionCompleted(scope: String) -> Bool {
        UserDefaults.standard.bool(forKey: Self.introductionKey) ||
        UserDefaults.standard.bool(forKey: "daily-guided-tour-v1-" + scope)
    }

    func preserveIntroductionCompletion(scope: String) {
        if introductionCompleted(scope: scope) { UserDefaults.standard.set(true, forKey: Self.introductionKey) }
    }

    func begin(model: WorkspaceModel, language: DailyLanguage = .saved, isIntroduction: Bool = false) {
        guard !active, !model.phoneAnalysisBusy, !model.mapLinkBusy else { return }
        withoutNavigationAnimation {
            self.language = language
            simulation = GuidedTourSimulation(isIntroduction: isIntroduction); exampleText = ""; analysisReady = false
            runID = UUID(); spotlight.reset(); connectionSetup = nil; active = true
        }
    }
    func advance(firebaseConnected: Bool = false, continueLocally: Bool = false) {
        withoutNavigationAnimation {
            switch stage {
            case .daily: analysisReady = false; simulation.startAnalysis()
            case .map: simulation.openNote(GuidedTourExample.focusNodeID)
            case .export: simulation.openExport()
            default: exampleText = sampleText; simulation.advance(firebaseConnected: firebaseConnected, continueLocally: continueLocally)
            }
        }
    }
    func back() { withoutNavigationAnimation { analysisReady = false; simulation.back() } }
    func openNote(_ id: String) { withoutNavigationAnimation { simulation.openNote(id) } }
    func closeNote() { withoutNavigationAnimation { simulation.closeNote() } }
    func answer(_ answer: Bool) { withoutNavigationAnimation { simulation.answer(answer) } }
    func analysisDismissed() {
        guard active, stage == .analysing, analysisReady else { return }
        withoutNavigationAnimation { simulation.analysisFinished(); analysisReady = false }
    }
    func skip(model: WorkspaceModel) {
        if simulation.isIntroduction {
            withoutNavigationAnimation {
                analysisReady = false
                simulation.skipExample()
            }
        } else { finish(model: model, offerProfile: false) }
    }
    func finish(model: WorkspaceModel, offerProfile: Bool) {
        if simulation.isIntroduction || offerProfile {
            guard model.uid != nil, model.serverReady, ChatGPTConnection.shared.ready else { return }
        }
        UserDefaults.standard.set(true, forKey: "daily-guided-tour-v1-" + model.companionScope)
        if simulation.isIntroduction { UserDefaults.standard.set(true, forKey: Self.introductionKey) }
        withoutNavigationAnimation {
            active = false; runID = UUID(); analysisReady = false; spotlight.reset()
            connectionSetup = nil; profileOpen = offerProfile
        }
    }
    private func withoutNavigationAnimation(_ action: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, action)
    }
}

/// Rehearsal UI has its own navigation and local data; the real workspace stays underneath.
struct GuidedTourOverlay: View {
    @EnvironmentObject private var tour: GuidedTourController
    @EnvironmentObject private var model: WorkspaceModel
    @ObservedObject private var connection = ChatGPTConnection.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var firebaseReady: Bool { model.cloudConnected && model.cloudVerified && model.serverReady }
    private var needsChatGPTSetup: Bool { tour.simulation.isIntroduction && tour.stage == .account && !connection.ready }
    private var canContinue: Bool {
        guard tour.canContinue else { return false }
        if tour.stage == .firebase { return true }
        if tour.stage == .account {
            return needsChatGPTSetup ? model.uid != nil : model.serverReady && connection.ready
        }
        return true
    }

    var body: some View {
        ZStack {
            GuidedTourWorkspace()
            TourSpotlightMask(registry: tour.spotlight, target: tour.target, secondaryTarget: "active-tab", accent: tour.accent, permitsExploration: tour.isMap || tour.stage == .emotionFlow)
                .ignoresSafeArea(.container)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            coach.padding(.horizontal, 16).padding(.bottom, 64)
        }
        .background(DailyTheme.canvas.ignoresSafeArea())
        .environment(\.tourSpotlight, tour.spotlight)
        .foregroundStyle(DailyTheme.ink)
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("guided-tour-overlay")
        .sheet(item: $tour.connectionSetup) { destination in
            NavigationStack {
                Group {
                    if destination == .firebase { PersonalSetupScreen(firebaseOnly: true) }
                    else { PhoneAnalysisSettingsScreen(connectionOnly: true) }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("Tanıtıma dön") { tour.connectionSetup = nil }
                        .accessibilityIdentifier("tour-connection-return")
                } }
            }.environmentObject(model)
        }
        .sheet(isPresented: Binding(get: { tour.stage == .analysing && !tour.analysisReady }, set: { _ in }),
               onDismiss: { tour.analysisDismissed() }) {
            analysisWindow
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    #if DEBUG
                    // The cancellation test drives this sheet by tapping its real skip button.
                    if ProcessInfo.processInfo.arguments.contains("-daily-tour-hold-analysis") { return }
                    #endif
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard !Task.isCancelled, tour.active, tour.stage == .analysing else { return }
                    tour.analysisReady = true
                }
        }
        .task(id: tour.stage.rawValue + tour.runID.uuidString + String(scenePhase == .active)) {
            guard scenePhase == .active else { return }
            if tour.stage == .writing {
                if reduceMotion { tour.exampleText = tour.sampleText; return }
                let letters = Array(tour.sampleText)
                tour.exampleText = ""
                do {
                    for count in stride(from: 8, to: letters.count, by: 8) {
                        try Task.checkCancellation()
                        tour.exampleText = String(letters.prefix(count))
                        try await Task.sleep(for: .milliseconds(45))
                    }
                    try Task.checkCancellation()
                    tour.exampleText = tour.sampleText
                } catch { return }
            }
        }
    }

    private var coach: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("UYGULAMADA DENE · \(tour.simulation.progress) / \(tour.simulation.totalSteps)")
                    .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(tour.accent)
                Spacer()
                if tour.stage != .firebase && tour.stage != .account {
                    Button(LocalizedStringKey(tour.simulation.isIntroduction ? "Örneği geç" : "Geç")) { tour.skip(model: model) }
                        .font(.caption).frame(minWidth: 44, minHeight: 32)
                        .accessibilityIdentifier("guided-tour-skip")
                }
            }
            Text(tour.location).font(.system(size: 10, weight: .bold)).tracking(0.6)
                .foregroundStyle(tour.accent).accessibilityIdentifier("guided-tour-location")
            GuidedTourExplanation(stage: tour.stage, title: tour.title, detail: tour.detail)
            HStack(spacing: 10) {
                Button { tour.back() } label: {
                    Image(systemName: "arrow.left").frame(width: 44, height: 44)
                }.disabled(tour.stage == .writing || tour.stage == .analysing)
                    .accessibilityLabel("Geri").accessibilityIdentifier("guided-tour-back")
                Button {
                    if needsChatGPTSetup { tour.connectionSetup = .chatGPT }
                    else if tour.stage == .account { tour.finish(model: model, offerProfile: true) }
                    else { tour.advance(firebaseConnected: firebaseReady, continueLocally: !firebaseReady) }
                } label: {
                    HStack {
                        Text(needsChatGPTSetup ? tour.language.text("ChatGPT hesabını bağla") : tour.actionTitle)
                        Image(systemName: "arrow.right")
                    }
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(.white).background(DailyTheme.navy, in: RoundedRectangle(cornerRadius: 15))
                }.disabled(!canContinue).opacity(canContinue ? 1 : 0.55)
                    .accessibilityIdentifier("guided-tour-next")
            }.transaction { $0.animation = nil }
        }
        .padding(.horizontal, 18).padding(.bottom, 16).padding(.top, 8)
        .frame(maxWidth: 520).dailyGlass(cornerRadius: 25, accent: tour.accent)
        .background(.white, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .tourHighlight("coach")
        .buttonStyle(.plain)
    }

    private var analysisWindow: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                DailySectionHeading(eyebrow: "Tanıtım", title: "Analizin", detail: "Örnek yazından notlar ve bağlantılar hazırlanıyor.")
                HStack(spacing: 14) {
                    DailyFlowMark(isRunning: true, showsControl: true).frame(width: 72, height: 34)
                    ProgressView().tint(DailyTheme.mint)
                    Text("Örnek analiz çalışıyor…").font(.subheadline)
                }.padding(20).dailyGlass()
                Text("Simülasyon · Gerçek AI isteği veya Firebase kaydı yapılmaz.")
                    .font(.caption).foregroundStyle(DailyTheme.muted)
                Spacer(minLength: 0)
            }.padding(24).background(DailyTheme.canvas)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey(tour.simulation.isIntroduction ? "Örneği geç" : "Tanıtımı geç")) { tour.skip(model: model) }
                        .accessibilityIdentifier("guided-tour-analysis-skip")
                } }
        }
        .accessibilityIdentifier("guided-tour-analysis-window")
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
    }
}

struct GuidedTourTip: View {
    enum Kind: String {
        case emotion, export

        var message: LocalizedStringKey {
            switch self {
            case .emotion: "Günlükten çıkan duygu yorumlarını ve kendi seçimlerini görebilirsin. Benzer eski günler varsa tarihleri de görünür."
            case .export: "Dosyayı önce kullanacağın AI aracına yükle. Ardından görevini yaz ki araç, seninle ilgili gerekli bilgileri dosyadan seçebilsin."
            }
        }

        var icon: String {
            switch self {
            case .emotion: "waveform.path"
            case .export: "doc.text"
            }
        }
    }

    let kind: Kind
    @AppStorage private var dismissed: Bool

    init(kind: Kind) {
        self.kind = kind
        _dismissed = AppStorage(wrappedValue: false, "daily-contextual-tour-v1-" + kind.rawValue)
    }

    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kind.icon).foregroundStyle(DailyTheme.cobalt)
                    .padding(.top, 3).accessibilityHidden(true)
                Text(kind.message).font(.footnote)
                    .foregroundStyle(DailyTheme.ink).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { dismissed = true } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(DailyTheme.cobalt)
                    .accessibilityLabel("İpucunu kapat")
            }.padding(.leading, 14).padding(.vertical, 6)
                .dailyGlass(cornerRadius: 16, accent: DailyTheme.cobalt)
                .accessibilityIdentifier("contextual-tour-" + kind.rawValue)
        }
    }
}

/// The copy alone slides; tab switches and action buttons never inherit this animation.
private struct GuidedTourExplanation: View {
    let stage: GuidedTourSimulation.Stage
    let title: String
    let detail: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed: (id: String, title: String, detail: String) = ("", "", "")
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(displayed.title).font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("guided-tour-title")
                Text(displayed.detail).font(.subheadline).foregroundStyle(DailyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).id(displayed.id)
                .transition(reduceMotion ? .identity : .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                                 removal: .move(edge: .trailing).combined(with: .opacity)))
        }.frame(maxHeight: 134).scrollBounceBehavior(.basedOnSize).clipped()
            .onChange(of: stage, initial: true) { _, next in
                var transaction = Transaction(animation: displayed.id.isEmpty || reduceMotion ? nil : .easeInOut(duration: 0.2))
                transaction.disablesAnimations = reduceMotion
                withTransaction(transaction) { displayed = (next.rawValue, title, detail) }
            }
    }
}
