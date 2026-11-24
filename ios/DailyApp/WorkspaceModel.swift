import Foundation
import SwiftUI
import Network
import DailyCore
import UserNotifications
import FirebaseCore
@preconcurrency import FirebaseAuth
@preconcurrency import GoogleSignIn

struct WorkspaceConflict: Identifiable {
    let id = UUID()
    let uid: String
    let date: String
    let server: WorkspaceRecord?
    let base: WorkspaceRecord?
    let text: String?
    let answers: [String: DraftAnswer]
}

struct DeviceWorkspaceProfile: Codable, Identifiable {
    let projectID: String
    let uid: String
    let email: String
    var id: String { projectID + ":" + uid }
}
struct GoogleWorkspaceSelection: Codable {
    let projectID: String
    let uid: String
    let googleUID: String
    let email: String
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var analysisMapTour: AnalysisMapTour?
    @Published private(set) var pendingDayReflection: CompletedDayReflection?
    @Published private(set) var analysisStatusHosts: Set<UUID> = []
    @Published private var openDayReflectionID: String?
    @Published private var pendingMapTours: [AnalysisMapTour] = []
    @Published private(set) var resettingWorkspace = false
    @Published private(set) var resetNotice = ""
    @Published var resetScreenOpen = false
    @Published private(set) var resetStage = ""
    @Published private(set) var resetNeedsGoogleAuthorization = false
    var workspaceResetPending: Bool { workspace?.store.resetPending == true }
    var canResetWorkspace: Bool { canSwitchWorkspace && !cloudBusy && !authBusy && !checkingFirebase && !notificationToggleBusy && !notificationSetupBusy && !notificationPermissionBusy && !resettingWorkspace && !ChatGPTConnection.shared.busy }
    @Published var emotionBackfillStatus = ""
    @Published var emotionBackfillRunning = false
    @Published var navigation = WorkspaceNavigation(today: WorkspaceModel.today)
    @Published private(set) var firebaseProjectID = ""
    @Published private(set) var uid: String?
    @Published private(set) var email = ""
    @Published private(set) var googleLinked = false
    @Published private(set) var authReady = false
    @Published private(set) var connectionDiagnostic: String?
    @Published private(set) var records: [String: WorkspaceRecord] = [:] {
        didSet { resetPresentationCaches(); refreshJournalWidget() }
    }
    private let journalMemo = WorkspaceRecordMemo<JournalDocument>()
    private let experienceMemo = WorkspaceRecordMemo<WorkspaceExperience>()
    private let cardMemo = WorkspaceRecordMemo<CompanionCard>()
    private let atlasMemo = WorkspaceRecordMemo<MobileAtlas>()
    private var cachedEmotionDays: [EmotionDay]?
    var emotionDays: [EmotionDay] {
        if let cachedEmotionDays { return cachedEmotionDays }
        let days = EmotionHistory.days(records: Array(records.values))
        cachedEmotionDays = days
        return days
    }
    private var cachedEvents: [CompanionEvent]?
    private var cachedChanges: [WorkspaceChangeReceipt]?
    private var knownQuestionTitles: Set<String>?
    private var cachedPendingQuestionCount: Int?
    var pendingQuestionCount: Int {
        if let cachedPendingQuestionCount { return cachedPendingQuestionCount }
        let count = dates.reduce(0) { count, date in
            count + (journal(date: date)?.pendingQuestions.filter { !isKnownQuestion($0.prompt) }.count ?? 0)
        }
        cachedPendingQuestionCount = count
        return count
    }

    private func resetPresentationCaches() {
        cachedEmotionDays = nil
        journalMemo.reset()
        experienceMemo.reset()
        cardMemo.reset()
        atlasMemo.reset()
        cachedEvents = nil
        cachedChanges = nil
        knownQuestionTitles = nil
        cachedPendingQuestionCount = nil
    }
    @Published private(set) var requests: [String: WorkspaceAnalysisRequest] = [:]
    @Published private(set) var requestsReady = false
    @Published private(set) var requestListenerMessage: String?
    @Published private(set) var requestNotices: [String: String] = [:]
    @Published private(set) var requestFailures: Set<String> = []
    private var draftStorage: [String: WorkspaceDraft] = [:]
    private(set) var drafts: [String: WorkspaceDraft] {
        get { draftStorage }
        set {
            objectWillChange.send()
            cachedPendingQuestionCount = nil
            draftStorage = newValue
        }
    }
    @Published private(set) var busyDates: Set<String> = []
    @Published private(set) var authBusy = false
    @Published private(set) var networkAvailable = false
    @Published private(set) var serverReady = false
    @Published private(set) var checkingFirebase = false
    @Published private(set) var lastFirebaseCheck: Date?
    @Published private(set) var journalRefreshError: String?
    private var refreshID: UUID?
    @Published private(set) var configurationError = false
    @Published private(set) var googleSignInAvailable = false
    @Published private(set) var authNotice: String?
    @Published private(set) var message = "Kayıtlı oturumun açılıyor…"
    @Published var conflict: WorkspaceConflict?
    @Published var companionSheet = false
    @Published var notificationsSheet = false
    @Published var agendaSheet = false
    @Published var selectedCompanionID: String?
    @Published var questionDestination: QuestionDestination?
    @Published var questionTabPath: [QuestionDestination] = []
    @Published private(set) var companionBusy = false
    @Published private(set) var companionNotice = ""
    @Published private(set) var companionNotificationsEnabled = false
    @Published var reminderPermissionPrompt = false
    private(set) var reminderNeedsSystemSettings = false
    @Published private(set) var remotePushEnabled = false
    @Published private(set) var nativeAgendaBusy = false
    @Published private(set) var appleAgendaResults: [String: AppleAgendaBridge.Result] = [:]
    private var lastAppleAgendaHash: String?
    private var nativeDeliveryNotice: String?
    @Published private(set) var pushBusy = false
    @Published private(set) var notificationStatus = "Bildirim durumu kontrol ediliyor…"
    private var pushDeviceID: String {
        let key = "daily-push-device-id"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased(); UserDefaults.standard.set(id, forKey: key); return id
    }
    private var pushEnvironment: String { Bundle.main.object(forInfoDictionaryKey: "DailyAPNsEnvironment") as? String ?? "development" }
    private var pendingCompanionOpen: (String, String)?
    private let companionNotifications = CompanionNotifications()
    private var workspace: WorkspaceRepository?
    private enum StorageMode: String { case local, google, legacy }
    private var storageMode = StorageMode.local
    private let googleCloud = GoogleFirebaseConnection()
    @Published private(set) var hasStarted = UserDefaults.standard.bool(forKey: "daily-has-started")
    @Published private(set) var cloudBusy = false
    @Published private(set) var cloudNotice = ""
    @Published private(set) var googleProjects: [GoogleFirebaseProject] = []
    @Published private(set) var deviceProfiles: [DeviceWorkspaceProfile] = []
    var cloudConnected: Bool { workspace?.cloudEnabled == true }
    var cloudVerified: Bool { workspace?.cloudVerified == true }
    var serverPushAvailable: Bool { cloudConnected && (storageMode == .legacy || pushServiceReady || remotePushEnabled) }
    var isDeviceOnly: Bool { !cloudConnected }
    var cloudHasConflict: Bool { workspace?.syncConflict == true }
    var pendingCloudWrites: Int { workspace?.store.pendingCount ?? 0 }
    var cloudSyncNotice: String { workspace?.syncNotice ?? "" }
    var googleCloudSignedIn: Bool { googleCloud.googleUID != nil }
    var legacySignInAvailable: Bool { storageMode != .google && FirebaseApp.app() != nil }
    private var canSwitchWorkspace: Bool { !nativeAgendaBusy && !resettingWorkspace && !phoneAnalysisBusy && !phoneMemoryBusy && !mapLinkBusy && !experienceBusy && !profileResearchRunning && !emotionBackfillRunning && busyDates.isEmpty && !companionBusy && !pushBusy }
    private var draftStore: WorkspaceDraftStore?
    @Published private(set) var unreadableDraftDates: Set<String> = []
    private var draftWriteTasks: [String: Task<Void, Never>] = [:]
    private var pendingDraftWrites: [String: UUID] = [:]
    private var authHandle: AuthStateDidChangeListenerHandle?
    private let monitor = NWPathMonitor()
    private var session = UUID()
    private var listenerGeneration = UUID()
    private var requestScope: WorkspaceRequestScope?
    private var googleClientID: String?
    @Published private(set) var experienceBusy = false
    @Published private(set) var experienceNotice = ""
    @Published private(set) var phoneAnalysisBusy = false {
        didSet { if phoneAnalysisBusy { scheduledMapReviewTask?.cancel() } }
    }
    @Published private(set) var profileResearchRunning = false
    @Published private(set) var profileResearchStatus: String?
    @Published private(set) var profileResearchReport: String?
    @Published private(set) var phoneAnalysisDate: String?
    @Published private(set) var phoneAnalysisReply: String?
    @Published private(set) var phoneAnalysisChanges: AnalysisChanges?
    @Published private(set) var phonePromptRevision = "Henüz yüklenmedi"
    @Published var phoneMemoryBusy = false
    @Published private(set) var phoneAnalysisNotice = ""
    private var phoneAnalysisTask: Task<Void,Never>?
    private var phoneRuntime: PhoneAnalysisRuntime?
    private var scheduledMapReviewTask: Task<Void, Never>?
    private var checkedMapReviewManifestHash: String?

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let previewsMapTourQuestions = arguments.contains("-daily-maptour-questions-preview")
        if previewsMapTourQuestions || arguments.contains("-daily-maptour-preview") || arguments.contains("-daily-maptour-busy-preview") {
            let display = try! AtlasPreview.records(includeSecondMap: previewsMapTourQuestions)
            let tourDate = previewsMapTourQuestions ? "2026-09-29" : Self.today
            var previewRecords = display
            if previewsMapTourQuestions {
                let journal = try! WorkspaceSavePlanner.plan(current: nil, expectedHash: nil, date: tourDate,
                    text: "Bugün bir sunum yaptım.", answers: [:], now: "2026-09-29T12:00:00Z", newID: "preview-map-tour-day").record
                var payload = try! journal.payload().object!
                var entry = payload["entry"]!.object!
                let journalID = entry["id"]!
                entry["analysis_status"] = .string("complete")
                payload["entry"] = .object(entry)
                payload["questions"] = .array([.object([
                    "id": .string("preview-map-tour-question"), "journal_id": journalID,
                    "kind": .string("open"), "position": .number(0),
                    "prompt": .string("Sunum öncesi sana ne iyi geldi?"), "rationale": .string("Günün deneyimini netleştir."),
                    "source_ref": journalID, "answer_text": .null, "answer_boolean": .null
                ])])
                previewRecords.append(try! WorkspaceRecord.make(key: journal.key, kind: .journal, payload: .object(payload)))
            }
            records = Dictionary(uniqueKeysWithValues: previewRecords.map { ($0.documentID, $0) })
            let atlas = try! MobileAtlas.load(records: display)!
            let graphs = atlas.maps.map { try! MobileAtlas.graph(for: $0, records: display) }
            let graph = MobileAtlas.Graph(nodes: graphs.flatMap(\.nodes), edges: graphs.flatMap(\.edges))
            let after = try! JSONValue.parse(String(decoding: JSONEncoder().encode(graph), as: UTF8.self))
            let before = JSONValue.object(["nodes": .array([]), "edges": .array([])])
            let changes = try! AnalysisChanges(before: before, after: after, questionCount: 0)
            analysisMapTour = try! AnalysisMapTour.make(id: "preview", date: tourDate, changes: changes, records: display)
            phoneAnalysisBusy = arguments.contains("-daily-maptour-busy-preview")
            uid = "preview"; authReady = true; serverReady = false; navigation.tab = .maps
            return
        }
        if ["-daily-flow-preview", "-daily-language-preview", "-daily-tour-preview", "-daily-social-preview", "-daily-history-preview", "-daily-result-preview", "-daily-analysis-preview"].contains(where: ProcessInfo.processInfo.arguments.contains) {
            let history = JournalCalendar.key(Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
            let showingResult = ProcessInfo.processInfo.arguments.contains("-daily-result-preview") || ProcessInfo.processInfo.arguments.contains("-daily-analysis-preview")
            let target = showingResult ? Self.today : history
            var previewRecords = try! ExperiencePreview.records(for: target)
            if target != Self.today {
                let writing = try! JournalPreview.records()
                previewRecords.removeAll { record in writing.contains { $0.key == record.key } }
                previewRecords += writing
            }
            let showsAnswers = ProcessInfo.processInfo.arguments.contains("-daily-answers-preview")
            if showsAnswers {
                let original = try! JournalPreview.records()[0]
                var payload = try! original.payload().object!
                payload["questions"] = .array([
                    .object(["id":.string("preview-open"),"journal_id":.string("preview-writing"),"kind":.string("open"),"position":.number(0),"prompt":.string("Bugün sana ne iyi geldi?"),"rationale":.string("Gününü netleştir"),"source_ref":.string("preview-writing"),"answer_text":.null,"answer_boolean":.null]),
                    .object(["id":.string("preview-boolean"),"journal_id":.string("preview-writing"),"kind":.string("boolean"),"position":.number(0),"prompt":.string("Bugün dinlenebildin mi?"),"rationale":.string("Duygu bağlamı"),"source_ref":.string("preview-writing"),"answer_text":.null,"answer_boolean":.null])])
                payload["analyses"] = .array([.object(["id":.string("preview-analysis"),"journal_id":.string("preview-writing"),"version":.number(1),"provider":.string("fixture"),"confidence":.string("medium"),"created_at":.string("2026-11-17T08:00:00Z"),"reflection":.string("Örnek günün kaydedilmiş yansıması.")])])
                let questionSource = try! WorkspaceRecord.make(key: original.key, kind: .journal, payload: .object(payload))
                previewRecords.removeAll { $0.key == original.key }; previewRecords.append(questionSource)
            }
            if ProcessInfo.processInfo.arguments.contains("-daily-emotion-timeline-preview") {
                previewRecords = try! ExperiencePreview.emotionTimelineRecords()
            }
            records = Dictionary(uniqueKeysWithValues: previewRecords.map { ($0.documentID, $0) })
            draftStore = try? WorkspaceDraftStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("DailyFlowPreview-" + UUID().uuidString))
            uid = "preview"; email = "sen@example.com"; googleLinked = true; firebaseProjectID = "kisisel-alanin"; authReady = true; serverReady = true; networkAvailable = true
            if !showingResult, !showsAnswers,
               !ProcessInfo.processInfo.arguments.contains("-daily-emotion-timeline-preview"),
               !ProcessInfo.processInfo.arguments.contains("-daily-writing-saved") {
                useFirstNoteDraftPreview()
            }
            if ProcessInfo.processInfo.arguments.contains("-daily-answer-long") {
                var draft = WorkspaceDraft(uid: "preview", date: Self.today, base: records[WorkspaceHash.sha256("journal:" + Self.today)])
                draft.answers["preview-open"] = .text(String(repeating: "Bugün yürüyüşe çıktım ve dinlendim.\n", count: 130) + "Yanıtın son satırı.")
                drafts[Self.today] = draft
            }
            if ProcessInfo.processInfo.arguments.contains("-daily-draft-history-preview") {
                // This fixture represents a day with a draft and no committed analysis.
                records.removeValue(forKey: WorkspaceHash.sha256("journal:" + history))
                records.removeValue(forKey: WorkspaceHash.sha256("note:companion/changes/preview.json"))
                var draft = WorkspaceDraft(uid: "preview", date: history, base: nil)
                draft.text = "Dün yazdığım günlük cihazda taslak olarak korunuyor."
                try! draftStore!.save(draft)
                // Exercise the same disk reload as a fresh application launch.
                drafts[history] = try! draftStore!.load(uid: "preview", date: history)
            }
            if showingResult {
                phoneAnalysisDate = target
                phoneAnalysisChanges = changeReceipts.first?.changes
                phoneAnalysisReply = journal(date: target)?.latestReply
            }
            if arguments.contains("-daily-completed-reflection-preview"), let saved = journal(date: Self.today),
               let reflection = saved.dayReflection {
                pendingDayReflection = CompletedDayReflection(id: "preview-reflection", date: saved.date,
                    reflection: reflection, advice: saved.dayAdvice)
            }
            if ProcessInfo.processInfo.arguments.contains("-daily-history-preview") { navigation.showJournal(date: history) }
            return
        }
        if ["-daily-changes-preview","-daily-tasks-preview","-daily-setup-preview","-daily-sample-preview"].contains(where:ProcessInfo.processInfo.arguments.contains) {
            records=Dictionary(uniqueKeysWithValues:try! ExperiencePreview.records().map{($0.documentID,$0)})
            uid="preview";email="sen@example.com";firebaseProjectID="kisisel-alanin";authReady=true;serverReady=false
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-daily-calendar-preview") || ProcessInfo.processInfo.arguments.contains("-daily-questions-preview") || ProcessInfo.processInfo.arguments.contains("-daily-settings-preview") || ProcessInfo.processInfo.arguments.contains("-daily-journal-preview") {
            let previewRecords = ProcessInfo.processInfo.arguments.contains("-daily-calendar-preview")
                ? try! AgendaPreview.records() : ProcessInfo.processInfo.arguments.contains("-daily-journal-preview")
                ? try! JournalPreview.records() : try! QuestionsPreview.records()
            if ProcessInfo.processInfo.arguments.contains("-daily-journal-preview") {
                draftStore=try? WorkspaceDraftStore(root:FileManager.default.temporaryDirectory.appendingPathComponent("DailyWritingPreview"))
                networkAvailable=true
            }
            records = Dictionary(uniqueKeysWithValues: previewRecords.map { ($0.documentID, $0) })
            uid = "preview"; email = "sen@example.com"; googleLinked = true; firebaseProjectID = "kisisel-alanin"; authReady = true; serverReady = true
            if ProcessInfo.processInfo.arguments.contains("-daily-journal-preview") { useFirstNoteDraftPreview() }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-daily-atlas-preview") {
            records = Dictionary(uniqueKeysWithValues: (try! AtlasPreview.records()).map { (WorkspaceHash.sha256($0.key), $0) })
            uid = "preview"; authReady = true; serverReady = false
            return
        }
        #endif
        companionNotifications.onFailure = { [weak self] message in self?.companionNotice = message }
        RemotePushRegistration.shared.onLateToken = { [weak self] token in
            guard let self, self.uid != nil, self.notificationsEnabled, self.serverReady, self.cloudConnected,
                  !self.pushBusy else { return }
            Task { _ = await self.setRemotePush(true, receivedToken: token); await self.refreshNotificationStatus() }
        }
        companionNotifications.onOpen = { [weak self] scope, id in
            guard let self else { return }
            if !self.authReady { self.pendingCompanionOpen = (scope, id); return }
            guard self.uid != nil, self.companionScope == scope else { return }
            self.openNotification(id: id)
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.networkAvailable = available
                if available { self.workspace?.scheduleSync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "daily.workspace.network"))
        if let data = UserDefaults.standard.data(forKey: "daily-device-profiles") {
            deviceProfiles = (try? JSONDecoder().decode([DeviceWorkspaceProfile].self, from: data)) ?? []
        }
        let mode = UserDefaults.standard.string(forKey: "daily-storage-mode")
        if mode == "google", let data = UserDefaults.standard.data(forKey: "daily-google-workspace"),
           let selected = try? JSONDecoder().decode(GoogleWorkspaceSelection.self, from: data) {
            do {
                let scope = try MemoryScope(projectID: selected.projectID, uid: selected.uid)
                let store = try DeviceWorkspaceStore(root: Self.deviceRoot(), scope: scope)
                let cloud = try GoogleFirestoreWorkspace(api: googleCloud, project: selected.projectID, uid: selected.uid, googleUID: selected.googleUID)
                try activateRepository(WorkspaceRepository(store: store, cloud: cloud), email: selected.email, mode: .google)
                Task {
                    do { try await googleCloud.restore(expectedGoogleUID: selected.googleUID)
                        await workspace?.suspendPublication(); workspace?.resumePublication() }
                    catch { cloudNotice = "Google oturumunu yenile. Günlüklerin ve haritaların bu cihazda kullanılabilir." }
                }
            } catch { configurationError = true; authReady = true; message = "Yerel kayıt açılamadı; veriler değiştirilmedi." }
        } else if mode == "legacy", let url = try? Self.personalConfigURL(), let options = FirebaseOptions(contentsOfFile: url.path) {
            connectFirebase(options, configURL: url)
        } else { startDeviceWorkspace() }
    }

    private static func deviceRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DailyXDeviceWorkspaces", isDirectory: true)
    }
    private func startDeviceWorkspace(profile: DeviceWorkspaceProfile? = nil) {
        do {
            let saved = UserDefaults.standard.data(forKey: "daily-active-device-profile")
                .flatMap { try? JSONDecoder().decode(DeviceWorkspaceProfile.self, from: $0) }
            let localID = UserDefaults.standard.string(forKey: "daily-local-uid") ?? UUID().uuidString.lowercased()
            UserDefaults.standard.set(localID, forKey: "daily-local-uid")
            let target = profile ?? saved ?? DeviceWorkspaceProfile(projectID: "daily-local", uid: localID, email: "")
            let scope = try MemoryScope(projectID: target.projectID, uid: target.uid)
            let store = try DeviceWorkspaceStore(root: Self.deviceRoot(), scope: scope)
            try activateRepository(WorkspaceRepository(store: store), email: target.email, mode: .local)
        } catch { configurationError = true; authReady = true; message = "Cihaz deposu açılamadı. Mevcut kayıtların değiştirilmedi." }
    }
    func continueOnDevice() {
        hasStarted = true; UserDefaults.standard.set(true, forKey: "daily-has-started")
    }
    func openDeviceProfile(_ profile: DeviceWorkspaceProfile) {
        guard canSwitchWorkspace, !cloudBusy else { return }
        startDeviceWorkspace(profile: profile); continueOnDevice()
    }
    func pauseCloudSync() {
        guard canSwitchWorkspace, !cloudBusy, let uid else { return }
        startDeviceWorkspace(profile: DeviceWorkspaceProfile(projectID: firebaseProjectID, uid: uid, email: email))
    }
    private func activeAccountMatches(_ expectedUID: String) -> Bool {
        uid == expectedUID && (storageMode != .legacy || Auth.auth().currentUser?.uid == expectedUID)
    }
    private func activateRepository(_ repository: WorkspaceRepository, email: String, mode: StorageMode) throws {
        guard flushDraftWrites() else { throw WorkspaceError.invalidDraft }
        let scope = repository.store.scope
        // Use the existing project-scoped draft location, preserving unsent edits on upgrade.
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("WorkspaceDraftsByProject", isDirectory: true).appendingPathComponent(scope.projectID, isDirectory: true)
        let nextDraftStore = try WorkspaceDraftStore(root: root)
        var nextDrafts: [String: WorkspaceDraft] = [:]
        var unreadableDates: Set<String> = []
        for date in try nextDraftStore.dates(uid: scope.uid) {
            do { nextDrafts[date] = try nextDraftStore.load(uid: scope.uid, date: date) }
            catch { unreadableDates.insert(date) }
        }
        workspace?.detach(); phoneAnalysisTask?.cancel(); phoneAnalysisTask = nil
        scheduledMapReviewTask?.cancel(); checkedMapReviewManifestHash = nil
        analysisBackground.finish()
        appleAgendaResults = [:]; lastAppleAgendaHash = nil
        session = UUID(); phoneRuntime = nil; committedDisplayRetry = nil; functionalRetryAfter = [:]
        phoneAnalysisBusy = false; phoneAnalysisDate = nil; phoneAnalysisReply = nil; phoneAnalysisChanges = nil; phoneAnalysisNotice = ""
        analysisMapTour = nil; pendingMapTours = []; pendingDayReflection = nil; openDayReflectionID = nil
        emotionBackfillRunning = false; profileResearchRunning = false
        profileResearchStatus = nil; profileResearchReport = nil; experienceBusy = false
        records = [:]; drafts = nextDrafts; unreadableDraftDates = unreadableDates
        busyDates = []; conflict = nil; serverReady = false
        requests = [:]; requestsReady = false; requestScope = nil; requestNotices = [:]; requestFailures = []
        navigation = WorkspaceNavigation(today: Self.today); questionTabPath = []; refreshID = nil; checkingFirebase = false
        connectionDiagnostic = nil; configurationError = false; journalRefreshError = nil
        workspace = repository; draftStore = nextDraftStore; storageMode = mode
        uid = scope.uid; firebaseProjectID = scope.projectID; self.email = email; googleLinked = mode == .google
        authReady = true; googleSignInAvailable = true
        UserDefaults.standard.set(mode.rawValue, forKey: "daily-storage-mode")
        let profile = DeviceWorkspaceProfile(projectID: scope.projectID, uid: scope.uid, email: email)
        if !deviceProfiles.contains(where: { $0.id == profile.id }) { deviceProfiles.append(profile) }
        UserDefaults.standard.set(try JSONEncoder().encode(deviceProfiles), forKey: "daily-device-profiles")
        UserDefaults.standard.set(try JSONEncoder().encode(profile), forKey: "daily-active-device-profile")
        ChatGPTConnection.shared.reset(scope: companionScope)
        companionSheet = false; notificationsSheet = false; questionDestination = nil; selectedCompanionID = nil; companionBusy = false
        companionNotifications.reset(scope: companionScope)
        remotePushEnabled = mode != .local && UserDefaults.standard.bool(forKey: "remote-push-\(companionScope)")
        companionNotificationsEnabled = !remotePushEnabled && companionNotifications.enabled(scope: companionScope)
        repository.onSyncStateChange = { [weak self] in self?.objectWillChange.send() }
        attach(uid: scope.uid)
    }
    func beginGoogleCloudConnection() async {
        guard !cloudBusy, canSwitchWorkspace else { return }
        cloudBusy = true; cloudNotice = "Google hesabın açılıyor…"; googleProjects = []
        defer { cloudBusy = false }
        do {
            try await googleCloud.signIn()
            googleProjects = try await googleCloud.projects()
            cloudNotice = "Kendi projeni seç veya yeni Firebase projesi oluştur."
        } catch { cloudNotice = error.localizedDescription }
    }
    @discardableResult
    func connectGoogleProject(_ project: GoogleFirebaseProject, transferLocal: Bool, fresh: Bool = false) async -> Bool {
        guard !cloudBusy, canSwitchWorkspace, let googleUID = googleCloud.googleUID else { return false }
        cloudBusy = true; cloudNotice = "Seçtiğin çalışma alanı doğrulanıyor…"
        defer { cloudBusy = false }
        let oldSession = session
        let previousWorkspace = workspace
        await previousWorkspace?.suspendPublication()
        defer { if workspace === previousWorkspace { previousWorkspace?.resumePublication() } }
        do {
            let targetUID = try await googleCloud.workspaceUID(project: project.projectID, newlyCreated: fresh)
            let scope = try MemoryScope(projectID: project.projectID, uid: targetUID)
            let store = try DeviceWorkspaceStore(root: Self.deviceRoot(), scope: scope)
            let cloud = try GoogleFirestoreWorkspace(api: googleCloud, project: project.projectID, uid: targetUID, googleUID: googleUID)
            let next = WorkspaceRepository(store: store, cloud: cloud)
            try await next.bootstrap(importing: transferLocal ? workspace?.store : nil)
            guard session == oldSession else { throw WorkspaceRequestError.accountChanged }
            let selected = GoogleWorkspaceSelection(projectID: project.projectID, uid: targetUID, googleUID: googleUID, email: googleCloud.email)
            UserDefaults.standard.set(try JSONEncoder().encode(selected), forKey: "daily-google-workspace")
            try activateRepository(next, email: selected.email, mode: .google)
            googleCloud.confirmedConnection(project: selected.projectID)
            continueOnDevice(); cloudNotice = "Kendi Firebase projen bağlandı. Yerel kayıtların korunuyor."
            return true
        } catch { cloudNotice = error.localizedDescription; return false }
    }
    @discardableResult
    func createGoogleProject(name: String, region: String, transferLocal: Bool) async -> Bool {
        guard !cloudBusy, canSwitchWorkspace else { return false }
        cloudBusy = true
        do {
            let project = try await googleCloud.createProject(name: name, region: region) { self.cloudNotice = $0 }
            cloudBusy = false
            return await connectGoogleProject(project, transferLocal: transferLocal, fresh: true)
        } catch { cloudBusy = false; cloudNotice = error.localizedDescription; return false }
    }
    func syncCloudNow() async {
        guard !cloudBusy, cloudConnected else { return }
        cloudBusy = true; defer { cloudBusy = false }
        do { try await workspace?.synchronize(force: true); cloudNotice = "Eşitleme tamamlandı." }
        catch { cloudNotice = error.localizedDescription }
    }

    func useCloudVersionKeepingLocalCopy() async {
        guard !cloudBusy, canSwitchWorkspace, let workspace, cloudConnected else { return }
        cloudBusy = true; defer { cloudBusy = false }
        do {
            let id = UUID().uuidString.lowercased()
            let scope = try MemoryScope(projectID: "daily-local", uid: id)
            let backup = try DeviceWorkspaceStore(root: Self.deviceRoot(), scope: scope)
            // Register the backup before reconciliation; an interruption still leaves it discoverable.
            let profile = DeviceWorkspaceProfile(projectID: scope.projectID, uid: id, email: email)
            deviceProfiles.append(profile)
            UserDefaults.standard.set(try JSONEncoder().encode(deviceProfiles), forKey: "daily-device-profiles")
            try await workspace.useCloudVersion(preservingIn: backup)
            cloudNotice = "Bulut sürümü açıldı. Önceki cihaz sürümü ayrı bir yerel alanda korunuyor."
        } catch { cloudNotice = error.localizedDescription }
    }

    private static func personalConfigURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true).appendingPathComponent("PersonalFirebase.plist")
    }

    var hasPreviousFirebaseSetup: Bool {
        guard let url = try? Self.personalConfigURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
    func restorePreviousFirebaseSetup() {
        guard canSwitchWorkspace, !cloudBusy, !cloudConnected, FirebaseApp.app() == nil,
              let url = try? Self.personalConfigURL(), let options = FirebaseOptions(contentsOfFile: url.path) else { return }
        connectFirebase(options, configURL: url)
    }

    func importPersonalFirebase(from url: URL, updatingCurrent: Bool = false) {
        guard !authBusy,
              (updatingCurrent ? legacySignInAvailable : FirebaseApp.app() == nil && isDeviceOnly) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard url.pathExtension.lowercased() == "plist" else { throw WorkspaceConnectionError.rejected }
            let data = try Data(contentsOf: url)
            guard data.count <= 65536,
                  let fields = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  fields["private_key"] == nil,
                  let project = fields["PROJECT_ID"] as? String, project.range(of: "^[a-z][a-z0-9-]{3,62}$", options: .regularExpression) != nil,
                  (!updatingCurrent || project == FirebaseApp.app()?.options.projectID),
                  let appID = fields["GOOGLE_APP_ID"] as? String, appID.contains(":ios:"),
                  let apiKey = fields["API_KEY"] as? String, !apiKey.isEmpty,
                  fields["BUNDLE_ID"] as? String == Bundle.main.bundleIdentifier,
                  let sender = fields["GCM_SENDER_ID"] as? String, !sender.isEmpty else { throw WorkspaceConnectionError.rejected }
            // Only public client fields enter the device configuration.
            var safe = ["PROJECT_ID": project, "GOOGLE_APP_ID": appID, "API_KEY": apiKey,
                        "BUNDLE_ID": Bundle.main.bundleIdentifier ?? "", "GCM_SENDER_ID": sender, "PLIST_VERSION": "1"]
            if let clientID = fields["CLIENT_ID"] as? String,
               let scheme = fields["REVERSED_CLIENT_ID"] as? String,
               !clientID.isEmpty, !scheme.isEmpty {
                safe["CLIENT_ID"] = clientID
                safe["REVERSED_CLIENT_ID"] = scheme
            }
            let destination = try Self.personalConfigURL()
            try PropertyListSerialization.data(fromPropertyList: safe, format: .xml, options: 0).write(to: destination, options: .atomic)
            if updatingCurrent {
                authNotice = "Firebase bağlantı dosyası güncellendi. Google giriş ayarlarının etkinleşmesi için uygulamayı kapatıp yeniden aç."
                return
            }
            guard let options = FirebaseOptions(contentsOfFile: destination.path) else { throw WorkspaceConnectionError.rejected }
            connectFirebase(options, configURL: destination)
        } catch {
            authNotice = "Dosya bağlanamadı. Aynı Firebase projesinin ve bu uygulamanın bundle kimliğinin GoogleService-Info.plist dosyasını seç."
            message = authNotice ?? "Firebase bağlantı dosyası açılamadı."
        }
    }

    private func connectFirebase(_ options: FirebaseOptions, configURL: URL) {
        guard FirebaseApp.app() == nil, let project = options.projectID, flushDraftWrites() else { return }
        storageMode = .legacy
        UserDefaults.standard.set("legacy", forKey: "daily-storage-mode")
        firebaseProjectID = project
        googleClientID = options.clientID
        let configuredScheme = (NSDictionary(contentsOf: configURL) as? [String: Any])?["REVERSED_CLIENT_ID"] as? String
        let bundledSchemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
            .flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        googleSignInAvailable = options.clientID != nil && configuredScheme.map { bundledSchemes.contains($0) } == true
        do {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true).appendingPathComponent("WorkspaceDraftsByProject", isDirectory: true).appendingPathComponent(project, isDirectory: true)
            draftStore = try WorkspaceDraftStore(root: root)
        } catch { draftStore = nil; message = "Yerel taslak deposu açılamadı." }
        configurationError = false
        authReady = false
        FirebaseApp.configure(options: options)
        workspace?.detach(); workspace = nil
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            let nextUID = user?.uid
            let nextEmail = user?.email ?? ""
            Task { @MainActor in self?.changedAccount(uid: nextUID, email: nextEmail) }
        }

    }

    var canEdit: Bool { uid != nil && draftStore != nil && !cloudBusy && !resettingWorkspace && !workspaceResetPending }

    /// Invoked only by the explicit destructive confirmation in Settings.
    func resetWorkspace(authorizeCloud: Bool = false) async {
        guard canResetWorkspace, let workspace, let uid else { return }
        guard workspace.cloudEnabled || workspace.store.scope.projectID == "daily-local" else {
            resetNotice = "Önce bu çalışma alanının Firebase bağlantısını yeniden aç."; return
        }
        guard flushDraftWrites() else {
            resetNotice = "Taslak diske yazılamadı. Yeniden dene."
            return
        }
        let expectedSession = session
        let scope = workspace.store.scope
        let all = workspace.store.records()
        let mapIDs = (try? MobileAtlas.load(records: all))?.maps.map(\.id) ?? []
        let jobs = all.filter { $0.key.hasPrefix("note:dailyx/receipts/") }
            .map { String($0.key.dropFirst("note:dailyx/receipts/".count)) }
        resettingWorkspace = true; resetNotice = ""; resetStage = "Sıfırlama hazırlanıyor…"
        scheduledMapReviewTask?.cancel(); checkedMapReviewManifestHash = nil
        resetNeedsGoogleAuthorization = false
        serverReady = false
        defer { resettingWorkspace = false }
        do {
            var authorizedCloud: (any WorkspaceCloudClient)?
            if authorizeCloud {
                resetStage = "Google hesabının proje yetkisi doğrulanıyor…"
                try await googleCloud.signIn()
                guard let googleUID = googleCloud.googleUID,
                      try await googleCloud.projects().contains(where: { $0.projectID == scope.projectID }) else { throw WorkspaceSyncError.disconnected }
                authorizedCloud = try GoogleFirestoreWorkspace(api: googleCloud, project: scope.projectID, uid: scope.uid, googleUID: googleUID)
            }
            // Quiesce publication before installing the durable reset fence. Failures leave it
            // installed, so relaunch cannot upload stale pending work or restore cloud records.
            resetStage = "Bu çalışma alanının iPhone alarmları ve bildirimleri kaldırılıyor…"
            let cancelledAlarms = try AppleAgendaBridge.shared.cancelWorkspaceAlarms(scope: companionScope)
            await companionNotifications.disable(scope: companionScope)
            guard session == expectedSession, self.workspace === workspace else { throw WorkspaceRequestError.accountChanged }
            resetStage = workspace.cloudEnabled ? "Bulut kayıtların ve eski sürümleri temizleniyor…" : "Yerel çalışma alanın temizleniyor…"
            try await workspace.beginReset(authorizedCloud: authorizedCloud)
            guard session == expectedSession, self.workspace === workspace else { throw WorkspaceRequestError.accountChanged }
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            resetStage = "Cihazdaki taslaklar, analizler ve önbellek temizleniyor…"
            try WorkspaceResetFiles.erase(root: root, scope: scope, mapIDs: mapIDs, jobIDs: jobs)
            try await AIUsageLedger.shared.clear(scope: companionScope)
            guard session == expectedSession, self.workspace === workspace else { throw WorkspaceRequestError.accountChanged }
            // Finish the durable transaction before clearing visible state. A disk error must
            // keep the recovery fence and the Reset screen rather than pretending it succeeded.
            try workspace.finishReset()
            NativeAgendaDelivery.clear(scope: companionScope)
            AppleAgendaBridge.shared.clearWorkspaceReceipts(scope: companionScope)
            appleAgendaResults = [:]
            lastAppleAgendaHash = nil
            UserDefaults.standard.removeObject(forKey: nativePushDirtyKey)
            UserDefaults.standard.removeObject(forKey: analysisResumeKey)
            UserDefaults.standard.removeObject(forKey: reminderPermissionKey)
            phoneRuntime = nil; committedDisplayRetry = nil; functionalRetryAfter = [:]
            drafts = [:]; unreadableDraftDates = []; records = [:]; requests = [:]; conflict = nil
            requestNotices = [:]; requestFailures = []; requestListenerMessage = nil
            emotionBackfillStatus = ""
            analysisMapTour = nil; pendingMapTours = []; pendingDayReflection = nil; openDayReflectionID = nil; phoneAnalysisChanges = nil
            phoneAnalysisReply = nil; phoneAnalysisDate = nil; phoneAnalysisNotice = ""
            profileResearchStatus = nil; profileResearchReport = nil
            companionSheet = false; agendaSheet = false; questionDestination = nil; questionTabPath = []
            selectedCompanionID = nil; pendingCompanionOpen = nil
            companionNotificationsEnabled = false; remotePushEnabled = false
            for prefix in ["remote-push-", "remote-push-intent-", "remote-push-renewed-", "companion-scheduled-", "companion-delivery-counts-"] {
                UserDefaults.standard.removeObject(forKey: prefix + companionScope)
            }
            // Invalidate any screen reads that began before the reset.
            session = UUID()
            // Keep the Settings navigation and reset presentation open after success.
            resetNotice = String(localized: "Günlüklerin, haritaların, analizlerin, soruların ve hatırlatmaların sıfırlandı. Kaldırılan iPhone alarmı: \(cancelledAlarms).")
            resetStage = "Tamamlandı"
            message = resetNotice
            resettingWorkspace = false
            attach(uid: uid)
        } catch {
            let underlying = (error as? WorkspaceResetFailure)?.underlying ?? error
            let detail = underlying as NSError
            resetNeedsGoogleAuthorization = workspace.cloudEnabled && ((underlying as? GoogleAPIError).map { [401,403].contains($0.code) } == true || (detail.domain.contains("Firestore") && [7,16].contains(detail.code)))
            resetNotice = resetStage + " aşamasında işlem durdu. " + error.localizedDescription
                + (workspace.store.resetPending ? " Eski kayıtların yeniden eşitlenmesi güvenli biçimde durduruldu; aynı ekrandan tekrar deneyebilirsin." : " Henüz çalışma alanı silinmedi; tekrar deneyebilirsin.")
            if resetNeedsGoogleAuthorization { resetNotice += " Proje sahibi Google hesabınla silme yetkisini doğrulayabilirsin." }
        }
    }
    var dates: [String] {
        let remote = records.values.filter { $0.kind == .journal }.map { String($0.key.dropFirst(8)) }
        return Set(remote + Array(drafts.keys)).union(unreadableDraftDates).sorted(by: >)
    }
    var memoryRecords: [WorkspaceRecord] {
        records.values.filter { [.note, .inference, .vision].contains($0.kind) && !$0.key.hasPrefix("note:companion/") }
            .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    }
    func retryAtlasNotes(for map: MobileAtlas.Map) async throws -> [MobileAtlas.Note] {
        guard let workspace, let request = requestScope else { throw WorkspaceRequestError.accountChanged }
        var pages: [WorkspaceRecord] = []
        for ref in map.detailPages ?? [] {
            try Task.checkCancellation()
            guard ref.isNotePage(for: map.id) else { throw WorkspaceError.malformedRecord }
            if let record = records[WorkspaceHash.sha256(ref.key)], record.hash == ref.hash {
                pages.append(record)
            } else {
                pages.append(try await workspace.atlasPage(ref, scope: request))
            }
        }
        guard requestScope == request else { throw WorkspaceRequestError.accountChanged }
        let snapshot = pages
        let notes = try await Task.detached(priority: .userInitiated) {
            try MobileAtlas.notes(for: map, records: snapshot)
        }.value
        guard requestScope == request else { throw WorkspaceRequestError.accountChanged }
        return notes
    }

    var atlasIndex: MobileAtlas? {
        atlasMemo.value(for: records[WorkspaceHash.sha256("note:companion/atlas/index.md")]) { record in
            guard let atlas = try MobileAtlas.load(records: [record]) else { throw WorkspaceError.malformedRecord }
            return atlas
        }
    }
    static var today: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    func showJournal(date: String) {
        guard navigation.showJournal(date: date) else { return }
        agendaSheet = false
    }

    func signIn(email: String, password: String, create: Bool) async {
        guard legacySignInAvailable, !configurationError, !authBusy else { return }
        storageMode = .legacy
        authBusy = true
        authNotice = nil
        connectionDiagnostic = nil
        defer { authBusy = false }
        do {
            if create { _ = try await Auth.auth().createUser(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) }
            else { _ = try await Auth.auth().signIn(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password) }
        } catch {
            message = WorkspaceConnectionDiagnostic.auth(error)
            connectionDiagnostic = message
        }
    }

    var googleSetupMessage: String { "Google hesabınla kendi Firebase projenin listesini aç. Dosya seçmen gerekmez." }

    func signInWithGoogle(linkExisting: Bool = false) async {
        if !linkExisting { await beginGoogleCloudConnection(); return }
        guard legacySignInAvailable else { return }
        guard !configurationError, googleSignInAvailable, let googleClientID, !authBusy else {
            authNotice = googleSetupMessage
            return
        }
        guard let presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else {
            authNotice = "Google giriş penceresi açılamadı. Uygulamayı yeniden açıp tekrar dene."
            return
        }
        authBusy = true
        authNotice = nil
        defer { authBusy = false }
        do {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: googleClientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else { throw WorkspaceConnectionError.rejected }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
            if linkExisting {
                guard let user = Auth.auth().currentUser else { throw WorkspaceConnectionError.rejected }
                _ = try await user.link(with: credential)
                googleLinked = user.providerData.contains { $0.providerID == "google.com" }
                authNotice = "Google hesabın bu çalışma alanına bağlandı."
            } else {
                _ = try await Auth.auth().signIn(with: credential)
            }
        } catch {
            authNotice = "Google girişi tamamlanamadı: \(WorkspaceConnectionDiagnostic.auth(error))"
        }
    }

    func signOut() async {
        guard !resettingWorkspace, !nativeAgendaBusy, busyDates.isEmpty, !authBusy, !companionBusy, !pushBusy, flushDraftWrites() else { return }
        do {
            if remotePushEnabled || UserDefaults.standard.bool(forKey: "remote-push-\(companionScope)") || UserDefaults.standard.bool(forKey: "remote-push-intent-\(companionScope)") {
                guard await setRemotePush(false) else { message = "Bildirim kaydı kapatılamadı. İnternete bağlanıp çıkışı tekrar dene."; return }
            }
            if legacySignInAvailable { try Auth.auth().signOut() }
            GIDSignIn.sharedInstance.signOut()
            pauseCloudSync()
        } catch { message = "Çıkış yapılamadı. Lütfen tekrar dene." }
    }

    func retryListener() {
        guard let uid, workspace != nil, !phoneAnalysisBusy, !phoneMemoryBusy,
              !mapLinkBusy, !experienceBusy, busyDates.isEmpty else { return }
        attach(uid: uid)
    }

    private var isVisualPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-daily-") && $0.hasSuffix("-preview") }
        #else
        return false
        #endif
    }
    func becameActive() {
        guard !isVisualPreview else { return }
        lastAppleAgendaHash = nil
        Task {
            await configureNotificationsIfNeeded()
            refreshCompanionNotifications()
        }
        renewRemotePushIfNeeded()
        guard uid != nil else { return }
        refreshJournalWidget()
        if UserDefaults.standard.bool(forKey: reminderPermissionKey) { checkReminderPermission(expectedSession: session) }
        // The device repository keeps its observer across foreground transitions.
        if requestScope == nil && !phoneAnalysisBusy { retryListener() }
        resumeInterruptedAnalysis()
        scheduleMapReviewIfNeeded()
    }

    @Published private(set) var atlasViewError: String?
    private var committedDisplayRetry: PhoneAnalysisCommit?
    private let analysisBackground = AnalysisBackgroundExecution()
    private var analysisInterrupted = false
    private var analysisResumeKey: String { "daily-analysis-resume-" + WorkspaceHash.sha256(companionScope) }
    @Published var pendingAppleRoute: DailyAppleRoute?
    private var functionalRetryAfter: [String: Date] = [:]
    var phoneAnalysisDisplayNeedsRetry: Bool { committedDisplayRetry != nil }

    func refreshFromFirebase(date: String? = nil) async {
        guard !resettingWorkspace, !workspaceResetPending, let uid, let workspace else { return }
        if date == nil && checkingFirebase { return }
        let activeSession = session, request = UUID()
        let startingHashes = records.mapValues(\.hash)
        if date == nil { refreshID = request; checkingFirebase = true }
        defer { if refreshID == request { checkingFirebase = false; refreshID = nil } }
        do {
            let fresh: [WorkspaceRecord]
            if let date {
                let record = try await workspace.fetch(uid: uid, date: date)
                fresh = record.map { [$0] } ?? []
            }
            else { fresh = try await workspace.fetchJournals(uid: uid) }
            guard self.uid == uid, session == activeSession, self.activeAccountMatches(uid) else { return }
            for record in fresh {
                // A newer realtime snapshot may arrive while the server read is in flight.
                guard records[record.documentID]?.hash == startingHashes[record.documentID]
                        || records[record.documentID]?.hash == record.hash else { continue }
                records[record.documentID] = record
                let day = String(record.key.dropFirst(8))
                if var draft = drafts[day], !draft.hasChanges { draft.receive(record); drafts[day] = draft }
            }
            lastFirebaseCheck = Date(); journalRefreshError = nil
            refreshCompanionNotifications()
        } catch {
            guard self.uid == uid, session == activeSession else { return }
            journalRefreshError = WorkspaceConnectionDiagnostic.firestore(error)
        }
    }

    private func changedAccount(uid nextUID: String?, email: String) {
        guard storageMode == .legacy, Auth.auth().currentUser?.uid == nextUID else { return }
        guard let nextUID else { startDeviceWorkspace(); return }
        if uid == nextUID, workspace != nil { self.email = email; authReady = true; return }
        do {
            guard let project = FirebaseApp.app()?.options.projectID else { throw WorkspaceError.invalidAccount }
            let scope = try MemoryScope(projectID: project, uid: nextUID)
            let store = try DeviceWorkspaceStore(root: Self.deviceRoot(), scope: scope)
            let repository = WorkspaceRepository(store: store, cloud: try FirebaseWorkspaceCloud(uid: nextUID))
            if !store.records().isEmpty { try activateRepository(repository, email: email, mode: .legacy) }
            else { authReady = false }
            googleLinked = Auth.auth().currentUser?.providerData.contains { $0.providerID == "google.com" } ?? false
            continueOnDevice()
            Task {
                do {
                    try await repository.bootstrap()
                    guard storageMode == .legacy, Auth.auth().currentUser?.uid == nextUID else { return }
                    if workspace !== repository { try activateRepository(repository, email: email, mode: .legacy) }
                    repository.retryLocalProjection()
                }
                catch { authReady = true; cloudNotice = error.localizedDescription }
            }
        } catch { authReady = true; message = "Hesap veya cihaz deposu açılamadı. Kayıtların değiştirilmedi." }
    }

    private func attach(uid: String) {
        let activeSession = session
        let generation = UUID()
        listenerGeneration = generation
        serverReady = false
        requestsReady = false
        requestScope = nil
        do {
            try workspace?.listen(uid: uid) { [weak self] list, cached, pending, diagnostic in
                guard let self, self.uid == uid, self.session == activeSession, self.listenerGeneration == generation else { return }
                guard let list else {
                    self.serverReady = false
                    self.connectionDiagnostic = diagnostic
                    self.message = "Kayıtlar alınamadı veya doğrulanamadı. Taslaklar korundu; bağlantı ve hesap yetkisini kontrol et."
                    return
                }
                do { self.records = try WorkspaceRecord.index(list) }
                catch {
                    self.serverReady = false
                    self.message = "Kayıt kimlikleri doğrulanamadı. Hiçbir kayıt sessizce atlanmadı; taslaklar korundu."
                    return
                }
                self.serverReady = !cached && !pending && !self.workspaceResetPending && !self.resettingWorkspace
                if self.serverReady {
                    self.refreshCompanionNotifications()
                    self.renewRemotePushIfNeeded()
                    Task {
                        await self.flushClosedQuestionSessions()
                        self.scheduleMapReviewIfNeeded()
                        await self.configureNotificationsIfNeeded()
                    }
                }
                self.connectionDiagnostic = nil
                for date in Array(self.drafts.keys) {
                    guard var draft = self.drafts[date], !draft.hasChanges else { continue }
                    draft.receive(self.records[WorkspaceHash.sha256("journal:\(date)")])
                    self.drafts[date] = draft
                }
                self.message = cached ? "Önbellek gösteriliyor. Sunucu onayı yok; taslaklar cihazda korunur." : "Yazıların ve yanıtların bu cihazda hazır."
            }
            let scope = try WorkspaceRequestScope(uid: uid, session: activeSession, generation: generation)
            requestScope = scope
            try workspace?.listenRequests(scope: scope) { [weak self] list, cached, pending, diagnostic in
                guard let self, self.uid == uid, self.session == activeSession, self.listenerGeneration == generation,
                      self.requestScope == scope, self.activeAccountMatches(uid) else { return }
                guard let list else {
                    self.requests = [:]; self.requestsReady = false
                    self.requestListenerMessage = diagnostic ?? "Analiz istekleri alınamadı veya doğrulanamadı. Günlüğün korundu; durum bağlantısını yeniden dene."
                    return
                }
                self.requests = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
                self.requestsReady = !cached && !pending
                self.requestListenerMessage = cached || pending ? "Analiz durumu için sunucu onayı bekleniyor. Önbellek onay sayılmaz." : nil
                self.resumeInterruptedAnalysis()
            }
        } catch {
            requestScope = nil; requestsReady = false
            message = "Hesap bağlantısı kurulamadı."
            requestListenerMessage = "Analiz durumu bağlantısı kurulamadı. Yeniden dene."
        }
    }

    var companionScope: String { "\(firebaseProjectID)_\(uid ?? "signed-out")" }

    var savedSocialProfile: SocialProfile {
        if let record = records[WorkspaceHash.sha256(SocialProfile.key)],
           let json = try? record.payload().string, let data = json.data(using: .utf8),
           let profile = try? JSONDecoder().decode(SocialProfile.self, from: data) { return profile }
        return SocialProfile()
    }

    func saveSocialProfile(_ profile: SocialProfile) async throws {
        let clean = try profile.validated()
        guard let workspace, let scope = requestScope, canEdit, !phoneAnalysisBusy, !phoneMemoryBusy, !mapLinkBusy else { throw WorkspaceRequestError.accountChanged }
        let previous = savedSocialProfile
        let record = try await workspace.saveSocialProfile(clean, expectedHash: records[WorkspaceHash.sha256(SocialProfile.key)]?.hash, scope: scope)
        guard requestScope == scope else { throw WorkspaceRequestError.accountChanged }
        records[record.documentID] = record
        try workspace.rememberSavedRecords(Array(records.values), uid: scope.uid)
        // Clean up only the exact block generated by the previous onboarding in an
        // unsent draft. A saved journal or user-edited text stays intact.
        if let draft = drafts[Self.today]?.text {
            let cleaned = previous.removingLegacyResearchDraft(from: draft)
            if cleaned != draft { editText(date: Self.today, text: cleaned) }
        }
        profileResearchStatus = nil
        profileResearchReport = nil
        if let research = clean.researchRequest { startProfileResearch(profile: record, research: research) }
    }

    private func startProfileResearch(profile: WorkspaceRecord, research: String) {
        guard !phoneAnalysisBusy, !mapLinkBusy, !experienceBusy, !phoneMemoryBusy,
              let workspace, let request = requestScope, let uid, networkAvailable, serverReady else {
            profileResearchStatus = "Profil kaydedildi. Araştırmayı başlatmak için bağlantını kontrol edip yeniden dene."
            return
        }
        let activeSession = session
        let project = firebaseProjectID
        let key = ProfileResearchSource.key(for: profile)
        let connection = ChatGPTConnection.shared
        profileResearchRunning = true
        phoneAnalysisBusy = true
        profileResearchStatus = "Profil bilgilerin hazırlanıyor…"
        phoneAnalysisTask = Task {
            defer {
                if session == activeSession {
                    profileResearchRunning = false; phoneAnalysisBusy = false; phoneAnalysisTask = nil
                }
            }
            do {
                let scope = try MemoryScope(projectID: project, uid: uid)
                if phoneRuntime == nil { phoneRuntime = try PhoneAnalysisRuntime(client: connection.client) }
                guard let runtime = phoneRuntime else { throw AnalysisCoreError.unavailable }
                let pendingJournal = try await runtime.outbox.load(scope: scope)
                guard session == activeSession, requestScope == request else { return }
                if pendingJournal != nil {
                    profileResearchStatus = "Bekleyen bir günlük analizi var. Önce onun kaydını tamamla, sonra profil araştırmasını yeniden dene."
                    return
                }
                var pending = try await runtime.profileOutbox.load(scope: scope)
                if let old = pending, old.source.key != key {
                    try await runtime.profileOutbox.archive(scope: scope)
                    pending = nil
                }
                var source: WorkspaceRecord
                if let pending { source = pending.source }
                else if let saved = try await workspace.fetchProfileResearch(key: key, scope: request) { source = saved }
                else {
                    source = try ProfileResearchSource.make(profile: profile, request: research, date: Self.today,
                                                            now: ISO8601DateFormatter().string(from: Date()))
                    do { try await workspace.immutable(source, scope: request) }
                    catch WorkspaceError.conflict {
                        guard let existing = try await workspace.fetchProfileResearch(key: key, scope: request) else { throw WorkspaceError.conflict }
                        source = existing
                    }
                }
                guard session == activeSession, requestScope == request else { return }
                try Task.checkCancellation()
                var researchConnection: (account: String, model: String, reasoning: String?, prompts: AnalysisPromptConfiguration)?
                for _ in 0..<8 {
                    let current = try source.analysisJournal()
                    let currentStatus = current.payload.object?["daily_task"]?.object?["status"]?.string
                    if pending == nil && (currentStatus == "completed" || currentStatus == "needs_input") { break }
                    let plan: PhoneAnalysisCommit
                    if let saved = pending { plan = saved; pending = nil }
                    else {
                        if researchConnection == nil {
                            profileResearchStatus = "ChatGPT bağlantısı kontrol ediliyor…"
                            guard await connection.prepareForAnalysis(), let account = connection.registrationID else {
                                if session == activeSession { profileResearchStatus = connection.notice }
                                return
                            }
                            let prompts = try await workspace.fetchAnalysisPrompts(scope: request)
                            researchConnection = (account, connection.model, connection.selectedReasoning, prompts)
                        }
                        guard let context = researchConnection, session == activeSession, requestScope == request,
                              connection.registrationID == context.account, connection.ready else { return }
                        let (memory, manifest) = try await workspace.fetchMemory(scope: request)
                        guard session == activeSession, requestScope == request, connection.registrationID == context.account else { return }
                        try Task.checkCancellation()
                        profileResearchStatus = "Açık web’de profil eşleşmeleri ve kaynaklar aranıyor…"
                        connection.logStep("PROFILE_RESEARCH")
                        plan = try await runtime.prepare(scope: scope, accountID: context.account, model: context.model,
                            source: source, remoteMemory: memory, manifest: manifest,
                            prompts: context.prompts, reasoningEffort: context.reasoning)
                    }
                    try Task.checkCancellation()
                    guard session == activeSession, requestScope == request else { return }
                    profileResearchStatus = "Kaynaklı bulgular kişisel alanına kaydediliyor…"
                    do { try await workspace.commitAnalysis(plan, scope: request) }
                    catch WorkspaceError.conflict {
                        try await runtime.profileOutbox.archive(scope: scope)
                        throw WorkspaceError.conflict
                    }
                    do {
                        try workspace.acceptCommittedAnalysis(plan, scope: request)
                        try await runtime.completed(plan, scope: scope)
                    } catch {
                        profileResearchStatus = "Araştırma Cihaza kaydedildi. Cihaz görünümü güncellenemedi; yeniden deneme kaydı tamamlar, araştırmayı tekrar üretmez."
                        return
                    }
                    guard session == activeSession, requestScope == request else { return }
                    await presentAnalysisMapTour(plan, expectedSession: activeSession, request: request)
                    source = plan.journal
                    if try source.analysisJournal().payload.object?["daily_task"]?.object?["status"]?.string != "in_progress" { break }
                }
                let result = try source.analysisJournal()
                profileResearchReport = result.latestReply
                guard session == activeSession, requestScope == request else { return }
                switch result.payload.object?["daily_task"]?.object?["status"]?.string {
                case "completed": profileResearchStatus = "Profil araştırması tamamlandı. Kaynakları aşağıda okuyabilirsin."
                case "needs_input": profileResearchStatus = "Eşleşmeyi doğrulamak için profil bilgilerine ayrıntı ekle."
                case "blocked": profileResearchStatus = "Araştırma tamamlanamadı. Erişim ayrıntılarını aşağıda okuyabilirsin."
                default: profileResearchStatus = "Bulunan kaynaklar kaydedildi. Devam etmek için araştırmayı yeniden başlat."
                }
            } catch {
                guard session == activeSession, requestScope == request else { return }
                if Task.isCancelled || error is CancellationError {
                    profileResearchStatus = "Araştırma durduruldu. Aynı bilgilerle yeniden deneyebilirsin."
                } else {
                    connection.recordFailure(error)
                    profileResearchStatus = ChatGPTConnection.message(error)
                }
            }
        }
    }

    func fetchTaskReport(key: String) async throws -> String {
        guard let workspace, let scope = requestScope else { throw WorkspaceRequestError.accountChanged }
        let report = try await workspace.fetchTaskReport(key: key, scope: scope)
        guard requestScope == scope else { throw WorkspaceRequestError.accountChanged }
        return report
    }

    func startEmotionBackfill() {
        let connection = ChatGPTConnection.shared
        guard !phoneAnalysisBusy, !phoneMemoryBusy, !mapLinkBusy, !experienceBusy,
              let workspace, let scope = requestScope, networkAvailable, serverReady, connection.ready else {
            emotionBackfillStatus = "Önce AI hesabını ve internet bağlantını kontrol et."; return
        }
        let sources = records.values.filter { record in
            guard let journal = try? record.journal() else { return false }
            return journal.analysisStatus == "complete" && journal.payload.object?["emotional_memory"] == nil
                && !isDirty(date: journal.date)
        }.sorted { $0.key < $1.key }
        guard !sources.isEmpty else { emotionBackfillStatus = "Kaydedilmiş günlüklerinin duygu geçmişi güncel."; return }
        let activeSession = session
        let modelID = connection.model
        let reasoning = connection.selectedReasoning
        phoneAnalysisBusy = true
        emotionBackfillRunning = true
        phoneAnalysisTask = Task {
            defer {
                if session == activeSession {
                    phoneAnalysisBusy = false; phoneAnalysisTask = nil; emotionBackfillRunning = false
                }
            }
            do {
                let root = URL.applicationSupportDirectory.appendingPathComponent("EmotionBackfill")
                    .appendingPathComponent(WorkspaceHash.sha256(companionScope))
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                for (index, source) in sources.enumerated() {
                    try Task.checkCancellation()
                    guard session == activeSession, requestScope == scope else { throw WorkspaceRequestError.accountChanged }
                    let journal = try source.journal()
                    phoneAnalysisDate = journal.date
                    emotionBackfillStatus = "\(index + 1) / \(sources.count) · \(journal.date)"
                    phoneAnalysisNotice = "Geçmiş duygu kayıtları değerlendiriliyor. " + emotionBackfillStatus
                    let evidence = try JSONValue.parse(AnalysisCore.invoke("journalEvidence", json: journal.payload.canonical())).array ?? []
                    let answers = evidence.dropFirst().compactMap(\.string)
                    let prepared = try AnalysisCore.invoke("prepareEmotionBackfill", json: JSONValue.object([
                        "rawText": .string(journal.rawText), "date": .string(journal.date),
                        "answers": .array(answers.map(JSONValue.string))]).canonical())
                    let checkpoint = root.appendingPathComponent(source.hash + ".json")
                    func validate(_ raw: String) throws -> String {
                        try AnalysisCore.invoke("validateEmotionBackfill", json: JSONValue.object([
                            "rawText": .string(journal.rawText), "answers": .array(answers.map(JSONValue.string)),
                            "result": .string(raw)]).canonical())
                    }
                    let validated: String
                    if FileManager.default.fileExists(atPath: checkpoint.path) {
                        validated = try validate(String(contentsOf: checkpoint, encoding: .utf8))
                    } else {
                        let client = connection.client
                        let raw = try await client.infer(model: modelID,
                            preparedJSON: ChatGPTModel.applyingReasoning(reasoning, to: prepared))
                        try Task.checkCancellation()
                        guard session == activeSession, requestScope == scope else { throw WorkspaceRequestError.accountChanged }
                        validated = try await AnalysisCore.validateModelResponse(raw, prepared: prepared, command: "validateEmotionBackfill",
                            reasoningEffort: reasoning, infer: { try await client.infer(model: modelID, preparedJSON: $0) },
                            onRepair: { self.phoneAnalysisNotice = "Duygu yanıtının biçimi düzeltiliyor…" }, validate: validate)
                    }
                    try Task.checkCancellation()
                    guard session == activeSession, requestScope == scope else { throw WorkspaceRequestError.accountChanged }
                    try Data(validated.utf8).write(to: checkpoint, options: [.atomic, .completeFileProtection])
                    var payload = journal.payload.object!
                    var emotional = try JSONValue.parse(validated).object!
                    emotional["source_hash"] = .string(WorkspaceHash.sha256(journal.rawText))
                    payload["emotional_memory"] = .object(emotional)
                    let record = try WorkspaceRecord.make(key: source.key, kind: .journal, payload: .object(payload))
                    let saved = try await workspace.saveMapLinkJournal(scope: scope, record: record, expectedHash: source.hash, cards: [])
                    guard session == activeSession, requestScope == scope else { throw WorkspaceRequestError.accountChanged }
                    if records[saved.documentID]?.hash == source.hash { records[saved.documentID] = saved }
                    try workspace.rememberSavedRecords(Array(records.values), uid: scope.uid)
                    try? FileManager.default.removeItem(at: checkpoint)
                }
                emotionBackfillStatus = "\(sources.count) günün duygu geçmişi tamamlandı."
                phoneAnalysisNotice = emotionBackfillStatus
            } catch {
                guard session == activeSession else { return }
                emotionBackfillStatus = Task.isCancelled ? "İşlem durduruldu. Tamamlanan günler kaydedildi."
                    : "İşlem durdu. Tamamlanan günler kaydedildi. " + ChatGPTConnection.message(error)
                phoneAnalysisNotice = emotionBackfillStatus
            }
        }
    }

    private func emotionContext(for date: String) throws -> String {
        let ordered = EmotionPatterns.relevantHistory(for: text(date: date), before: date, days: emotionDays)
        var selected: [EmotionDay] = []
        for day in ordered {
            let candidate = try EmotionHistory.export(days: selected + [day]).canonical()
            if candidate.utf16.count <= 10000 { selected.append(day) }
        }
        return try EmotionHistory.export(days: selected).canonical()
    }

    func canStartDailyAnalysis(date: String) -> Bool {
        !unreadableDraftDates.contains(date)
            && PhoneAnalysisReadiness.canStart(journal: journal(date: date), text: text(date: date), pendingAnswers: drafts[date]?.answers ?? [:])
    }
    func canStartQuestionAnalysis(date: String) -> Bool {
        !unreadableDraftDates.contains(date)
            && PhoneAnalysisReadiness.canStartQuestions(journal: journal(date: date), pendingAnswers: drafts[date]?.answers ?? [:])
    }
    func submitFunctionalQuestionAnswer(date: String, id: String) {
        guard canEdit, !phoneAnalysisBusy, !phoneMemoryBusy, !mapLinkBusy, !busyDates.contains(date),
              let question = journal(date: date)?.questions.first(where: { $0.id == id }), question.isFunctional else { return }
        let draft = drafts[date]
        let answer = draft?.answers[id]
        guard answer != nil || question.hasPendingFunctionalAnswer else { return }
        let owner = session
        Task {
            if let answer {
                await save(date: date, text: nil, answers: [id: answer], expectedHash: draft?.base?.hash)
            }
            guard session == owner, drafts[date]?.answers[id] == nil, conflict == nil else { return }
            functionalRetryAfter.removeValue(forKey: date)
            _ = await applyFunctionalAnswers(date: date)
        }
    }
    private func presentAnalysisMapTour(_ plan: PhoneAnalysisCommit, expectedSession: UUID, request: WorkspaceRequestScope,
                                        researchChanges: [AnalysisChanges]? = nil) async {
        let changes = researchChanges.map(AnalysisChanges.combined) ?? plan.changes
        guard let changes else { return }
        let sourceDate = (try? plan.journal.analysisJournal().date) ?? Self.today
        let prepared = await Task.detached(priority: .userInitiated) {
            try? AnalysisMapTour.make(id: plan.jobID, date: sourceDate, changes: changes, records: plan.atlas,
                                      isJournalAnalysis: plan.source.kind == .journal && plan.execution != "functional")
        }.value
        guard session == expectedSession, requestScope == request, !Task.isCancelled, let prepared else { return }
        guard analysisMapTour?.id != prepared.id, !pendingMapTours.contains(where: { $0.id == prepared.id }) else { return }
        pendingMapTours.append(prepared)
        showPendingAnalysisMapTour()
    }
    var analysisOverlayBlockedByOtherSheet: Bool {
        notificationsSheet || companionSheet || agendaSheet || resetScreenOpen || reminderPermissionPrompt || conflict != nil
    }
    var analysisMapTourBlockedBySheet: Bool {
        analysisOverlayBlockedByOtherSheet || questionDestination != nil || pendingDayReflection != nil || dayReflectionIsOpen
    }
    var dayReflectionIsOpen: Bool { openDayReflectionID != nil }

    func setAnalysisStatusHost(_ id: UUID, visible: Bool) {
        if visible { analysisStatusHosts.insert(id) }
        else { analysisStatusHosts.remove(id) }
    }

    func takePendingDayReflection(date: String?) -> CompletedDayReflection? {
        guard !dayReflectionIsOpen, let reflection = pendingDayReflection,
              date == nil || date == reflection.date else { return nil }
        openDayReflectionID = reflection.id
        pendingDayReflection = nil
        return reflection
    }

    func closeDayReflection(id: String) {
        if openDayReflectionID == id { openDayReflectionID = nil }
    }

    private func queueDayReflection(for plan: PhoneAnalysisCommit) {
        guard let source = try? plan.source.analysisJournal(), source.isFinishingDayReflection,
              let saved = try? plan.journal.journal(), let reflection = saved.dayReflection else { return }
        pendingDayReflection = CompletedDayReflection(id: plan.jobID, date: saved.date, reflection: reflection,
            advice: saved.dayAdvice, previousReflection: saved.previousDayReflection)
    }
    func showPendingAnalysisMapTour() {
        guard UIApplication.shared.applicationState == .active, !analysisMapTourBlockedBySheet,
              analysisMapTour == nil, !pendingMapTours.isEmpty else { return }
        analysisMapTour = pendingMapTours.removeFirst()
        navigation.tab = .maps
    }
    func finishAnalysisMapTour() {
        guard let completedTour = analysisMapTour else { return }
        if !pendingMapTours.isEmpty {
            analysisMapTour = pendingMapTours.removeFirst()
            return
        }
        let pendingQuestions = journal(date: completedTour.date)?.pendingQuestions ?? []
        questionTabPath = pendingQuestions.contains(where: { !isKnownQuestion($0.prompt) })
            ? [QuestionDestination(date: completedTour.date)] : []
        navigation.tab = .questions
        analysisMapTour = nil
    }
    var hasPendingMapTours: Bool { !pendingMapTours.isEmpty }
    func closeAnalysisMapTours() {
        pendingMapTours = []; analysisMapTour = nil; navigation.tab = .maps
    }

    private func retryCommittedDisplay(_ plan: PhoneAnalysisCommit) {
        guard let workspace, let request = requestScope, let uid, let runtime = phoneRuntime else { return }
        let expectedSession = session
        phoneAnalysisBusy = true
        phoneAnalysisTask = Task {
            defer { if session == expectedSession { phoneAnalysisBusy = false; phoneAnalysisTask = nil } }
            do {
                let scope = try MemoryScope(projectID: firebaseProjectID, uid: uid)
                try workspace.acceptCommittedAnalysis(plan, scope: request)
                try await runtime.completed(plan, scope: scope)
                guard session == expectedSession, requestScope == request else { return }
                committedDisplayRetry = nil
                UserDefaults.standard.removeObject(forKey: analysisResumeKey)
                phoneAnalysisNotice = "Kaydedilmiş analiz açıldı. Yeni AI sorgusu yapılmadı."
                queueDayReflection(for: plan)
                await presentAnalysisMapTour(plan, expectedSession: expectedSession, request: request)
            } catch {
                if session == expectedSession { phoneAnalysisNotice = "Analiz Cihazında kayıtlı. Cihaz görünümü hâlâ güncellenemedi; yeniden deneyebilirsin." }
            }
        }
    }

    private func applyFunctionalAnswers(date: String) async -> Bool {
        if let retry = functionalRetryAfter[date], retry > Date() { return false }
        guard !phoneAnalysisBusy, let workspace, let request = requestScope, let uid,
              let source = records[WorkspaceHash.sha256("journal:" + date)] else { return false }
        let expectedSession = session
        functionalRetryAfter[date] = Date().addingTimeInterval(60)
        phoneAnalysisBusy = true
        defer { if session == expectedSession { phoneAnalysisBusy = false } }
        var committed = false
        do {
            if phoneRuntime == nil { phoneRuntime = try PhoneAnalysisRuntime(client: ChatGPTConnection.shared.client) }
            guard let runtime = phoneRuntime else { throw AnalysisCoreError.unavailable }
            let scope = try MemoryScope(projectID: firebaseProjectID, uid: uid)
            let (memory, manifest) = try await workspace.fetchMemory(scope: request)
            let plan = try await runtime.prepareFunctional(scope: scope, source: source, remoteMemory: memory, manifest: manifest)
            guard session == expectedSession, requestScope == request else { return false }
            let previousAgenda = workspace.store.record(ManagedAgenda.key)
            let needsReminderPermission = addsReminder(plan, previousAgenda: previousAgenda)
            try await workspace.commitAnalysis(plan, scope: request)
            committed = true
            guard session == expectedSession, requestScope == request else { return false }
            authorizeApplePlans(plan)
            if needsReminderPermission { checkReminderPermission(expectedSession: expectedSession) }
            try workspace.acceptCommittedAnalysis(plan, scope: request)
            try await runtime.completed(plan, scope: scope)
            guard session == expectedSession, requestScope == request else { return false }
            if var draft = drafts[date], records[plan.journal.documentID]?.hash == plan.journal.hash {
                draft.acknowledgeFunctional(plan.journal, previousHash: plan.source.hash)
                persist(draft)
            }
            refreshCompanionNotifications()
            functionalRetryAfter.removeValue(forKey: date)
            let applied = try plan.journal.journal()
            let results = applied.payload.object?["reminder_results"]?.array?.compactMap(\.string) ?? []
            message = results.isEmpty ? "Onayların uygulandı. Yeni AI analizi yapılmadı." : results.joined(separator: "\n")
            return true
        } catch {
            if session == expectedSession { message = committed ? "Onayların cihazına kaydedildi; cihaz görünümü yenilenemedi. Yeniden deneme kaydı tamamlar." : "Onayların saklandı; işlem tamamlanamadı. Yeniden denenecek." }
            return false
        }
    }

    func startPhoneAnalysis(date: String?, retryOnly: Bool = false, remainingStages: Int = 8, requiresNewInput: Bool = false, recovering: Bool = false) {
        guard !resettingWorkspace, !workspaceResetPending, !phoneAnalysisBusy, !mapLinkBusy, !experienceBusy else { return }
        if let date, unreadableDraftDates.contains(date) {
            phoneAnalysisNotice = "Taslak okunamadı"
            return
        }
        if let saved = committedDisplayRetry {
            retryCommittedDisplay(saved)
            return
        }
        guard flushDraftWrites(date: date) else {
            phoneAnalysisNotice = "Taslak diske yazılamadı. Yeniden dene."
            return
        }
        if !retryOnly, !recovering, let date, let journal = journal(date: date), journal.questions.contains(where: { question in
            question.hasPendingFunctionalAnswer || (question.isFunctional && drafts[date]?.answers[question.id] != nil)
        }) {
            submitQuestionAnswers(date: date)
            return
        }
        if !recovering, requiresNewInput, let date, !canStartDailyAnalysis(date:date) {
            phoneAnalysisNotice="Yeni yazı veya yanıt yok. Önceki yanıtını okuyabilirsin."
            return
        }
        phoneAnalysisReply = nil
        phoneAnalysisChanges = nil
        phoneAnalysisDate = date
        guard !phoneMemoryBusy else { phoneAnalysisNotice="Hafıza aktarımının tamamlanmasını bekle.";return }
        guard !cloudBusy, let workspace,let request=requestScope,let uid,serverReady else {
            phoneAnalysisNotice="Cihaz deposu henüz hazır değil.";return
        }
        if !networkAvailable, recovering { return }
        guard networkAvailable else {
            if let date { Task { await saveText(date: date); phoneAnalysisNotice = "Kaydedildi. Analiz için internete bağlan." } }
            else { phoneAnalysisNotice = "Analiz için internete bağlan." }
            return
        }
        let connection=ChatGPTConnection.shared
        if let date, busyDates.contains(date) {
            phoneAnalysisNotice="Devam eden kaydın tamamlanmasını bekle.";return
        }
        let activeSession=session
        let resumeKey = analysisResumeKey
        analysisInterrupted = false
        if let date { UserDefaults.standard.set(date, forKey: resumeKey) }
        if UIApplication.shared.applicationState != .background {
            analysisBackground.start { [weak self] in
                guard let self, self.session == activeSession else { return }
                self.analysisInterrupted = true
                self.phoneAnalysisTask?.cancel()
            }
        }
        phoneAnalysisBusy=true;phoneAnalysisNotice=retryOnly ? "Bekleyen kayıt denetleniyor…" : "Kaynaklar hazırlanıyor…"
        phoneAnalysisTask=Task {
            let timings = AnalysisPhaseTimings()
            var continueResearch = false
            var savedResult = false
            defer {
                if session==activeSession {
                    connection.recordAnalysisTimings(timings)
                    phoneAnalysisBusy=false;phoneAnalysisTask=nil
                    if continueResearch && !Task.isCancelled {
                        startPhoneAnalysis(date: date, remainingStages: remainingStages - 1, recovering: recovering)
                        if !phoneAnalysisBusy {
                            analysisBackground.finish()
                            if UIApplication.shared.applicationState == .active && networkAvailable {
                                UserDefaults.standard.removeObject(forKey: resumeKey)
                            }
                        }
                    } else {
                        analysisBackground.finish()
                        if analysisInterrupted && (!savedResult || continueResearch) {
                            // The foreground callback may have arrived before cancellation unwound.
                            resumeInterruptedAnalysis()
                        } else {
                            UserDefaults.standard.removeObject(forKey: resumeKey)
                        }
                    }
                }
            }
            do {
                let scope=try MemoryScope(projectID:firebaseProjectID,uid:uid)
                if phoneRuntime==nil { phoneRuntime=try PhoneAnalysisRuntime(client:connection.client) }
                guard let runtime=phoneRuntime else { throw AnalysisCoreError.unavailable }
                let pending=try await runtime.outbox.load(scope:scope)
                var checkedSource: WorkspaceRecord?
                try AnalysisScopeGuard.check(sessionMatches:session==activeSession,workspaceMatches:requestScope==request,phase:.beforePreparation)
                try Task.checkCancellation()
                var prompts = AnalysisPromptConfiguration.bundled
                // Persist an already-generated result before editing its source or asking for new inference.
                if pending == nil && !retryOnly {
                    if UIApplication.shared.applicationState == .background, !UIApplication.shared.isProtectedDataAvailable {
                        analysisInterrupted = true
                        throw CancellationError()
                    }
                    if recovering, let date, !canStartDailyAnalysis(date: date),
                       journal(date: date)?.payload.object?["daily_task"]?.object?["status"] != .string("in_progress") { return }
                    phoneAnalysisNotice="Analiz yönergeleri hazırlanıyor…"
                    connection.logStep("ANALYSIS_PROMPTS")
                    do {
                        prompts = try await workspace.fetchAnalysisPrompts(scope: request)
                    } catch {
                        guard session == activeSession, requestScope == request else { return }
                        try Task.checkCancellation()
                        connection.recordFailure(error)
                        phoneAnalysisNotice="Analiz yönergeleri doğrulanamadı. Analiz başlamadı; Ayarlar’daki hata günlüğünü kontrol et."
                        return
                    }
                    guard session == activeSession, requestScope == request else { return }
                    try Task.checkCancellation()
                    phonePromptRevision=prompts.revision
                    connection.logStep("ANALYSIS_PROMPTS_" + prompts.revision,outcome:"completed")
                    if let date {
                        open(date: date)
                        if let draft = drafts[date], draft.hasChanges {
                            phoneAnalysisNotice="Yazın ve yanıtların kaydediliyor…"
                            connection.logStep("ANALYSIS_SOURCE_SAVE")
                            await save(date: date, text: draft.text, answers: draft.answers, expectedHash: draft.base?.hash, closeQuestionSession: !draft.answers.isEmpty)
                            guard session == activeSession, requestScope == request else { return }
                            try Task.checkCancellation()
                            guard !isDirty(date: date), conflict == nil else {
                                connection.logStep("ANALYSIS_SOURCE_SAVE",outcome:"failed")
                                phoneAnalysisNotice="Analiz başlamadı. \(message)"
                                return
                            }
                            connection.logStep("ANALYSIS_SOURCE_SAVE",outcome:"completed")
                        }
                    }
                    if requiresNewInput, let date {
                        let fresh=try await workspace.fetch(uid:uid,date:date)
                        guard session==activeSession,requestScope==request else { return }
                        guard let fresh else { phoneAnalysisNotice="Önce günlük yaz.";return }
                        let saved=try fresh.journal()
                        guard PhoneAnalysisReadiness.canStart(journal:saved,text:saved.rawText,pendingAnswers:[:]) else {
                            phoneAnalysisNotice="Bu yazı zaten analiz edildi. Yanıtını okuyabilirsin."
                            return
                        }
                        checkedSource=fresh
                    }
                    phoneAnalysisNotice="Kaydedildi. ChatGPT bağlantısı kontrol ediliyor…"
                    let connected=await connection.prepareForAnalysis()
                    guard session==activeSession else { return }
                    try Task.checkCancellation()
                    if !connected && UIApplication.shared.applicationState == .background && !UIApplication.shared.isProtectedDataAvailable {
                        analysisInterrupted = true
                        throw CancellationError()
                    }
                    guard connected else { phoneAnalysisNotice=connection.notice;return }
                }
                connection.logStep(retryOnly ? "ANALYSIS_SAVE_RETRY" : "ANALYSIS_PREPARE")
                let account=connection.registrationID,selectedModel=connection.model
                let plan: PhoneAnalysisCommit
                if let pending {
                    try AnalysisScopeGuard.check(sessionMatches:session==activeSession,workspaceMatches:requestScope==request,phase:.beforeCommit)
                    plan=pending
                    phoneAnalysisDate=String(pending.source.key.dropFirst("journal:".count))
                    let saved = try pending.journal.journal()
                    if !saved.awaitsDayReflectionQuestions {
                        phoneAnalysisReply = try saved.payload.object?["daily_task"]?.canonical()
                            ?? saved.dayReflection
                    }
                }
                else {
                    let candidate: WorkspaceRecord?
                    if let checkedSource { candidate=checkedSource }
                    else if let date { candidate=try await workspace.fetch(uid:uid,date:date) }
                    else { candidate=nil }
                    guard !retryOnly,let date,let account,let source=candidate else {
                        phoneAnalysisNotice=retryOnly ? "Bekleyen analiz kaydı yok." : "Bu günün analizi için önce günlük yazıp kaydet.";return
                    }
                    let (memory,manifest)=try await workspace.fetchMemory(scope:request)
                    try AnalysisScopeGuard.check(sessionMatches:session==activeSession,workspaceMatches:requestScope==request,
                        accountMatches:connection.registrationID==account,aiReady:connection.ready,phase:.beforeInference)
                    phoneAnalysisNotice="ChatGPT değerlendiriyor…"
                    connection.logStep("ANALYSIS_INFERENCE")
                    plan = try await AnalysisPhaseTimings.$current.withValue(timings) {
                        try await runtime.prepare(scope:scope,accountID:account,model:selectedModel,
                            source:source,remoteMemory:memory,manifest:manifest,experience:experience.context + "\nTARİHLİ DUYGU GEÇMİŞİ VE ÖNCELİKLİ KULLANICI SEÇİMLERİ (yorumları yeni kanıt sayma; gerçek alıntılara dayan):\n" + (try emotionContext(for: source.analysisJournal().date)),suppressedQuestionPrompts:experience.items.filter{$0.kind == "question_known"}.map(\.title),prompts:prompts,reasoningEffort:connection.selectedReasoning,
                            onProgress: { [weak self] stage in
                                await self?.receivePhoneTaskProgress(stage, session: activeSession)
                            },
                            onReply: { [weak self] reply in
                                await self?.receivePhoneAnalysisReply(reply, session: activeSession)
                            })
                    }
                }
                try Task.checkCancellation()
                try AnalysisScopeGuard.check(sessionMatches:session==activeSession,workspaceMatches:requestScope==request,phase:.afterInference)
                phoneAnalysisNotice="Analiz doğrulandı. Günlük, hafıza ve haritalar kaydediliyor…"
                connection.logStep("ANALYSIS_SAVE")
                let previousAgenda = workspace.store.record(ManagedAgenda.key)
                let needsReminderPermission = addsReminder(plan, previousAgenda: previousAgenda)
                do {
                    let commitStart = DispatchTime.now()
                    defer { timings.record(.commit, since: commitStart) }
                    try await workspace.commitAnalysis(plan,scope:request)
                }
                if session == activeSession { connection.recordAnalysisTimings(timings) }
                savedResult = true
                try AnalysisScopeGuard.check(sessionMatches:session==activeSession,workspaceMatches:requestScope==request,phase:.afterCommit)
                authorizeApplePlans(plan)
                if needsReminderPermission { checkReminderPermission(expectedSession: activeSession) }
                // The cloud commit has succeeded. Device/cache failures below must never be reported as inference failure.
                committedDisplayRetry = plan
                do {
                    try workspace.acceptCommittedAnalysis(plan, scope: request)
                    try await runtime.completed(plan,scope:scope)
                    guard session == activeSession, requestScope == request else { return }
                    committedDisplayRetry = nil
                    refreshCompanionNotifications()
                } catch {
                    guard session == activeSession, requestScope == request else { return }
                    phoneAnalysisNotice = "Analiz Cihaza kaydedildi. Cihaz görünümü güncellenemedi; yeniden deneme yalnız kaydedilen sonucu açar."
                    connection.logStep("ANALYSIS_DISPLAY", outcome: "failed")
                    return
                }
                do { try await workspace.refreshPeriodicallyAfterAnalysis(plan, scope: request); atlasViewError = nil }
                catch { if session == activeSession { atlasViewError = "Analiz kaydedildi. Dönemsel eşitleme tamamlanamadı; cihazdaki kaydedilmiş sonuç gösteriliyor." } }
                guard session==activeSession,requestScope==request else { return }
                let currentDraftNeedsAnalysis = date.map { isDirty(date: $0) } ?? false
                phoneAnalysisNotice=pending != nil && (date != phoneAnalysisDate || currentDraftNeedsAnalysis)
                    ? "\(phoneAnalysisDate ?? "") gününün bekleyen analizi kaydedildi. Güncel yazını ve yanıtlarını analiz etmek için yukarıdaki uygulama simgesine veya Analize başla düğmesine yeniden dokun."
                    : Self.taskCompletionNotice(try plan.journal.journal())
                phoneAnalysisChanges=plan.changes
                let unfinished = try plan.journal.journal().payload.object?["daily_task"]?.object?["status"] == .string("in_progress")
                let continueCurrentWriting = pending != nil && !retryOnly && date != nil && (date != phoneAnalysisDate || currentDraftNeedsAnalysis)
                continueResearch = remainingStages > 1 && (continueCurrentWriting || (unfinished && !currentDraftNeedsAnalysis && date == phoneAnalysisDate))
                if continueCurrentWriting && continueResearch {
                    phoneAnalysisNotice = "Bekleyen sonuç kaydedildi. Şimdi güncel yazın kaydedilip analiz ediliyor…"
                }
                if unfinished && !continueResearch {
                    phoneAnalysisNotice = "Araştırmanın tamamlanan aşamaları kaydedildi. Devam etmek için uygulama simgesine dokun."
                }
                if !continueCurrentWriting { queueDayReflection(for: plan) }
                await presentAnalysisMapTour(plan, expectedSession: activeSession, request: request)
                connection.logStep("ANALYSIS_SAVE",outcome:"completed")
            } catch {
                if session==activeSession {
                    if analysisInterrupted || (!Task.isCancelled && UIApplication.shared.applicationState == .background &&
                        (!networkAvailable || !UIApplication.shared.isProtectedDataAvailable)) {
                        analysisInterrupted = true
                        phoneAnalysisNotice = "Analiz durakladı. dAIly’ye dönünce kaydedilen aşamadan devam edecek."
                    } else if Task.isCancelled {
                        phoneAnalysisNotice = "Analiz durduruldu. Yazın ve yanıtların korundu."
                    } else {
                        connection.recordFailure(error)
                        phoneAnalysisNotice=ChatGPTConnection.message(error)
                    }
                }
            }
        }
    }

    func resumeInterruptedAnalysis() {
        guard UIApplication.shared.applicationState == .active, !isVisualPreview, networkAvailable,
              uid != nil, serverReady, requestScope != nil, !phoneAnalysisBusy,
              let date = UserDefaults.standard.string(forKey: analysisResumeKey),
              WorkspaceIdentity.validDate(date), !busyDates.contains(date) else { return }
        startPhoneAnalysis(date: date, recovering: true)
    }

    func cancelPhoneAnalysis() {
        UserDefaults.standard.removeObject(forKey: analysisResumeKey)
        analysisInterrupted = false
        phoneAnalysisTask?.cancel()
    }

    var blocksScheduledMapReview: Bool {
        phoneAnalysisBusy || phoneMemoryBusy || mapLinkBusy || experienceBusy || cloudBusy || resettingWorkspace || !busyDates.isEmpty
    }

    func scheduleMapReviewIfNeeded() {
        let connection = ChatGPTConnection.shared
        guard scheduledMapReviewTask == nil, !isVisualPreview, !blocksScheduledMapReview,
              UIApplication.shared.applicationState == .active, serverReady, networkAvailable,
              committedDisplayRetry == nil, connection.ready, !connection.busy, let account = connection.registrationID,
              let workspace, let request = requestScope,
              let storedManifest = workspace.store.record(PhoneAnalysisCommit.manifestKey),
              storedManifest.hash != checkedMapReviewManifestHash else { return }

        let expectedSession = session
        let selectedModel = connection.model
        let reasoning = connection.selectedReasoning
        scheduledMapReviewTask = Task(priority: .utility) {
            defer {
                scheduledMapReviewTask = nil
                let replaced = self.workspace?.store.record(PhoneAnalysisCommit.manifestKey)?.hash != storedManifest.hash
                if Task.isCancelled || replaced { scheduleMapReviewIfNeeded() }
            }
            do {
                let (memory, manifest) = try await workspace.fetchMemory(scope: request)
                guard let memory, let manifest, manifest.hash == storedManifest.hash else { return }
                try Task.checkCancellation()
                guard session == expectedSession, requestScope == request else { return }
                guard try AnalysisCore.invoke("mapReviewDue", json: memory.json) == "true" else {
                    checkedMapReviewManifestHash = manifest.hash
                    return
                }
                if let date = memory.latestCountedJournalDate, let trigger = workspace.store.record("journal:" + date) {
                    let journal = try trigger.journal()
                    guard journal.analysisStatus == "complete", !journal.awaitsDayReflectionQuestions else { return }
                }
                let scope = workspace.store.scope
                if phoneRuntime == nil { phoneRuntime = try PhoneAnalysisRuntime(client: connection.client) }
                guard let runtime = phoneRuntime, try await runtime.hasPendingCommits(scope: scope) == false else { return }
                let prompts = try await workspace.fetchAnalysisPrompts(scope: request)
                @MainActor func stillCurrent() -> Bool {
                    !Task.isCancelled && session == expectedSession && requestScope == request && !blocksScheduledMapReview &&
                    connection.ready && connection.registrationID == account && connection.model == selectedModel &&
                    workspace.store.record(PhoneAnalysisCommit.manifestKey)?.hash == manifest.hash
                }
                guard stillCurrent() else { return }
                await runtime.coordinator.activate(scope: scope, accountID: account)
                try Task.checkCancellation()
                let result: String?
                do {
                    result = try await runtime.coordinator.crossMap(scope: scope, accountID: account, model: selectedModel,
                        memory: memory, prompts: prompts, reasoningEffort: reasoning)
                    guard result != nil else { return }
                } catch {
                    guard stillCurrent(), networkAvailable, UIApplication.shared.applicationState == .active else { return }
                    result = nil
                }
                guard stillCurrent() else { return }
                let receiptRecord = changeReceipts.first { $0.undone != true && $0.memoryHash == memory.contentHash }
                    .flatMap { workspace.store.record("note:companion/changes/" + $0.id + ".json") }
                let plan = try await Task.detached(priority: .utility) {
                    try WorkspaceMemoryMutation(reviewing: memory, expectedManifest: manifest, result: result,
                        changeReceipt: receiptRecord)
                }.value
                guard stillCurrent(), try await runtime.hasPendingCommits(scope: scope) == false, stillCurrent() else { return }
                try await workspace.commitMemoryEdit(plan, scope: request)
                if session == expectedSession { checkedMapReviewManifestHash = plan.manifest.hash }
                try await runtime.cacheCommittedMemory(plan.memory, scope: scope)
            } catch {
                if !Task.isCancelled && session == expectedSession {
                    connection.logStep("MAP_REVIEW_POST_COMMIT", outcome: "failed")
                }
            }
        }
    }

    /// Explicit export reads the current account's complete cloud memory only on request.
    func localMapReview() async throws -> JSONValue? {
        guard let uid else { return nil }
        let expectedSession=session
        let scope=try MemoryScope(projectID:firebaseProjectID,uid:uid)
        let root=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        let store=try MemoryStore(root:root.appendingPathComponent("DailyXMemory",isDirectory:true))
        let memory=try await store.load(scope:scope)
        guard session==expectedSession else { throw WorkspaceRequestError.accountChanged }
        return try memory.flatMap { try JSONValue.parse($0.json).object?["mapReview"] }
    }
    func mindmapContextSnapshot(includeEmotions: Bool) async throws -> MindmapContextSnapshot {
        guard !phoneAnalysisBusy, !phoneMemoryBusy, !mapLinkBusy, !experienceBusy,
              let workspace, let request = requestScope, uid == request.uid else {
            throw MindmapExportFailure.unavailable
        }
        guard serverReady else { throw MindmapExportFailure.offline }
        let activeSession = session
        phoneMemoryBusy = true
        defer { phoneMemoryBusy = false }
        let (memory, _) = try await workspace.fetchMemory(scope: request)
        guard session == activeSession, requestScope == request else { throw WorkspaceRequestError.accountChanged }
        guard let memory, memory.nodeCount > 0 else { throw MindmapExportFailure.empty }
        let history = includeEmotions ? EmotionHistory.export(days: emotionDays) : .array([])
        return MindmapContextSnapshot(memory: memory, emotionHistory: history)
    }
    private func receivePhoneTaskProgress(_ stage: String, session expectedSession: UUID) {
        guard session == expectedSession, phoneAnalysisBusy else { return }
        ChatGPTConnection.shared.logStep(stage)
        switch stage {
        case "LONG_JOURNAL_ANALYSIS": phoneAnalysisNotice = "Uzun günlüğün kesilmeden bölümler halinde değerlendiriliyor. Tamamlanan bölümler cihazda korunur."
        case "DAY_REFLECTION": phoneAnalysisNotice = "Günün yorumu ve yeni yanıtların değerlendiriliyor…"
        case "MAP_LINK_ANALYSIS": phoneAnalysisNotice = "Seçtiğin düşünceler arasındaki ilişkiler cevaplarınla değerlendiriliyor…"
        case "TASK_ROUTE": phoneAnalysisNotice = "İsteğin ve önceki yanıtların değerlendiriliyor…"
        case "TASK_AGENDA_QUOTE_REPAIR": phoneAnalysisNotice = "Ajanda işlemlerinin dayandığı ifadeler kontrol ediliyor…"
        case "TASK_FORMAT_REPAIR": phoneAnalysisNotice = "Yanıtın biçimi düzeltiliyor; önceki aşamalar korunuyor…"
        case "TASK_RESEARCH": phoneAnalysisNotice = "Web kaynakları araştırılıyor…"
        case "TASK_EXECUTE": phoneAnalysisNotice = "İstediğin görev üzerinde çalışılıyor…"
        default: phoneAnalysisNotice = "Günlüğün ve haritaların değerlendiriliyor…"
        }
    }
    private static func taskCompletionNotice(_ journal: JournalDocument) -> String {
        switch journal.payload.object?["daily_task"]?.object?["status"]?.string {
        case "in_progress": return "Bu araştırma aşaması kaydedildi. Eksik kalan kaynaklardan devam ediliyor…"
        case "needs_input": return "Görev için birkaç bilgi gerekiyor. Soruları yanıtlayıp geri çıktığında aynı görev otomatik devam edecek."
        case "blocked": return "Görev tamamlanamadı. Nedenini Yanıtı oku düğmesinden görebilirsin."
        case "completed": return "Görevin sonucu kaydedildi. Yanıtı oku düğmesinden rapora ulaşabilirsin."
        default: return ""
        }
    }
    private func receivePhoneAnalysisReply(_ reply: String, session expectedSession: UUID) {
        guard session == expectedSession, phoneAnalysisBusy else { return }
        phoneAnalysisReply = reply
    }
    func archivePendingPhoneAnalysis() async {
        guard !phoneAnalysisBusy, !mapLinkBusy,let uid,let runtime=phoneRuntime else { return }
        do {
            let scope=try MemoryScope(projectID:firebaseProjectID,uid:uid)
            try await runtime.outbox.archive(scope:scope)
            phoneAnalysisNotice="Bekleyen sonuç cihazda arşivlendi. Güncel kayıtla yeni analiz başlatabilirsin."
        } catch { phoneAnalysisNotice="Bekleyen sonuç arşivlenemedi; korundu." }
    }
    private func openNotification(id: String) {
        if id == "setup_test" { companionNotice="Deneme bildirimi açıldı. Yerel bildirim çalışıyor."; return }
        if id.hasPrefix("agenda_") { companionSheet = false; agendaSheet = true; return }
        let prefix = "journal_questions_"
        if id.hasPrefix(prefix), WorkspaceIdentity.validDate(String(id.dropFirst(prefix.count))) {
            companionSheet = false
            questionDestination = QuestionDestination(date: String(id.dropFirst(prefix.count)))
        } else { selectedCompanionID = id; companionSheet = true }
    }
    var companionCards: [CompanionCard] {
        let events = companionEvents
        return records.values.compactMap { record in
            cardMemo.value(for: record, decode: CompanionCard.decode)
        }.filter { !["closed", "expired"].contains($0.state(events: events)) }
            .sorted { $0.notBefore < $1.notBefore }
    }
    var companionEvents: [CompanionEvent] {
        if let cachedEvents { return cachedEvents }
        let events = records.values.compactMap { try? CompanionEvent.decode($0) }
        cachedEvents = events
        return events
    }
    var companionActive: Bool {
        guard let record = records.values.first(where: { $0.key == "note:companion/preferences.md" }),
              let text = try? record.payload().string,
              let value = try? JSONValue.parse(text) else { return true }
        return value.object?["enabled"] == .bool(true)
    }
    var companionPreferredHour: Int {
        guard let record=records[WorkspaceHash.sha256("note:companion/preferences.md")],let text=try? record.payload().string,
            let fields=try? JSONValue.parse(text).object,let hour=fields["hour"]?.integer else {return 10}
        return min(21,max(8,hour))
    }
    var companionDailyLimit: Int {
        guard let record = records.values.first(where: { $0.key == "note:companion/preferences.md" }),
              let text = try? record.payload().string,
              let value = try? JSONValue.parse(text), let limit = value.object?["dailyLimit"]?.integer else { return 3 }
        return max(1, min(5, limit))
    }
    func refreshCompanionNotifications() {
        guard uid != nil, !resettingWorkspace, !workspaceResetPending else { return }
        reconcileApplePlans()
        let scope = companionScope, events = companionEvents, active = notificationsEnabled && !remotePushEnabled
        let appleAlerts = AppleAgendaBridge.shared.coveredEvents(scope: scope, agenda: workspace?.store.record(ManagedAgenda.key))
        let reminders = records.values.first(where: { $0.key == ManagedAgenda.key })
            .flatMap { try? ManagedAgenda.reminders($0) }?
            .filter { !NativeAgendaDelivery.covers($0, scope: scope) && !appleAlerts.contains($0.deadlineId ?? "") } ?? []
        let cards = companionCards.filter { card in
            if let date = card.journalDate { return journal(date: date)?.pendingQuestions.contains(where: { !isKnownQuestion($0.prompt) }) == true }
            return companionActive
        } + reminders
        let capabilities = pushCapabilities
        let fallback = notificationsEnabled && remotePushEnabled ? reminders.filter {
            !capabilities.contains(.string("agenda-v1")) ||
            (!capabilities.contains(.string("agenda-explicit-hours")) && ManagedAgenda.expiresBeforeLegacyPushWindow($0))
        } : []
        Task { await companionNotifications.reconcile(scope: scope, cards: cards, events: events, active: active,
            dailyLimit: companionDailyLimit, preferredHour: companionPreferredHour, agendaFallbackIDs: Set(fallback.map(\.id))) }
    }
    private var nativePushDirtyKey: String { "daily-native-push-dirty-" + WorkspaceHash.sha256(companionScope) }
    private func authorizeApplePlans(_ plan: PhoneAnalysisCommit) {
        let destinations = plan.appleDestinations ?? [:]
        let revoked = plan.appleRevocations ?? []
        guard !isVisualPreview, !destinations.isEmpty || !revoked.isEmpty else { return }
        AppleAgendaBridge.shared.applyApprovals(destinations, revoking: revoked, scope: companionScope)
        lastAppleAgendaHash = nil
    }

    private func reconcileApplePlans() {
        guard !isVisualPreview, UIApplication.shared.applicationState == .active, !nativeAgendaBusy, !pushBusy,
              serverReady, !resettingWorkspace, !workspaceResetPending, let workspace else { return }
        let agenda = workspace.store.record(ManagedAgenda.key)
        let hash = agenda?.hash ?? "empty"
        guard lastAppleAgendaHash != hash else { return }
        let scope = companionScope
        let bridge = AppleAgendaBridge.shared
        guard bridge.hasWork(scope: scope) else { return }
        lastAppleAgendaHash = hash
        nativeAgendaBusy = true
        Task {
            defer {
                nativeAgendaBusy = false
                refreshCompanionNotifications()
            }
            do {
                let previous = bridge.coveredEvents(scope: scope, agenda: agenda)
                let result = try await bridge.reconcile(agenda: agenda, scope: scope)
                guard scope == companionScope else { return }
                if appleAgendaResults != result { appleAgendaResults = result }
                let changed = previous != bridge.coveredEvents(scope: scope, agenda: agenda)
                await restoreNativePushIfNeeded(scope: scope, changed: changed || agenda != nil)
            } catch {
                if scope == companionScope { companionNotice = error.localizedDescription }
            }
        }
    }

    private func nativeSuppressionKeys(scope: String, after cutoff: Date = .now) -> Set<String> {
        let manual = NativeAgendaDelivery.suppressionKeys(scope: scope, after: cutoff)
        guard let record = workspace?.store.record(ManagedAgenda.key) else { return manual }
        let covered = AppleAgendaBridge.shared.coveredEvents(scope: scope, agenda: record)
        guard !covered.isEmpty, let cards = try? ManagedAgenda.reminders(record) else { return manual }
        return manual.union(cards.compactMap { card in
            guard let id = card.deadlineId, covered.contains(id),
                  let date = CompanionCard.date(card.notBefore), date > cutoff else { return nil }
            return WorkspaceHash.sha256(NativeAgendaDelivery.deliveryKey(id, date))
        })
    }

    func restoreNativePushIfNeeded(scope: String, changed: Bool = false) async {
        guard scope == companionScope, remotePushEnabled || UserDefaults.standard.bool(forKey: "remote-push-intent-" + scope) else { return }
        if changed { UserDefaults.standard.set(true, forKey: nativePushDirtyKey) }
        guard UserDefaults.standard.bool(forKey: nativePushDirtyKey), let workspace, let request = requestScope else { return }
        do {
            try await workspace.publishNativePush(scope: request, deviceID: pushDeviceID, keys: nativeSuppressionKeys(scope: scope))
            if companionScope == scope { UserDefaults.standard.removeObject(forKey: nativePushDirtyKey) }
        } catch {
            nativeDeliveryNotice = String(localized: "Bu hatırlatmanın sunucu kaydı bağlantı kurulunca yeniden eşitlenecek.")
            companionNotice = nativeDeliveryNotice ?? ""
        }
    }
    private var pushCapabilities: [JSONValue] {
        guard let record = records.values.first(where: { $0.key == "note:companion/push-service.json" }),
              let text = try? record.payload().string, let value = try? JSONValue.parse(text) else { return [] }
        return value.object?["capabilities"]?.array ?? []
    }
    private var notificationToggleBusy = false
    private var notificationSetupBusy = false
    private var notificationPermissionBusy = false
    var notificationsEnabled: Bool {
        (UserDefaults.standard.object(forKey: "dailyx-notifications-\(companionScope)") as? Bool) ?? true
    }
    private func addsReminder(_ plan: PhoneAnalysisCommit, previousAgenda: WorkspaceRecord?) -> Bool {
        guard !plan.source.isProfileResearch else { return false }
        if let nextAgenda = plan.atlas.first(where: { $0.key == ManagedAgenda.key }), nextAgenda.hash != previousAgenda?.hash {
            let old = ManagedAgenda.reminderSchedules(previousAgenda)
            let native = plan.appleDestinations ?? [:]
            if ManagedAgenda.reminderSchedules(nextAgenda).contains(where: { native[$0.key] == nil && old[$0.key] != $0.value }) { return true }
        }
        guard let old = try? plan.source.journal(), let next = try? plan.journal.journal() else { return false }
        let oldProposals = old.questions.compactMap { $0.fields["reminder_proposal"]?.object }
        return next.pendingQuestions.contains { question in
            guard let proposal = question.fields["reminder_proposal"]?.object,
                  proposal["schedule"]?.object?["appleDestination"]?.string == nil else { return false }
            return !oldProposals.contains(proposal)
        }
    }

    private var reminderPermissionKey: String { "daily-reminder-permission-" + WorkspaceHash.sha256(companionScope) }

    private func checkReminderPermission(expectedSession: UUID) {
        guard !isVisualPreview else { return }
        if UIApplication.shared.applicationState != .active {
            UserDefaults.standard.set(true, forKey: reminderPermissionKey)
            return
        }
        UserDefaults.standard.removeObject(forKey: reminderPermissionKey)
        Task {
            let status = await companionNotifications.authorizationStatus()
            guard session == expectedSession else { return }
            if status == .notDetermined && notificationsEnabled {
                do {
                    let granted = try await companionNotifications.requestPermission()
                    guard granted, session == expectedSession else { return }
                    await setNotifications(true)
                } catch {
                    guard session == expectedSession else { return }
                    reminderNeedsSystemSettings = false
                    reminderPermissionPrompt = true
                }
                return
            }
            guard status == .denied || status == .notDetermined || !notificationsEnabled else { return }
            reminderNeedsSystemSettings = status == .denied
            reminderPermissionPrompt = true
        }
    }

    func prepareReminderNotificationSettings() {
        UserDefaults.standard.set(true, forKey: "dailyx-notifications-\(companionScope)")
        objectWillChange.send()
    }
    func requestInitialNotificationPermission() async {
        guard !isVisualPreview else { return }
        guard !notificationPermissionBusy, !UserDefaults.standard.bool(forKey: "dailyx-notification-prompted") else { return }
        notificationPermissionBusy=true
        defer { notificationPermissionBusy=false }
        do {
            _ = try await companionNotifications.requestPermission()
            UserDefaults.standard.set(true, forKey: "dailyx-notification-prompted")
        } catch { companionNotice="Bildirim izni alınamadı. Bir sonraki açılışta yeniden denenecek." }
    }
    func configureNotificationsIfNeeded() async {
        guard !resettingWorkspace, !workspaceResetPending else { return }
        guard !isVisualPreview else { return }
        guard uid != nil, !notificationSetupBusy, !pushBusy, !nativeAgendaBusy else { return }
        notificationSetupBusy=true
        defer { notificationSetupBusy=false; Task { await refreshNotificationStatus() } }
        let scope=companionScope
        // Migrate explicit local opt-outs, but do not interpret remote mode's local-off as an opt-out.
        let key="dailyx-notifications-\(scope)"
        if UserDefaults.standard.object(forKey:key) == nil {
            let old=UserDefaults.standard.object(forKey:"companion-notifications-\(scope)") as? Bool
            UserDefaults.standard.set(remotePushEnabled || old != false,forKey:key)
        }
        guard notificationsEnabled else {
            if remotePushEnabled || UserDefaults.standard.bool(forKey:"remote-push-\(companionScope)") || UserDefaults.standard.bool(forKey:"remote-push-intent-\(companionScope)") { _ = await setRemotePush(false) }
            if companionNotifications.enabled(scope: scope) {
                await companionNotifications.disable(scope: scope)
                if scope == companionScope { companionNotificationsEnabled = false }
            }
            return
        }
        if remotePushEnabled { await restoreNativePushIfNeeded(scope: scope) }
        if !remotePushEnabled && !companionNotificationsEnabled {
            await setCompanionNotifications(true)
        }
    }
    func refreshNotificationStatus() async {
        let scope = companionScope
        let status = await companionNotifications.statusSummary()
        guard scope == companionScope else { return }
        notificationStatus = status + (!serverPushAvailable ? " · Yerel hatırlatmalar" : remotePushEnabled ? " · Sunucu cihaz kaydı: açık" : " · Sunucu cihaz kaydı: yok")
    }
    func retryNotificationRegistration(requestServer: Bool = false) async {
        guard notificationsEnabled else { await refreshNotificationStatus(); return }
        if remotePushEnabled || (requestServer && cloudConnected) {
            _ = await setRemotePush(true)
        } else { await configureNotificationsIfNeeded() }
        await refreshNotificationStatus()
    }
    func setNotifications(_ enabled: Bool) async {
        guard uid != nil, !nativeAgendaBusy, !pushBusy, !notificationSetupBusy, !notificationToggleBusy else { return }
        notificationToggleBusy = true
        defer { notificationToggleBusy = false }
        let scope=companionScope
        UserDefaults.standard.set(enabled,forKey:"dailyx-notifications-\(scope)")
        if !enabled {
            if remotePushEnabled || UserDefaults.standard.bool(forKey:"remote-push-\(companionScope)") || UserDefaults.standard.bool(forKey:"remote-push-intent-\(companionScope)") { _ = await setRemotePush(false) }
            guard companionScope == scope else { return }
            companionNotificationsEnabled = false
            await companionNotifications.disable(scope: scope)
        } else {
            await configureNotificationsIfNeeded()
        }
        objectWillChange.send()
    }
    func setCompanionNotifications(_ enabled: Bool) async {
        guard uid != nil, !pushBusy, !remotePushEnabled else { return }
        let scope = companionScope
        do {
            if enabled {
                let granted = try await companionNotifications.enable(scope: scope)
                guard companionScope == scope else { return }
                companionNotificationsEnabled=granted
                if !granted { companionNotice="Bildirim izni kapalı. İzin vermek için iPhone bildirim ayarlarını aç." }
            }
            else { await companionNotifications.disable(scope: scope); companionNotificationsEnabled = false }
            if companionScope == scope { refreshCompanionNotifications() }
        } catch { companionNotice = "Bildirim izni alınamadı. iPhone Ayarları’ndan kontrol edebilirsin." }
    }
    func renewRemotePushIfNeeded() {
        guard cloudConnected, remotePushEnabled, notificationsEnabled, serverReady, !pushBusy else { return }
        let last = UserDefaults.standard.double(forKey: "remote-push-renewed-\(companionScope)")
        guard Date().timeIntervalSince1970 - last > 86400 else { return }
        Task { _ = await setRemotePush(true) }
    }
    var pushServiceReady: Bool {
        guard let record=records.values.first(where:{$0.key=="note:companion/push-service.json"}),
              let text=try? record.payload().string,let value=try? JSONValue.parse(text).object,
              value["bundleID"]?.string==Bundle.main.bundleIdentifier,
              let at=value["updatedAt"]?.string.flatMap(CompanionCard.date) else { return false }
        return Date().timeIntervalSince(at)>=0 && Date().timeIntervalSince(at)<600
    }
    @discardableResult
    func setRemotePush(_ enabled: Bool) async -> Bool {
        await setRemotePush(enabled, receivedToken: nil)
    }
    @discardableResult
    private func setRemotePush(_ enabled: Bool, receivedToken: String?) async -> Bool {
        // The app identity is shared with dAIly; readiness still belongs to the DailyX queue.
        // Registration must not depend on a cached heartbeat: snapshots are intentionally
        // refreshed only after analysis, so an otherwise healthy service can look stale.
        guard cloudConnected, !nativeAgendaBusy, !pushBusy, serverReady, let workspace, let request = requestScope,
              !enabled || notificationsEnabled else { return false }
        let scope = companionScope
        let renewing = remotePushEnabled
        let futureNative = enabled && !nativeSuppressionKeys(scope: scope).isEmpty
        pushBusy = true
        defer { pushBusy = false }
        var stage = "APNS_REGISTER"
        do {
            if enabled {
                let nativeKeys = nativeSuppressionKeys(scope: scope)
                if !nativeKeys.isEmpty || UserDefaults.standard.bool(forKey: nativePushDirtyKey) {
                    stage = "NATIVE_DELIVERY_CHECK"
                    try await workspace.publishNativePush(scope: request, deviceID: pushDeviceID, keys: nativeKeys,
                        checkingCapability: futureNative && !renewing)
                    guard companionScope == scope, requestScope == request else { return false }
                    UserDefaults.standard.removeObject(forKey: nativePushDirtyKey)
                }
            }
            stage = "APNS_REGISTER"
            companionNotice = enabled ? "iPhone’un Apple bildirim adresi alınıyor…" : "Bildirim kaydı kaldırılıyor…"
            let token: String?
            if enabled, let receivedToken { token = receivedToken }
            else if enabled { token = try await RemotePushRegistration.shared.token() }
            else { token = nil }
            guard companionScope == scope, requestScope == request else { return false }
            // Persist intent before the acknowledged write, so interruption still allows later revocation.
            if enabled {
                UserDefaults.standard.set(true, forKey: "remote-push-intent-\(scope)")
            }
            companionNotice = enabled ? "Apple adresi alındı; Firebase’e kaydediliyor…" : "Bildirim kaydı kaldırılıyor…"
            stage = "FIREBASE_DEVICE_WRITE"
            try await workspace.registerPush(scope: request, deviceID: pushDeviceID, token: token, environment: pushEnvironment)
            guard companionScope == scope else { return false }
            remotePushEnabled = enabled
            if enabled { companionNotifications.useRemoteDelivery(scope: scope); companionNotificationsEnabled = false }
            UserDefaults.standard.set(enabled, forKey: "remote-push-\(scope)")
            UserDefaults.standard.removeObject(forKey: "remote-push-intent-\(scope)")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "remote-push-renewed-\(scope)")
            companionNotice = enabled ? "Cihaz kaydı alındı. Bildirimlerin gelmesi için Firebase push servisinin de çalışması gerekir. Kayıt uygulamayı açtıkça yenilenir; 7 gün sonra sona erer." : "Uzaktan bildirim kaydı kapatıldı."
            if renewing, futureNative,
               !pushCapabilities.contains(.string("agenda-native-device-v1")) {
                companionNotice += " " + String(localized: "Bu cihazda Apple’a aktarılmış hatırlatmalar var. Bildirim servisi etkinlik bazlı teslimatı destekleyene kadar aynı hatırlatma iki kez gelebilir.")
            }
            refreshCompanionNotifications()
            return true
        } catch {
            guard companionScope == scope, requestScope == request else { return false }
            if enabled && !renewing && notificationsEnabled {
                if !companionNotificationsEnabled {
                    companionNotificationsEnabled = (try? await companionNotifications.enable(scope: scope)) == true
                }
                guard companionScope == scope, requestScope == request else { return false }
                refreshCompanionNotifications()
                if error is NativePushFailure {
                    companionNotice = String(localized: "İlerideki Apple hatırlatmalarının iki kez gelmesini önlemek için sunucu kaydı bekliyor. Firebase bildirim servisi güncellendiğinde “Bildirim kaydını yeniden dene”ye dokun.")
                    return false
                }
            }
            // Back off failed renewals; explicit toggle remains available for immediate retry.
            UserDefaults.standard.set(Date().timeIntervalSince1970 - 86400 + 300, forKey: "remote-push-renewed-\(scope)")
            companionNotice = (error as? RemotePushRegistration.Failure) == .denied
                ? "iPhone bildirim izni kapalı. Aşağıdaki iPhone bildirim ayarlarını aç düğmesinden izin ver."
                : "Cihaz sunucuya kaydedilemedi. Yerel hatırlatmalar açık kalır. \(error.localizedDescription) [\(stage) · \(pushEnvironment) · \((error as NSError).domain) · \((error as NSError).code)]"
            return false
        }
    }

    func respondCompanion(card: CompanionCard, action: String, text: String = "") async -> Bool {
        guard !companionBusy, serverReady, let workspace, let scope = requestScope,
              let record = records.values.first(where: { $0.key == "note:companion/cards/\(card.id).md" }) else { return false }
        companionBusy = true; companionNotice = ""
        defer { companionBusy = false }
        do {
            let event = try CompanionEvent(cardId: card.id, action: action, text: text)
            try await workspace.respondCompanion(scope: scope, card: record, event: event)
            guard requestScope == scope else { return false }
            let saved = try event.record(); records[saved.documentID] = saved
            if let uid { try workspace.rememberSavedRecords(Array(records.values), uid: uid) }
            refreshCompanionNotifications()
            companionNotice = action == "answer" ? "Yanıt günlüğe eklendi. Telefonla analiz ekranından değerlendirebilirsin." : "Kaydedildi."
            if action == "answer" { await refreshFromFirebase(date:try CompanionReplyPlanner.date(event)) }
            return true
        } catch { companionNotice = "Gönderilemedi; yazdığın cevap korunuyor. Bağlantıyı kontrol edip yeniden dene."; return false }
    }

    func sendCommand(_ command: PhoneCommand) async throws {
        guard serverReady, networkAvailable, let workspace, let scope = requestScope else { throw WorkspaceConnectionError.rejected }
        try await workspace.sendCommand(scope: scope, command: command)
        guard requestScope == scope else { throw WorkspaceRequestError.accountChanged }
        let record = try command.record(); records[record.documentID] = record
        if let uid { try workspace.rememberSavedRecords(Array(records.values), uid: uid) }
    }

    @Published private(set) var mapLinkBusy = false
    @Published private(set) var mapLinkNotice = ""
    func beginMapLinkQuestions(nodes: [MobileAtlas.Node]) async -> String? {
        guard nodes.count >= 2, nodes.count <= 30 else { mapLinkNotice = "Birlikte değerlendirmek için 2–30 düşünce seç."; return nil }
        guard !experienceBusy, !mapLinkBusy, !phoneAnalysisBusy, let uid, let workspace, let scope = requestScope, let runtime = phoneRuntime,
              serverReady, networkAvailable else { mapLinkNotice = "Bağlantını kontrol et; başka analiz varsa bitmesini bekle."; return nil }
        let day = JournalCalendar.key(Date()), activeSession = session
        guard !isDirty(date: day), !busyDates.contains(day) else { mapLinkNotice = "Bugünkü yazını ve yanıt taslaklarını önce kaydet."; return nil }
        mapLinkBusy = true; busyDates.insert(day); mapLinkNotice = "Seçtiğin düşünceler için 3 yazılı ve 3 evet/hayır sorusu hazırlanıyor…"
        defer {
            mapLinkBusy = false
            if session == activeSession { busyDates.remove(day) }
        }
        do {
            guard await ChatGPTConnection.shared.prepareForAnalysis() else { mapLinkNotice = ChatGPTConnection.shared.notice; return nil }
            guard session == activeSession, requestScope == scope else { return nil }
            let source = try await workspace.fetch(uid: uid, date: day)
            if let source {
                let value = try source.payload().object
                if value?["map_link_session"]?.object?["phase"] == .string("answering") {
                    mapLinkNotice = "Devam eden harita sorularını açıyorum. Yeni bir alan için önce bu turu tamamla."
                    return day
                }
                if let status = value?["daily_task"]?.object?["status"]?.string, ["needs_input", "in_progress"].contains(status) {
                    mapLinkNotice = "Bugünkü araştırma veya görevin sorularını önce tamamla."
                    return nil
                }
            }
            let journal: JSONValue
            if let source { journal = try source.payload() }
            else {
                journal = try WorkspaceSavePlanner.plan(current: nil, expectedHash: nil, date: day,
                    text: "Seçtiğim düşünceler arasındaki ilişkileri geliştirmek istiyorum.", answers: [:],
                    now: ISO8601DateFormatter().string(from: Date()), newID: UUID().uuidString.lowercased()).record.payload()
            }
            let data = JSONValue.array(nodes.map { node in .object([
                "id": .string(node.id), "label": .string(node.label), "summary": .string(node.summary),
                "topicPath": .array(node.topicPath.map(JSONValue.string))
            ]) })
            let account = ChatGPTConnection.shared.registrationID
            let prompts = try await workspace.fetchAnalysisPrompts(scope: scope)
            let result = try await runtime.mapQuestions(model: ChatGPTConnection.shared.model, reasoningEffort: ChatGPTConnection.shared.selectedReasoning, nodes: data, prompts: prompts)
            guard session == activeSession, requestScope == scope, account == ChatGPTConnection.shared.registrationID else { return nil }
            let args = try JSONValue.object(["journal": journal, "nodeIDs": .array(nodes.map { .string($0.id) }),
                "result": result, "sessionID": .string(UUID().uuidString.lowercased()),
                "now": .string(ISO8601DateFormatter().string(from: Date()))]).canonical()
            guard let output = try JSONValue.parse(AnalysisCore.invoke("installMapQuestions", json: args)).object,
                  let payload = output["journal"], let rawCards = output["cards"]?.array else { throw AnalysisCoreError.invalidOutput }
            let record = try WorkspaceRecord.make(key: "journal:" + day, kind: .journal, payload: payload)
            let cards = try rawCards.map { value -> WorkspaceRecord in
                guard let row = value.object, let key = row["key"]?.string, let content = row["content"]?.string else { throw AnalysisCoreError.invalidOutput }
                return try WorkspaceRecord.make(key: key, kind: .note, payload: JSONValue.parse(content))
            }
            let saved = try await workspace.saveMapLinkJournal(scope: scope, record: record, expectedHash: source?.hash, cards: cards)
            guard session == activeSession, requestScope == scope else { return nil }
            records[saved.documentID] = saved
            for card in cards { records[card.documentID] = card }
            if var draft = drafts[day], !draft.hasChanges { draft.receive(saved); drafts[day] = draft }
            try workspace.rememberSavedRecords(Array(records.values), uid: uid)
            refreshCompanionNotifications()
            mapLinkNotice = "Sorular hazır. Cevaplarını analiz ettiğinde desteklenen bağlantılar haritaya eklenecek."
            return day
        } catch {
            guard session == activeSession else { return nil }
            ChatGPTConnection.shared.recordFailure(error)
            mapLinkNotice = (error as? WorkspaceError) == .conflict
                ? "Günlük başka cihazda değişti. Seçimin korunuyor; güncel kayıtla yeniden dene."
                : "Harita soruları hazırlanamadı: " + ChatGPTConnection.message(error)
            return nil
        }
    }

    #if DEBUG
    private func useFirstNoteDraftPreview() {
        let date = Self.today
        guard let uid, let record = records.removeValue(forKey: WorkspaceHash.sha256("journal:" + date)),
              let journal = try? record.journal() else { return }
        var draft = WorkspaceDraft(uid: uid, date: date, base: nil)
        if !journal.rawText.isEmpty { draft.text = journal.rawText }
        drafts[date] = draft
    }
    #endif

    func open(date: String, retry: Bool = false) {
        guard let uid, drafts[date] == nil, retry || !unreadableDraftDates.contains(date) else { return }
        guard let draftStore else { return }
        do {
            drafts[date] = try draftStore.load(uid: uid, date: date) ?? WorkspaceDraft(uid: uid, date: date, base: records[WorkspaceHash.sha256("journal:\(date)")])
            if unreadableDraftDates.contains(date) { unreadableDraftDates.remove(date) }
        } catch {
            if !unreadableDraftDates.contains(date) { unreadableDraftDates.insert(date) }
        }
    }

    func canEdit(date: String) -> Bool { canEdit && !unreadableDraftDates.contains(date) }

    func isJournalSavedOnDevice(date: String) -> Bool {
        workspace?.store.record("journal:\(date)") != nil
    }

    func isJournalSynced(date: String) -> Bool {
        cloudConnected && cloudVerified && isJournalSavedOnDevice(date: date)
            && workspace?.store.hasPendingPublication(key: "journal:\(date)") == false
    }

    func journal(date: String) -> JournalDocument? {
        let remote = records[WorkspaceHash.sha256("journal:\(date)")]
        let draft = drafts[date]
        if let draft, !draft.closedQuestionIDs.isEmpty {
            return JournalPresentation.current(remote: remote, draft: draft)
        }
        return journalMemo.value(for: remote ?? draft?.base) { try $0.journal() }
    }

    func text(date: String) -> String {
        if let text = drafts[date]?.text { return text }
        if let base = journalMemo.value(for: drafts[date]?.base, decode: { try $0.journal() }) {
            return base.rawText
        }
        return journal(date: date)?.rawText ?? ""
    }
    func pendingAnswer(date: String, id: String) -> DraftAnswer? { drafts[date]?.answers[id] }
    func isDirty(date: String) -> Bool { drafts[date]?.hasChanges == true }
    func remoteChanged(date: String) -> Bool {
        guard let draft = drafts[date], draft.hasChanges else { return false }
        return draft.requiresComparison || draft.base?.hash != records[WorkspaceHash.sha256("journal:\(date)")]?.hash
    }

    func requestBlock(date: String, kind: WorkspaceAnalysisKind) -> WorkspaceRequestBlock? {
        guard let uid else { return .accountChanged }
        return WorkspaceRequestEligibility.block(uid: uid, date: date, record: records[WorkspaceHash.sha256("journal:\(date)")],
                                                  draft: drafts[date], kind: kind,
                                                  serverReady: serverReady && requestsReady, networkAvailable: networkAvailable)
    }

    func analysisRequest(date: String, kind: WorkspaceAnalysisKind) -> WorkspaceAnalysisRequest? {
        guard requestsReady, !isDirty(date: date), let record = records[WorkspaceHash.sha256("journal:\(date)")] else { return nil }
        return WorkspaceAnalysisRequest.latest(Array(requests.values), for: record, kind: kind)
    }

    func requestNotice(date: String, kind: WorkspaceAnalysisKind) -> String? {
        guard !isDirty(date: date), let id = currentRequestID(date: date, kind: kind) else { return nil }
        return requestNotices[id]
    }

    func requestNeedsRetry(date: String, kind: WorkspaceAnalysisKind) -> Bool {
        let status = analysisRequest(date: date, kind: kind)?.status
        let failed = currentRequestID(date: date, kind: kind).map { requestFailures.contains($0) } ?? false
        return failed || status == .failed || status == .stale
    }

    func canRequestAnalysis(date: String, kind: WorkspaceAnalysisKind) -> Bool {
        guard requestScope != nil, requestBlock(date: date, kind: kind) == nil, !busyDates.contains(date) else { return false }
        if let status = analysisRequest(date: date, kind: kind)?.status,
           status == .queued || status == .processing || status == .complete { return false }
        return true
    }

    private func currentRequestID(date: String, kind: WorkspaceAnalysisKind) -> String? {
        guard let record = records[WorkspaceHash.sha256("journal:\(date)")] else { return nil }
        return try? WorkspaceAnalysisRequest.identity(kind: kind, sourceHash: record.hash)
    }

    func requestAnalysis(date: String, kind: WorkspaceAnalysisKind) async {
        guard let uid, let workspace, let scope = requestScope, scope.uid == uid,
              scope.session == session, scope.generation == listenerGeneration,
              activeAccountMatches(uid), canRequestAnalysis(date: date, kind: kind),
              let source = records[WorkspaceHash.sha256("journal:\(date)")],
              let id = currentRequestID(date: date, kind: kind) else { return }
        let activeSession = session
        busyDates.insert(date)
        requestNotices[id] = "İstek gönderiliyor; Firebase sunucusunun onayı bekleniyor…"
        requestFailures.remove(id)
        defer { if session == activeSession { busyDates.remove(date) } }
        do {
            _ = try await workspace.enqueue(scope: scope, source: source, kind: kind)
            guard self.uid == uid, session == activeSession, requestScope == scope,
                  listenerGeneration == scope.generation, activeAccountMatches(uid) else { return }
            // No optimistic queued/complete status: only the transaction acknowledgement
            // produces this notice; the listener remains the source of request state.
            requestNotices[id] = "İstek Firebase sunucusunda onaylandı. Güncel aşama durum bağlantısından izleniyor."
        } catch {
            guard self.uid == uid, session == activeSession, requestScope == scope,
                  listenerGeneration == scope.generation, activeAccountMatches(uid) else { return }
            requestFailures.insert(id)
            requestNotices[id] = (error as? WorkspaceRequestError) == .sourceChanged
                ? "Sunucudaki günlük değişmiş; istek gönderilmedi. Güncel kaydı açıp yeniden dene. Kaydın ve taslağın korundu."
                : "Analiz isteği sunucuda onaylanmadı. Kaydedilmiş günlüğün korundu; bağlantını kontrol edip yeniden dene."
        }
    }

    func editText(date: String, text: String) {
        guard canEdit(date: date) else { return }
        open(date: date)
        guard var draft = drafts[date], draft.uid == uid else { return }
        let previous = draft.text
        let wasWritable = previous?.contains { !$0.isWhitespace } ?? false
        let writable = text.contains { !$0.isWhitespace }
        let bucketChanged = DailyWritingProgress.characterCount(in: previous ?? "", upTo: 1_200) / 24
            != DailyWritingProgress.characterCount(in: text, upTo: 1_200) / 24
        draft.text = text
        persist(draft, publish: previous == nil || previous?.isEmpty != text.isEmpty || wasWritable != writable || bucketChanged)
    }

    func updateInlineNote(date: String, note: InlineJournalDraft?) {
        guard canEdit(date: date) else { return }
        open(date: date)
        guard var draft = drafts[date], draft.uid == uid else { return }
        let hadNote = draft.inlineNote != nil
        draft.inlineNote = note
        persist(draft, publish: hadNote != (note != nil))
    }

    func appendInlineNote(date: String, text note: String) -> Bool {
        guard canEdit(date: date), !phoneAnalysisBusy, !busyDates.contains(date),
              var draft = drafts[date], draft.uid == uid, note.contains(where: { !$0.isWhitespace }) else { return false }
        draft.inlineNote = InlineJournalDraft(text: note, editingTextHash: nil)
        do {
            try draft.applyInlineNote(to: text(date: date))
            try writeDraftNow(draft)
            drafts[date] = draft
            return true
        } catch {
            message = "Taslak diske yazılamadı; uygulamayı kapatmadan tekrar dene."
            return false
        }
    }

    func editAnswer(date: String, id: String, answer: DraftAnswer, savedText: String? = nil) {
        guard canEdit(date: date) else { return }
        open(date: date)
        guard var draft = drafts[date], draft.uid == uid else { return }
        let previous = draft.answers.updateValue(answer, forKey: id)
        guard previous != answer else { return }
        // UITextView displays the live text. Keep every keystroke available for
        // saving and analysis, and refresh the workspace only when readiness changes.
        if case .text(let old) = previous, case .text(let new) = answer {
            let wasAnswered = old?.contains { !$0.isWhitespace } == true
            let isAnswered = new?.contains { !$0.isWhitespace } == true
            let saved = savedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let changedFromSaved = !saved.isEmpty &&
                (old?.trimmingCharacters(in: .whitespacesAndNewlines) == saved) !=
                (new?.trimmingCharacters(in: .whitespacesAndNewlines) == saved)
            persist(draft, publish: wasAnswered != isAnswered || old?.isEmpty != new?.isEmpty || changedFromSaved)
        } else {
            persist(draft)
        }
    }

    private func persist(_ draft: WorkspaceDraft, publish: Bool = true) {
        guard let draftStore else { return }
        let date = draft.date
        if publish { objectWillChange.send() }
        if draftStorage[date]?.closedQuestionIDs != draft.closedQuestionIDs || draftStorage[date]?.base?.hash != draft.base?.hash {
            cachedPendingQuestionCount = nil
        }
        draftStorage[date] = draft
        let version = UUID()
        pendingDraftWrites[date] = version
        // Flush the latest value at a bounded interval even during continuous typing.
        guard draftWriteTasks[date] == nil else { return }
        draftWriteTasks[date] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let latest = self.draftStorage[date],
                  let latestVersion = self.pendingDraftWrites[date] else { return }
            self.draftWriteTasks.removeValue(forKey: date)
            draftStore.saveInBackground(latest) { [weak self] saved in
                Task { @MainActor in self?.finishDraftWrite(date: date, version: latestVersion, saved: saved) }
            }
        }
    }

    private func finishDraftWrite(date: String, version: UUID, saved: Bool) {
        guard pendingDraftWrites[date] == version else { return }
        draftWriteTasks.removeValue(forKey: date)
        if saved { pendingDraftWrites.removeValue(forKey: date) }
        let status = saved ? "Taslak bu cihazda korundu. Henüz günlük kaydına uygulanmadı."
            : "Taslak diske yazılamadı; uygulamayı kapatmadan tekrar dene."
        if message != status { message = status }
    }

    private func writeDraftNow(_ draft: WorkspaceDraft) throws {
        guard let draftStore else { throw WorkspaceError.invalidDraft }
        draftWriteTasks.removeValue(forKey: draft.date)?.cancel()
        try draftStore.save(draft)
        pendingDraftWrites.removeValue(forKey: draft.date)
    }

    @discardableResult
    func flushDraftWrites(date: String? = nil) -> Bool {
        let dates = date.map { [$0] } ?? Array(pendingDraftWrites.keys)
        var saved = true
        for date in dates {
            guard pendingDraftWrites[date] != nil, let draft = drafts[date] else { continue }
            do { try writeDraftNow(draft) }
            catch {
                message = "Taslak diske yazılamadı; uygulamayı kapatmadan tekrar dene."
                saved = false
            }
        }
        return saved
    }

    private func removeDraftFile(uid: String, date: String) throws {
        draftWriteTasks.removeValue(forKey: date)?.cancel()
        try draftStore?.remove(uid: uid, date: date)
        pendingDraftWrites.removeValue(forKey: date)
    }

    func saveText(date: String) async {
        open(date: date)
        guard let draft = drafts[date], let text = draft.text else { return }
        await save(date: date, text: text, answers: [:], expectedHash: draft.base?.hash)
    }

    func saveAnswer(date: String, id: String) async {
        guard let draft = drafts[date], let answer = draft.answers[id] else { return }
        await save(date: date, text: nil, answers: [id: answer], expectedHash: draft.base?.hash)
    }

    func submitQuestionAnswers(date: String) {
        guard let journal = journal(date: date) else { return }
        let ids = journal.questions.filter { $0.isAnswered || drafts[date]?.answers[$0.id] != nil }.map(\.id)
        guard !ids.isEmpty else { return }
        phoneAnalysisDate = date
        phoneAnalysisNotice = "Yanıtların kaydediliyor…"
        Task { await closeQuestionSession(date: date, questionIDs: ids) }
    }

    func skipDayReflectionQuestions(date: String) {
        guard canEdit(date: date), !canStartQuestionAnalysis(date: date),
              !phoneAnalysisBusy, !phoneMemoryBusy, !mapLinkBusy,
              let journal = journal(date: date), journal.awaitsDayReflectionQuestions else { return }
        let ids = journal.questions.filter { !$0.isFunctional }.map(\.id)
        Task { await closeQuestionSession(date: date, questionIDs: ids) }
    }

    func closeQuestionSession(date: String, questionIDs: [String]) async {
        guard !questionIDs.isEmpty else { return }
        functionalRetryAfter.removeValue(forKey: date)
        open(date: date)
        guard var draft = drafts[date] else { return }
        let saved = try? records[WorkspaceHash.sha256("journal:\(date)")]?.journal()
        draft.closeQuestions(questionIDs, in: saved)
        guard !draft.closedQuestionIDs.isEmpty else { await flushClosedQuestionSessions(); return }
        persist(draft)
        guard flushDraftWrites(date: date) else {
            phoneAnalysisNotice = "Taslak diske yazılamadı. Yeniden dene."
            return
        }
        await flushClosedQuestionSessions()
    }

    func flushClosedQuestionSessions() async {
        guard serverReady, UIApplication.shared.applicationState == .active, !phoneAnalysisBusy, !phoneMemoryBusy, !mapLinkBusy, conflict == nil else { return }
        resumeInterruptedAnalysis()
        guard !phoneAnalysisBusy else { return }
        let owner = uid
        // Recover a close/save that succeeded just before the app was suspended or terminated.
        let functionalDates = records.values.compactMap { record -> String? in
            guard record.kind == .journal, let journal = try? record.journal(),
                  journal.questions.contains(where: { $0.isSessionClosed && $0.hasPendingFunctionalAnswer }) else { return nil }
            return journal.date
        }.sorted()
        for date in functionalDates {
            guard uid == owner, await applyFunctionalAnswers(date: date) else { return }
        }
        for date in drafts.keys.sorted() {
            guard uid == owner, conflict == nil else { return }
            guard let draft = drafts[date], !draft.requiresComparison, (!draft.closedQuestionIDs.isEmpty || draft.analyzeAfterClose), !busyDates.contains(date) else { continue }
            let expected = draft.text == nil && draft.answers.isEmpty
                ? records[WorkspaceHash.sha256("journal:\(date)")]?.hash : draft.base?.hash
            if draft.hasChanges { await save(date: date, text: draft.text, answers: draft.answers, expectedHash: expected) }
            guard uid == owner, !phoneAnalysisBusy, !mapLinkBusy, !phoneMemoryBusy, serverReady,
                  workspace != nil, requestScope != nil, UIApplication.shared.applicationState == .active else { return }
            guard drafts[date]?.hasChanges == false, conflict == nil else { continue }
            if journal(date: date)?.questions.contains(where: \.hasPendingFunctionalAnswer) == true {
                guard await applyFunctionalAnswers(date: date) else { return }
            }
            guard var saved = drafts[date], !saved.hasChanges, saved.analyzeAfterClose, conflict == nil else { continue }
            guard networkAvailable else { continue }
            // Consume before dispatch: callbacks cannot enqueue this session twice.
            saved.analyzeAfterClose = false
            do { try writeDraftNow(saved) }
            catch { message = "Analiz isteği cihazda saklanamadı; yanıtların korunuyor."; return }
            drafts[date] = saved
            startPhoneAnalysis(date: date)
            return
        }
    }

    private func save(date: String, text: String?, answers: [String: DraftAnswer], expectedHash: String?, explicitlyCompared: Bool = false, closeQuestionSession: Bool = false, restoring: WorkspaceRecord? = nil) async {
        guard let uid, let workspace, let draft = drafts[date], !busyDates.contains(date) else { return }
        do { try writeDraftNow(draft) }
        catch { message = "Taslak güvenle saklanamadı; buluta yazılmadı."; return }
        let activeSession = session
        let originalRemoteHash = records[WorkspaceHash.sha256("journal:\(date)")]?.hash
        busyDates.insert(date)
        defer { if session == activeSession { busyDates.remove(date) } }
        do {
            // Retained edits after a partial override need their own comparison before any write.
            try draft.checkSubmission(explicitlyCompared: explicitlyCompared)
            let saved = try await workspace.save(uid: uid, date: date, expectedHash: expectedHash, text: text, answers: answers, closeQuestionSession: closeQuestionSession, closedQuestionIDs: draft.closedQuestionIDs, restoring: restoring)
            guard session == activeSession, self.uid == uid else { return }
            connectionDiagnostic = nil
            // A newer realtime snapshot can arrive before this completion callback.
            // Never roll it back to the earlier transaction result.
            let latest = records[saved.documentID]
            if latest?.hash == originalRemoteHash || latest?.hash == saved.hash { records[saved.documentID] = saved }
            var viewCacheFailed = false
            do { try workspace.rememberSavedRecords(Array(records.values), uid: uid) }
            catch { viewCacheFailed = true }
            refreshCompanionNotifications()
            if var remaining = drafts[date] {
                remaining.acknowledge(saved, submittedText: text, submittedAnswers: answers, expectedHash: expectedHash)
                if !remaining.hasChanges { remaining.receive(records[saved.documentID]) }
                drafts[date] = remaining
                do {
                    if remaining.needsPersistence { try writeDraftNow(remaining) }
                    else { try removeDraftFile(uid: uid, date: date) }
                    message = remaining.hasChanges ? "Gönderilen değişiklik cihazda kaydedildi. Diğer taslakların korunuyor." : "Cihaza kaydedildi. Bu, analizin tamamlandığı anlamına gelmez."
                } catch { message = "Sunucuda kaydedildi; cihazdaki taslak temizlenemedi. Tekrar açılışta çakışma kontrolü yapılacak." }
            }
            if viewCacheFailed { message = "Cihaza kaydedildi. Cihaz önbelleği yazılamadı; asıl kayıt korunuyor." }
        } catch {
            guard session == activeSession, self.uid == uid else { return }
            if (error as? WorkspaceError) == .conflict {
                do {
                    let server = try await workspace.fetch(uid: uid, date: date)
                    guard session == activeSession, self.uid == uid else { return }
                    if var pending = drafts[date] {
                        pending.markConflict()
                        persist(pending)
                    }
                    conflict = WorkspaceConflict(uid: uid, date: date, server: server, base: draft.base, text: text, answers: answers)
                    message = server == nil
                        ? "Sunucuda bu günlük bulunamadı. Telefonda saklanan günlük ve yanıtların korunuyor; birlikte geri yükleyebilirsin."
                        : "Sunucudaki kayıt ile taslağın farklı. Yerel metin ve yanıtların korunuyor."
                } catch {
                    guard session == activeSession, self.uid == uid else { return }
                    message = "Çakışma var; sunucu sürümü alınamadı. Taslağın korundu, bağlantı gelince tekrar dene."
                }
            } else {
                connectionDiagnostic = WorkspaceConnectionDiagnostic.firestore(error)
                message = "Günlük cihaz deposuna kaydedilemedi. Taslağın bu cihazda korunuyor. Bu işlem ChatGPT bağlantısından bağımsızdır."
            }
        }
    }

    func overwrite(_ comparison: WorkspaceConflict) async {
        // This hash came from an explicit server read. CAS repeats the comparison inside
        // the transaction; if the server changed again, a new comparison is required.
        guard uid == comparison.uid else { return }
        conflict = nil
        await save(date: comparison.date, text: comparison.text, answers: comparison.answers,
                   expectedHash: comparison.server?.hash, explicitlyCompared: true,
                   restoring: comparison.server == nil ? comparison.base : nil)
        if conflict == nil { await flushClosedQuestionSessions() }
    }

    func reloadServer(_ comparison: WorkspaceConflict) async {
        guard let uid, uid == comparison.uid, let workspace else { return }
        let activeSession = session
        let originalDraft = drafts[comparison.date]
        do {
            let latest = try await workspace.fetch(uid: uid, date: comparison.date)
            guard session == activeSession, self.uid == uid else { return }
            guard drafts[comparison.date] == originalDraft else {
                message = "Beklerken taslak değişti; yeni yazdıkların korunuyor. Yeniden karşılaştır."
                return
            }
            // A separate, unfinished note was never part of the submitted conflict.
            var replacement = WorkspaceDraft(uid: uid, date: comparison.date, base: latest)
            replacement.inlineNote = originalDraft?.inlineNote
            if replacement.needsPersistence { try writeDraftNow(replacement) }
            else { try removeDraftFile(uid: uid, date: comparison.date) }
            drafts[comparison.date] = replacement
            records[WorkspaceHash.sha256("journal:\(comparison.date)")] = latest
            conflict = nil
            message = "Bu günün yerel taslağı bırakıldı; güncel sunucu sürümü açıldı."
        } catch {
            guard session == activeSession, self.uid == uid else { return }
            message = "Sunucu sürümü yüklenemedi. Yerel taslak değiştirilmedi."
        }
    }
}


extension WorkspaceModel {
    var experience: WorkspaceExperience {
        experienceMemo.value(for: records[WorkspaceHash.sha256(WorkspaceExperience.key)]) {
            try WorkspaceExperience(record: $0)
        } ?? WorkspaceExperience()
    }
    var changeReceipts: [WorkspaceChangeReceipt] {
        if let cachedChanges { return cachedChanges }
        let changes = records.values.compactMap { try? WorkspaceChangeReceipt.decode($0) }
            .sorted { $0.createdAt > $1.createdAt }
        cachedChanges = changes
        return changes
    }
    func isKnownQuestion(_ prompt: String) -> Bool {
        let locale = Locale(identifier: "tr_TR")
        if knownQuestionTitles == nil {
            knownQuestionTitles = Set(experience.items.filter { $0.kind == "question_known" }.map {
                $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            })
        }
        return knownQuestionTitles?.contains(
            prompt.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        ) == true
    }
    func recordExperience(_ event: ExperienceEvent) async -> Bool {
        guard !experienceBusy,!phoneAnalysisBusy,let workspace,let scope=requestScope,serverReady else { experienceNotice="Bağlantıyı kontrol et ve devam eden işlemin bitmesini bekle.";return false }
        experienceBusy=true;experienceNotice=""
        defer { if requestScope == scope { experienceBusy=false } }
        do {
            let record=try await workspace.recordExperience(event,scope:scope)
            guard requestScope == scope else { return false }
            records[record.documentID]=record
            try workspace.rememberSavedRecords(Array(records.values),uid:scope.uid)
            experienceNotice="Kaydedildi. Sonraki analiz bu yanıtı dikkate alacak."
            refreshCompanionNotifications()
            return true
        }catch{if requestScope == scope { experienceNotice="Kaydedilemedi; yeniden deneyebilirsin." };return false}
    }
    func markQuestionKnown(_ event:ExperienceEvent,question:JournalQuestion,date:String) async -> Bool {
        let owner=uid
        guard await recordExperience(event),uid == owner else {return false}
        open(date:date)
        guard var draft=drafts[date],let saved=journal(date:date) else {return true}
        draft.closeQuestions([question.id],in:saved)
        draft.analyzeAfterClose=false
        persist(draft)
        await save(date:date,text:draft.text,answers:draft.answers,expectedHash:draft.base?.hash)
        return uid == owner
    }
    /// Reuses the journal CAS and version archive, preserving all unknown payload fields.
    func saveEmotionCorrection(date: String, observation: EmotionObservation, choices: [String]) async -> Bool {
        guard !isDirty(date: date), let journal = journal(date: date),
              let day = emotionDays.first(where: { $0.date == date }),
              let original = day.originalObservations.first(where: { $0.id == observation.correctionID }) else {
            experienceNotice = "Günlük değişmiş. Güncel analizi açıp yeniden dene."; return false
        }
        let previous = journal.payload.object?["emotion_observation_overrides"]?.object
        var edits = previous?["source_hash"]?.string == day.sourceFingerprint ? previous?["edits"]?.array ?? [] : []
        if previous?["source_hash"]?.string != day.sourceFingerprint,
           let legacy = journal.payload.object?["emotion_override"]?.object,
           legacy["source_hash"]?.string == day.sourceFingerprint {
            let selected = Set(legacy["choices"]?.array?.compactMap(\.string).map(EmotionDefinition.canonical) ?? [])
            edits = day.originalObservations.map { item in .object([
                "observation_id": .string(item.id), "original_key": .string(item.key), "quote": .string(item.quote),
                "sequence": .number(Double(item.sequence)), "choices": .array(selected.contains(item.key) ? [.string(item.key)] : [])]) }
        }
        edits.removeAll { $0.object?["observation_id"]?.string == original.id }
        edits.append(.object(["observation_id": .string(original.id), "original_key": .string(original.key),
            "quote": .string(original.quote), "sequence": .number(Double(original.sequence)),
            "choices": .array(Array(Set(choices)).sorted().map(JSONValue.string))]))
        return await saveJournalDecoration(date: date, field: "emotion_observation_overrides",
            value: .object(["source_hash": .string(day.sourceFingerprint), "edits": .array(edits)]))
    }
    func saveJournalDecoration(date: String, field: String, value: JSONValue) async -> Bool {
        guard ["emotion_override", "emotion_observation_overrides"].contains(field),
              !phoneAnalysisBusy, !mapLinkBusy, !phoneMemoryBusy, !experienceBusy,
              let workspace, let scope = requestScope, serverReady else { return false }
        if isDirty(date: date) { await saveText(date: date) }
        guard requestScope == scope, !phoneAnalysisBusy, !mapLinkBusy, !phoneMemoryBusy, !experienceBusy,
              !isDirty(date: date), let previous = records[WorkspaceHash.sha256("journal:" + date)],
              let journal = try? previous.journal(), var payload = journal.payload.object else { return false }
        guard value.object?["source_hash"]?.string == WorkspaceHash.sha256(journal.rawText) else { return false }
        experienceBusy = true
        defer { if requestScope == scope { experienceBusy = false } }
        do {
            payload[field] = value
            let record = try WorkspaceRecord.make(key: previous.key, kind: .journal, payload: .object(payload))
            let saved = try await workspace.saveMapLinkJournal(scope: scope, record: record, expectedHash: previous.hash, cards: [])
            guard requestScope == scope else { return false }
            if records[saved.documentID]?.hash == previous.hash { records[saved.documentID] = saved }
            try workspace.rememberSavedRecords(Array(records.values), uid: scope.uid)
            if var draft = drafts[date], !draft.hasChanges { draft.receive(saved); persist(draft) }
            experienceNotice = "Kaydedildi."
            return true
        } catch {
            if requestScope == scope {
                experienceNotice = "Kaydedilemedi. Kayıt başka cihazda değişmiş veya bağlantı kesilmiş olabilir."
            }
            return false
        }
    }

    func correctNode(id: String,text: String,verdict: String) async -> Bool {
        guard !experienceBusy,!phoneAnalysisBusy,!mapLinkBusy,!phoneMemoryBusy,let workspace,let scope=requestScope,serverReady else { experienceNotice="Bağlantını ve devam eden işlemleri kontrol et.";return false }
        experienceBusy=true;experienceNotice=""
        defer { if requestScope == scope { experienceBusy=false } }
        do {
            let (memory,manifest)=try await workspace.fetchMemory(scope:scope)
            guard let memory,requestScope == scope else { throw WorkspaceError.conflict }
            let plan=try WorkspaceMemoryMutation(before:memory,expectedManifest:manifest,action:"correct",nodeID:id,text:text,verdict:verdict)
            try await workspace.commitMemoryEdit(plan,scope:scope)
            guard requestScope == scope else { return false }
            await acceptMemoryEdit(plan,scope:scope)
            guard requestScope == scope else {return false}
            experienceNotice="Düzeltmen Cihaza kaydedildi. Sonraki analizlerde önceliklidir."
            return true
        }catch{if requestScope == scope { experienceNotice="Düzeltme kaydedilemedi. Harita değişmiş veya bağlantı kesilmiş olabilir; yazdığın metin korunuyor." };return false}
    }
    func undoAnalysis(_ receipt: WorkspaceChangeReceipt) async -> Bool {
        guard receipt.undone != true,!experienceBusy,!phoneAnalysisBusy,!mapLinkBusy,!phoneMemoryBusy,!isDirty(date:receipt.date),let workspace,let scope=requestScope,serverReady else { experienceNotice="Taslağını kaydet ve devam eden işlemin bitmesini bekle.";return false }
        experienceBusy=true;experienceNotice=""
        defer { if requestScope == scope { experienceBusy=false } }
        do {
            let (current,manifest)=try await workspace.fetchMemory(scope:scope)
            guard let current,current.contentHash == receipt.memoryHash,
                  let journal=try await workspace.fetch(uid:scope.uid,date:receipt.date),journal.hash == receipt.resultHash,
                  let receiptRecord=records.values.first(where:{$0.key == "note:companion/changes/"+receipt.id+".json"}) else { throw WorkspaceError.conflict }
            let prior:PortableMemory
            if receipt.priorManifest == .null { prior=try PortableMemory(json:AnalysisCore.invoke("emptyMemory",json:"{}")) }
            else {
                let priorManifest=try WorkspaceRecord(json:receipt.priorManifest)
                guard let value=try await workspace.fetchMemoryManifest(priorManifest,scope:scope) else { throw WorkspaceError.conflict }
                prior=value
            }
            let oldJournal=try await workspace.fetchVersion(key:journal.key,hash:receipt.sourceHash,scope:scope)
            guard let receiptText=try receiptRecord.payload().string,var row=try JSONValue.parse(receiptText).object else { throw WorkspaceError.malformedRecord }
            row["undone"] = .bool(true)
            let updatedReceipt=try WorkspaceRecord.make(key:receiptRecord.key,kind:.note,payload:.string(JSONValue.object(row).canonical()))
            var additional=[oldJournal,updatedReceipt]
            if let card=records.values.first(where:{$0.key == "note:companion/cards/journal_questions_"+receipt.date+".md"}),
               let text=try card.payload().string,var fields=try JSONValue.parse(text).object {
                fields["withdrawn"] = .bool(true)
                additional.append(try WorkspaceRecord.make(key:card.key,kind:.note,payload:.string(JSONValue.object(fields).canonical())))
            }
            let plan=try WorkspaceMemoryMutation(before:current,expectedManifest:manifest,action:"rollback",prior:prior,additional:additional,expectedRecords:[journal,receiptRecord])
            try await workspace.commitMemoryEdit(plan,scope:scope)
            guard requestScope == scope else { return false }
            await acceptMemoryEdit(plan,scope:scope)
            if var draft=drafts[receipt.date],!draft.hasChanges { draft.receive(oldJournal);persist(draft) }
            guard requestScope == scope else {return false}
            phoneAnalysisChanges=nil;phoneAnalysisReply=nil
            experienceNotice="Son analiz geri alındı. Günlük metnin ve işlem geçmişin korunuyor."
            return true
        }catch{if requestScope == scope { experienceNotice="Geri alınmadı: analizden sonra başka bir değişiklik yapılmış veya bağlantı kesilmiş olabilir. Güncel kayıtların korunuyor." };return false}
    }
    private func acceptMemoryEdit(_ plan: WorkspaceMemoryMutation,scope:WorkspaceRequestScope) async {
        guard requestScope == scope,let workspace else { return }
        for record in plan.records+[plan.manifest] { records[record.documentID]=record }
        try? workspace.rememberMemoryEdit(Array(records.values),uid:scope.uid)
        if let memoryScope=try? MemoryScope(projectID:firebaseProjectID,uid:scope.uid),
           let store=try? MemoryStore(root:URL.applicationSupportDirectory.appendingPathComponent("DailyXMemory")) {
            let local=try? await store.load(scope:memoryScope)
            try? await store.save(plan.memory,expectedHash:local?.contentHash,scope:memoryScope)
        }
        refreshCompanionNotifications()
    }
}


extension WorkspaceModel {
    func testLocalNotification() async {
        guard uid != nil else { experienceNotice="Önce kendi hesabına giriş yap.";return }
        let owner=companionScope
        do {
            try await companionNotifications.scheduleTest(scope:owner)
            guard companionScope == owner else {return}
            experienceNotice="10 saniye sonrasına yerel deneme bildirimi planlandı. Uygulamayı arka plana alıp kontrol et. Bu test sunucudan push teslimatını doğrulamaz."
            await refreshNotificationStatus()
        }catch{if companionScope == owner {experienceNotice="Deneme bildirimi planlanamadı. iPhone bildirim iznini kontrol et."}}
    }
}


extension WorkspaceModel {
    func saveNotificationLimit(_ limit:Int,hour:Int) async {
        guard !experienceBusy,let workspace,let scope=requestScope,serverReady else {return}
        experienceBusy=true
        defer{if requestScope == scope {experienceBusy=false}}
        do {
            let record=try await workspace.saveNotificationLimit(limit,hour:hour,scope:scope)
            guard requestScope == scope else {return}
            records[record.documentID]=record
            try workspace.rememberSavedRecords(Array(records.values),uid:scope.uid)
            refreshCompanionNotifications()
            experienceNotice="Günlük bildirim sınırın kaydedildi."
        }catch{if requestScope == scope {experienceNotice="Bildirim tercihi kaydedilemedi; yeniden dene."}}
    }
}
