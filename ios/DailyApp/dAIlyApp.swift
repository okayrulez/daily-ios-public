import SwiftUI
import DailyCore
import UIKit
import GoogleSignIn
import Combine

@main
struct DailyXApp: App {
    @UIApplicationDelegateAdaptor(DailyPushDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var workspace = WorkspaceModel()
    var body: some Scene {
        WindowGroup {
            DailyRootView().environmentObject(workspace).preferredColorScheme(.light)
                .onChange(of: scenePhase != .background && (workspace.phoneAnalysisBusy || workspace.mapLinkBusy), initial: true) { _, keepAwake in
                    UIApplication.shared.isIdleTimerDisabled = keepAwake
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active {
                        workspace.becameActive()
                        Task { await workspace.flushClosedQuestionSessions() }
                    }
                    if phase != .active { workspace.flushDraftWrites() }
                }
                .onChange(of: workspace.phoneAnalysisBusy) { _, busy in
                    if !busy { Task { await workspace.flushClosedQuestionSessions() } }
                }
                .onChange(of: workspace.mapLinkBusy) { _, busy in
                    if !busy { Task { await workspace.flushClosedQuestionSessions() } }
                }
                .onChange(of: workspace.phoneMemoryBusy) { _, busy in
                    if !busy { Task { await workspace.flushClosedQuestionSessions() } }
                }
                .onChange(of: workspace.blocksScheduledMapReview) { _, blocked in
                    if !blocked { workspace.scheduleMapReviewIfNeeded() }
                }
                .onReceive(ChatGPTConnection.shared.$ready.removeDuplicates()) { ready in
                    if ready { Task { @MainActor in workspace.scheduleMapReviewIfNeeded() } }
                }
                .onChange(of: workspace.networkAvailable) { _, online in
                    if online {
                        Task {
                            workspace.resumeInterruptedAnalysis()
                            await workspace.flushClosedQuestionSessions()
                            workspace.scheduleMapReviewIfNeeded()
                            await workspace.retryNotificationRegistration()
                        }
                    }
                }
                .onOpenURL { url in
                    if !workspace.openAppleSurface(url) { _ = GIDSignIn.sharedInstance.handle(url) }
                }
        }
    }

}

private struct AppleRouteTrigger: Equatable {
    let route: DailyAppleRoute?
    let ready: Bool
}

struct DailyRootView: View {
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var tour = GuidedTourController()
    @AppStorage(DailyLanguage.preferenceKey) private var preferredLanguage = ""
    @State private var previewLanguageConfirmed = false
    private var languageSelected: Bool { DailyLanguage(rawValue: preferredLanguage) != nil }
    private var displayLanguage: DailyLanguage {
        if previewScreen != nil && previewScreen != "language" { return .turkish }
        return DailyLanguage(rawValue: preferredLanguage) ?? .turkish
    }
    private var offersTour: Bool { previewScreen == nil && !atlasPreview && model.authReady && model.hasStarted && model.uid != nil && languageSelected }
    private var previewScreen: String? {
        #if DEBUG
        if ["-daily-maptour-busy-preview", "-daily-maptour-questions-preview"].contains(where: ProcessInfo.processInfo.arguments.contains) { return "maptour" }
        for screen in ["maptour","changes","tasks","setup","sample","flow","tour","social","history","result","analysis","language"] {
            if ProcessInfo.processInfo.arguments.contains("-daily-"+screen+"-preview") { return screen }
        }
        if ProcessInfo.processInfo.arguments.contains("-daily-journal-preview") { return "journal" }
        if ProcessInfo.processInfo.arguments.contains("-daily-questions-preview") { return "questions" }
        if ProcessInfo.processInfo.arguments.contains("-daily-calendar-preview") { return "calendar" }
        if ProcessInfo.processInfo.arguments.contains("-daily-settings-preview") { return "settings" }
        #endif
        return nil
    }
    private var atlasPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-daily-atlas-preview")
        #else
        false
        #endif
    }
    var body: some View {
        DailyCanvas {
            VStack(spacing: 0) {
                if previewScreen == "maptour" {
                    workspaceTabs
                } else if previewScreen == "language" && !previewLanguageConfirmed {
                    languageSelection
                } else if previewScreen == "language" {
                    workspaceTabs
                } else if previewScreen == "changes" {
                    NavigationStack { WorkspaceChangesScreen().workspaceToolbar() }
                } else if previewScreen == "tasks" {
                    NavigationStack { WorkspaceTasksScreen().workspaceToolbar() }
                } else if previewScreen == "setup" {
                    NavigationStack { PersonalSetupScreen().workspaceToolbar() }
                } else if previewScreen == "sample" {
                    NavigationStack { SampleWorkspaceScreen() }
                } else if previewScreen == "social" {
                    NavigationStack { SocialProfileScreen() }
                } else if previewScreen == "analysis" {
                    AnalysisStatusSheet(date: WorkspaceModel.today)
                } else if ["flow", "tour", "history", "result"].contains(previewScreen ?? "") {
                    workspaceTabs
                } else if previewScreen == "journal" {
                    workspaceTabs
                } else if previewScreen == "questions" {
                    NavigationStack { QuestionsScreen().workspaceToolbar() }
                } else if previewScreen == "calendar" {
                    NavigationStack { PhoneAgendaScreen().workspaceToolbar() }
                } else if previewScreen == "settings" {
                    NavigationStack { SettingsScreen().workspaceToolbar() }
                } else if atlasPreview {
                    NavigationStack { AtlasMapScreen(mapID: String(repeating: "a", count: 32)) }
                } else if !model.authReady {
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large).tint(DailyTheme.orange)
                        DailySectionHeading(eyebrow: "dAIly", title: "Kayıtlı oturumun açılıyor…", detail: "Taslakların bu cihazda güvende.")
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 360).padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.uid == nil || !model.hasStarted {
                    NavigationStack { AccountScreen() }
                } else if !languageSelected {
                    languageSelection
                } else {
                    workspaceTabs
                }
            }
        }
        .allowsHitTesting(!tour.active && model.analysisMapTour == nil)
        .accessibilityHidden(tour.active || model.analysisMapTour != nil)
        .overlay { if tour.active { GuidedTourOverlay().environmentObject(tour).allowsHitTesting(true) } }
        .overlay {
            if let mapTour = model.analysisMapTour, !tour.active {
                AnalysisMapTourScreen(tour: mapTour).environmentObject(model).id(mapTour.id)
            }
        }
        .environmentObject(tour)
        .tint(DailyTheme.cobalt)
        .onAppear {
            #if DEBUG
            if previewScreen == "tour" { tour.begin(model: model, language: displayLanguage) }
            #endif
        }
        .onChange(of: offersTour, initial: true) { _, available in
            if available { startIntroductionIfNeeded() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.showPendingAnalysisMapTour() }
        }
        .onChange(of: model.analysisMapTourBlockedBySheet) { _, blocked in
            if !blocked { model.showPendingAnalysisMapTour() }
        }
        .onChange(of: model.companionScope) { previous, _ in
            model.reminderPermissionPrompt = false
            tour.preserveIntroductionCompletion(scope: previous)
            // A full replay can open the real optional Firebase connection.
            if tour.active && tour.connectionSetup == .firebase { return }
            tour.active = false; tour.profileOpen = false
            tour.connectionSetup = nil
            if offersTour { startIntroductionIfNeeded() }
        }
        .task(id: "\(offersTour)-\(tour.active)-\(tour.profileOpen)") {
            if offersTour && !tour.active && !tour.profileOpen && tour.introductionCompleted(scope: model.companionScope) { await model.requestInitialNotificationPermission() }
        }
        .task(id: "\(model.uid ?? "")-\(languageSelected)-\(tour.active)-\(tour.profileOpen)") {
            if previewScreen == nil && !atlasPreview && languageSelected && !tour.active && !tour.profileOpen {
                await model.configureNotificationsIfNeeded()
            }
        }
        .task(id: AppleRouteTrigger(route: model.pendingAppleRoute, ready: offersTour && model.serverReady && !tour.active)) {
            guard offersTour, model.serverReady, !tour.active, let route = model.pendingAppleRoute else { return }
            switch route {
            case .newNote: model.showJournal(date: WorkspaceModel.today)
            case .reflection(let date): model.showJournal(date: date)
            case .agenda: model.navigation.tab = .agenda
            }
        }
        .sheet(isPresented: $model.notificationsSheet) {
            NavigationStack {
                NotificationCenterScreen().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Kapat") { model.notificationsSheet = false } }
                }
            }
        }
        .sheet(isPresented: $model.companionSheet) { NavigationStack { CompanionInboxScreen().environmentObject(model) } }
        .sheet(isPresented: $model.agendaSheet) {
            NavigationStack {
                PhoneAgendaScreen().environmentObject(model)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { model.agendaSheet = false } } }
            }
        }
        .sheet(isPresented: $model.resetScreenOpen) {
            NavigationStack {
                WorkspaceResetScreen().environmentObject(model)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Kapat") { model.resetScreenOpen = false }.disabled(model.resettingWorkspace)
                    } }
            }.interactiveDismissDisabled(model.resettingWorkspace)
        }
        .sheet(item: $model.questionDestination) { destination in
            NavigationStack { JournalQuestionsScreen(date: destination.date).environmentObject(model)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { model.questionDestination = nil } } }
            }
            .modifier(AutomaticDayReflectionSheet(enabled: true, date: destination.date))
        }
        .sheet(item: $model.conflict) { comparison in
            ConflictScreen(comparison: comparison).environmentObject(model)
        }
        .sheet(isPresented: $tour.profileOpen) {
            NavigationStack { SocialProfileScreen() }.environmentObject(model)
        }
        .alert("Bildirimleri aç", isPresented: $model.reminderPermissionPrompt) {
            if model.reminderNeedsSystemSettings {
                Button("iPhone Ayarlarını aç") {
                    model.prepareReminderNotificationSettings()
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
            } else {
                Button("Bildirimleri aç") { Task { await model.setNotifications(true) } }
            }
            Button("Şimdi değil", role: .cancel) {}
        } message: {
            Text("Ajanda hatırlatmalarını bu iPhone’da almak için bildirimlere izin ver.")
        }
        .modifier(AutomaticDayReflectionSheet(enabled: !tour.active && !tour.profileOpen &&
            model.questionDestination == nil && !model.analysisOverlayBlockedByOtherSheet))
        .environment(\.locale, displayLanguage.locale)
    }
    private var languageSelection: some View {
        LanguageSelectionScreen { selected in
            preferredLanguage = selected.rawValue
            if previewScreen == "language" {
                previewLanguageConfirmed = true
                tour.begin(model: model, language: selected, isIntroduction: true)
            }
        }
    }

    private func startIntroductionIfNeeded() {
        if tour.introductionCompleted(scope: model.companionScope) {
            tour.preserveIntroductionCompletion(scope: model.companionScope)
            return
        }
        tour.begin(model: model, language: displayLanguage, isIntroduction: true)
    }

    private var workspaceTabs: some View {
        var selectionTransaction = Transaction(animation: nil)
        selectionTransaction.disablesAnimations = true
        return TabView(selection: $model.navigation.tab.transaction(selectionTransaction)) {
            NavigationStack { JournalScreen(date: model.navigation.journalDate, allowsDailyAction:true) }
                .id(model.navigation.journalRoute)
                .tabItem { Label("Bugün", systemImage: "square.and.pencil") }
                .tag(WorkspaceTab.today)
            NavigationStack { PhoneAgendaScreen().workspaceToolbar() }
                .tabItem { Label("Ajanda", systemImage: "calendar") }
                .tag(WorkspaceTab.agenda)
            NavigationStack(path: $model.questionTabPath) { QuestionsScreen().workspaceToolbar() }
                .tabItem { Label("Sorular", systemImage: "bubble.left.and.bubble.right") }
                .tag(WorkspaceTab.questions)
            NavigationStack { AtlasScreen().workspaceToolbar() }
                .tabItem { Label("Haritalar", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(WorkspaceTab.maps)
            NavigationStack { SettingsScreen().workspaceToolbar() }
                .tabItem { Label("Ayarlar", systemImage: "gearshape") }
                .tag(WorkspaceTab.settings)
        }
        .toolbarBackground(DailyTheme.paper, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .transaction { transaction in
            if tour.active {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .id(model.uid)
    }

}

struct MobileIntroSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    let finish: () -> Void

    private let pages: [(eyebrow: String, title: String, detail: String, symbol: String)] = [
        ("dAIly’ye hoş geldin", "Yaz, cevapla, keşfet.", "Bugün ekranına gününü veya bir düşünceni yaz. Başlamak için Ayarlar → ChatGPT bağlantısı bölümünden ChatGPT hesabını bağla.", "✳"),
        ("Analizi başlat", "Daily butonuna dokun.", "Bugün ekranındaki Daily butonu yeni yazını ve yanıtlarını kaydeder, ardından analizi başlatır. Yeni içerik yoksa yeniden AI çağrısı yapılmaz.", "app"),
        ("Hangi gün analiz edilir?", "Buton yalnız Bugün’de çalışır.", "Diğer sekmelerde Daily butonu bulunmaz. Geçmiş bir yazıyı değiştirdiğinde o yazının altındaki analiz düğmesini kullanabilirsin.", "◷"),
        ("Soruları cevapla", "Cevapların birlikte işlenir.", "İstediğin soruları cevapla. Yazdıkça üstteki Daily logosu belirginleşir; hazır olduğunda ona dokun. Cevapların birlikte analiz edilir. Ekrandan çıkmak analiz başlatmaz; taslakların korunur.", "app"),
        ("Sonucu oku", "Yanıtın bir dokunuş uzakta.", "Analiz penceresindeki küçük sayfa simgesine dokunarak ChatGPT’nin yanıtını okuyabilirsin. Sonuç hazır olduğunda Ne değiştiğini gör bağlantısı belirir. Ajandada bir güne dokunarak o günün kaydını, aktivitelerini ve alttaki yorumunu aç. Günlüğü aç düğmesiyle yazına dönebilirsin. Analiz tamamlandığında eklenen ve değişen harita bağlantıları otomatik gezdirilir. Analiz sürerken uygulamayı açık tut; ekran kendiliğinden kapanmaz.", "▤"),
        ("Sonra yeniden bak", "İzlerini keşfet.", "Sorular’da yeni sorularını, Haritalar’da düşüncelerin arasındaki bağlantıları bulursun. Bir nota dokunarak ayrıntısını okuyabilirsin. Bu tanıtımı Ayarlar → Uygulama tanıtımı bölümünden istediğin zaman tekrar açabilirsin.", "✳"),
        ("Bağlamını yanında taşı", "Haritalarını başka bir araca ver.", "Ayarlar → Zihin haritalarını paylaş bölümünden tüm haritalarını notları ve bağlantılarıyla dosya olarak al. Dosyayı kullanacağın AI aracına başlangıç bağlamı olarak ekle ve yapmak istediğin işi yaz. Örneğin yazı hazırlarken konuşma tarzını kullanmasını, ilgisiz bilgileri katmamasını iste. Dosya kişisel bilgiler içerir; yalnız istediğin araca kendin ver. Güncellemek için yeniden dışa aktar.", "▤"),
    ]

    var body: some View {
        let page = pages[step]
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    if page.symbol == "app" {
                        Image("DailyMark").resizable().scaledToFit().padding(8)
                            .accessibilityLabel("Uygulama simgesi")
                    } else {
                        Text(page.symbol).font(.system(size: 30, weight: .regular, design: .default))
                    }
                }
                .foregroundStyle(DailyTheme.cobalt)
                .frame(width: 58, height: 58)
                .background(DailyTheme.paleBlue)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                DailyEyebrow(text: page.eyebrow)
                Text(page.title)
                    .font(.system(size: 35, weight: .semibold, design: .default))
                    .fixedSize(horizontal: false, vertical: true)
                Text(page.detail)
                    .font(.body)
                    .foregroundStyle(DailyTheme.muted)
                    .lineSpacing(5)
                HStack(spacing: 7) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Capsule()
                            .fill(index == step ? DailyTheme.cobalt : DailyTheme.line)
                            .frame(width: index == step ? 28 : 8, height: 6)
                    }
                    Spacer()
                    Text("\(step + 1)/\(pages.count)").font(.caption.bold()).foregroundStyle(DailyTheme.muted)
                }
                HStack(spacing: 10) {
                    if step > 0 {
                        Button("Geri") { step -= 1 }
                            .buttonStyle(DailySecondaryButtonStyle())
                    }
                    Button(step == pages.count - 1 ? "dAIly’ye başla" : "İleri") {
                        if step == pages.count - 1 { finish(); dismiss() } else { step += 1 }
                    }
                    .buttonStyle(DailyPrimaryButtonStyle())
                }
                Button("Tanıtımı geç") { finish(); dismiss() }
                    .font(.footnote).frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(24)
        }
        .background(DailyTheme.canvas)
    }
}
