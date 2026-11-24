import SwiftUI
import DailyCore

struct QuestionDestination: Identifiable, Hashable {
    let date: String
    var showAnswered = false
    var id: String { date }
}

struct QuestionsScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @State private var answered = false
    private var journals: [JournalDocument] { model.dates.compactMap { model.journal(date: $0) } }
    private func displayedQuestions(_ journal: JournalDocument) -> [JournalQuestion] {
        answered ? journal.questions.filter { $0.isAnswered || $0.isSessionClosed || model.isKnownQuestion($0.prompt) } + journal.archivedAnsweredQuestions : journal.pendingQuestions.filter { !model.isKnownQuestion($0.prompt) }
    }
    var body: some View {
        let journals = self.journals
        let count = journals.flatMap(\.pendingQuestions).filter { !model.isKnownQuestion($0.prompt) }.count
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                DailySectionHeading(eyebrow: "Kendine bir adım daha", title: "Birlikte netleştirelim.", detail: count > 0 ? "\(count) soru hazır. İstediğin kadarını yanıtla." : "Günlüğünden doğan sorular ve kaydettiğin yanıtlar burada.")
                if model.checkingFirebase {
                    ProgressView("Güncel sorular Firebase’den kontrol ediliyor…")
                }
                if let error = model.journalRefreshError {
                    Text(error).font(.footnote).foregroundStyle(DailyTheme.orange)
                    Button("Yeniden kontrol et") { Task { await model.refreshFromFirebase() } }
                        .buttonStyle(DailySecondaryButtonStyle()).disabled(model.checkingFirebase)
                }
                Picker("Soruları göster", selection: $answered) {
                    Text("Yanıt bekleyen").tag(false)
                    Text("Yanıtladıklarım").tag(true)
                }.pickerStyle(.segmented)
                ForEach(journals.filter { !displayedQuestions($0).isEmpty }, id: \.date) { journal in
                    NavigationLink(value: QuestionDestination(date: journal.date, showAnswered: answered)) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(journal.date).font(.caption.bold()).foregroundStyle(DailyTheme.cobalt)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            Text(displayedQuestions(journal).first?.prompt ?? "Günlüğünün soruları")
                                .font(.system(size: 20, weight: .semibold, design: .default)).foregroundStyle(DailyTheme.ink).multilineTextAlignment(.leading).lineLimit(3)
                            let selected = displayedQuestions(journal)
                            Text("\(selected.filter { $0.kind == .boolean }.count) evet/hayır · \(selected.filter { $0.kind == .open }.count) yazılı")
                                .font(.footnote).foregroundStyle(DailyTheme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).dailyGlass(accent: DailyTheme.energy)
                    }.buttonStyle(.plain).accessibilityIdentifier("questions-day-" + journal.date)
                }
                if !model.checkingFirebase && !journals.contains(where: { !displayedQuestions($0).isEmpty }) {
                    Label(answered ? "Kaydettiğin yanıtlar burada birikecek." : "Şimdilik yanıt bekleyen günlük sorusu yok.", systemImage: answered ? "text.bubble" : "checkmark.circle")
                        .foregroundStyle(DailyTheme.muted).dailyCard()
                }
                if !answered && journals.contains(where: { $0.payload.object?["map_link_session"] == nil && $0.payload.object?["daily_task"] == nil && $0.analysisStatus != "complete" }) {
                    Text("Bazı günlükler henüz analiz edilmedi. İlgili yazıyı açıp analizi başlatabilirsin.")
                        .font(.footnote).foregroundStyle(DailyTheme.muted)
                }
                NavigationLink { CompanionInboxScreen() } label: {
                    Label("Diğer takip konuları", systemImage: "sparkles")
                }.buttonStyle(DailySecondaryButtonStyle())
            }.padding(20)
        }.navigationTitle("Sorular").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: QuestionDestination.self) { destination in
                JournalQuestionsScreen(date: destination.date, showAnswered: destination.showAnswered)
            }
            .refreshable { await model.refreshFromFirebase() }
    }
}

struct JournalQuestionsScreen: View {
    let date: String
    var showAnswered = false
    @EnvironmentObject private var model: WorkspaceModel
    @State private var includeAnswered = false
    @State private var replyStatusOpen = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DailySectionHeading(eyebrow: date, title: showAnswered ? "Yanıtladıkların." : "Söz sende.", detail: showAnswered ? "Kaydettiğin cevaplar yeni analizlerden sonra da burada korunur." : "İstediğin soruları yanıtla. Hazır olduğunda üstteki Daily butonuna dokun.", showsEyebrow:true)
                if let error = model.journalRefreshError {
                    Text(error).font(.footnote).foregroundStyle(DailyTheme.orange)
                    Button("Soruları yeniden kontrol et") { Task { await model.refreshFromFirebase(date: date) } }
                }
                if model.remoteChanged(date: date) {
                    Text("Güncel sorular gösteriliyor. Eski yanıt taslakların korundu; kaydederken değişiklikleri karşılaştıracağız.").font(.footnote).foregroundStyle(DailyTheme.orange)
                }
                if let journal = model.journal(date: date) {
                    if journal.payload.object?["map_link_session"]?.object?["phase"] == .string("answering") {
                        Label("Seçtiğin düşüncelerin bağlarını yanıtlarınla netleştir. Analizi üstteki Daily butonundan başlat.", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.subheadline).foregroundStyle(DailyTheme.ink).dailyCard()
                    }
                    if let task = journal.payload.object?["daily_task"] {
                        TaskResultCard(task: task, showContinuation: false)
                    }
                    if !showAnswered { Toggle("Kaydedilmiş yanıtları da göster", isOn: $includeAnswered).font(.subheadline) }
                    let visible = journal.questions.filter { showAnswered ? ($0.isAnswered || $0.isSessionClosed || model.isKnownQuestion($0.prompt)) : (includeAnswered || (!model.isKnownQuestion($0.prompt) && (!$0.isAnswered && !$0.isSessionClosed) || model.pendingAnswer(date: date, id: $0.id) != nil)) }
                    let archived = (showAnswered || includeAnswered) ? journal.archivedAnsweredQuestions : []
                    if visible.isEmpty && archived.isEmpty {
                        Label(journal.payload.object?["daily_task"] != nil ? "Görev için bekleyen soru yok." : journal.questions.isEmpty ? (journal.analysisStatus == "complete" ? "Bu analizde ek soruya gerek görülmedi." : "Sorular analiz tamamlandığında görünür.") : "Bu soru oturumu tamamlandı.", systemImage: "checkmark.circle").dailyCard()
                    }
                    ForEach(visible.sorted { $0.kind == $1.kind ? $0.position < $1.position : $0.kind == .boolean }) { question in
                        if showAnswered {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(question.prompt).font(.headline)
                                Text(model.isKnownQuestion(question.prompt) ? "Daha önce belirtildi · yeniden sorulmasın" : !question.isAnswered ? "Boş bırakıldı" : question.kind == .boolean ? (question.answerBoolean == 1 ? "Evet" : "Hayır") : (question.answerText ?? ""))
                                    .textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).dailyCard()
                        } else { QuestionEditor(date: date, question: question) { replyStatusOpen = true } }
                    }
                    if !archived.isEmpty {
                        Text("Önceki analizlerde yanıtladıkların").font(.headline).foregroundStyle(DailyTheme.ink)
                        ForEach(archived) { question in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(question.prompt).font(.headline).foregroundStyle(DailyTheme.ink)
                                Text(model.isKnownQuestion(question.prompt) ? "Daha önce belirtildi · yeniden sorulmasın" : !question.isAnswered ? "Boş bırakıldı" : question.kind == .boolean ? (question.answerBoolean == 1 ? "Evet" : "Hayır") : (question.answerText ?? ""))
                                    .font(.body).foregroundStyle(DailyTheme.ink).textSelection(.enabled)
                                Label(question.isAnswered ? "Kaydedilmiş yanıt" : "Tamamlanan oturum · Boş bırakıldı", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(DailyTheme.cobalt)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(20).dailyGlass(accent: DailyTheme.energy)
                        }
                    }
                    if let orphaned = model.drafts[date]?.answers.keys.filter({ id in !journal.questions.contains { $0.id == id } }), !orphaned.isEmpty {
                        Text("\(orphaned.count) eski yanıt taslağın korunuyor; soru değiştiği için otomatik gönderilmedi.").font(.footnote).foregroundStyle(DailyTheme.orange)
                    }
                    if let results = journal.payload.object?["reminder_results"]?.array {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                            if let text = result.string { Label(text, systemImage: "bell").font(.footnote).foregroundStyle(DailyTheme.ink) }
                        }
                    }
                    if journal.awaitsDayReflectionQuestions && !showAnswered && !model.canStartQuestionAnalysis(date: date) {
                        Button("Soruları geç ve yorumu oku") { model.skipDayReflectionQuestions(date: date) }
                        .buttonStyle(DailySecondaryButtonStyle())
                        .disabled(!model.canEdit(date: date) || !model.serverReady ||
                            model.phoneAnalysisBusy || model.phoneMemoryBusy || model.mapLinkBusy || model.busyDates.contains(date))
                        .accessibilityIdentifier("journal-finish-reflection-questions")
                    }
                    if let reflection = journal.dayReflection {
                        JournalReflectionButton(date: date, reflection: reflection, advice: journal.dayAdvice,
                            previousReflection: journal.previousDayReflection)
                            .accessibilityIdentifier("question-day-reflection")
                    }
                    if !showAnswered && !journal.pendingQuestions.isEmpty {
                        Text("Cevapların bu cihazda taslak olarak korunur. Daily butonuna dokunduğunda birlikte değerlendirilir; bütün soruları yanıtlaman gerekmez.")
                            .font(.footnote).foregroundStyle(DailyTheme.muted)
                    }
                } else {
                    ProgressView("Günlüğün Firebase’den alınıyor…")
                    if !model.serverReady { Button("Bağlantıyı yeniden dene") { model.retryListener() } }
                }
                Text(model.message).font(.footnote).foregroundStyle(DailyTheme.muted).accessibilityAddTraits(.updatesFrequently)
            }.padding(20)
        }.navigationTitle("Günlüğünün soruları").navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .workspaceToolbar(date: date, questionAnalysis: !showAnswered)
            .onDisappear { model.flushDraftWrites(date: date) }
            .sheet(isPresented: $replyStatusOpen) { AnalysisStatusSheet(date: date) }
            .task(id: date) {
                model.open(date: date); includeAnswered = showAnswered
            }
            .refreshable { await model.refreshFromFirebase(date: date) }
    }
}

struct NotificationSettingsScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DailySectionHeading(eyebrow: "Sana uygun zamanda", title: "Bildirimler", detail: "Sorular hazır olunca ve planlarının zamanı gelince haber al. Soru bildirimine dokununca yanıt ekranın açılır.")
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Bildirimler", isOn: Binding(get: { model.notificationsEnabled }, set: { enabled in Task { await model.setNotifications(enabled) } }))
                        .disabled(model.pushBusy)
                    Text(model.remotePushEnabled ? "Hatırlatmalar sunucudan iletilir." : "Telefona kaydedilmiş hatırlatmalar uygulama kapalıyken de çalışır.")
                        .font(.footnote).foregroundStyle(DailyTheme.muted)
                    if model.serverPushAvailable && !model.remotePushEnabled {
                        Text("Bu telefonun sunucu bildirim kaydı henüz tamamlanmadı. Aşağıdan yeniden deneyebilirsin.")
                            .font(.footnote).foregroundStyle(DailyTheme.muted)
                    }
                    Text(model.notificationStatus).font(.footnote).foregroundStyle(DailyTheme.ink)
                    if model.cloudConnected {
                        Button("Bildirim kaydını yeniden dene") { Task { await model.retryNotificationRegistration(requestServer: true) } }
                            .buttonStyle(DailySecondaryButtonStyle()).disabled(model.pushBusy)
                    }
                    if model.pushBusy { ProgressView("Cihaz kaydı doğrulanıyor…") }
                    if !model.companionNotice.isEmpty { Text(model.companionNotice).font(.footnote).foregroundStyle(DailyTheme.cobalt) }
                }.dailyCard()
                NotificationFrequencySection()
                Button("Deneme bildirimi gönder") { Task { await model.testLocalNotification() } }.buttonStyle(DailySecondaryButtonStyle())
                if !model.experienceNotice.isEmpty {Text(model.experienceNotice).font(.footnote)}
                Text("Kilit ekranında günlüğün ve yanıtların gösterilmez. Otomatik takip bildirimleri 08.00–22.00 arasında gelir; ajanda hatırlatmaları seçtiğin saati kullanır.").font(.footnote).foregroundStyle(DailyTheme.muted)
                Button("iPhone bildirim ayarlarını aç") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(DailySecondaryButtonStyle())
            }.padding(20)
        }.navigationTitle("Bildirimler").navigationBarTitleDisplayMode(.inline)
            .task { await model.refreshNotificationStatus() }
    }
}


private struct NotificationFrequencySection:View {
    @EnvironmentObject private var model:WorkspaceModel
    @State private var limit=3
    @State private var hour=10
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Stepper("Günde en fazla \(limit) bildirim",value:$limit,in:1...5)
            Picker("Takip bildirimleri en erken",selection:$hour) {ForEach(8...21,id:\.self) {Text(String(format:"%02d.00",$0)).tag($0)}}
            Button("Bildirim tercihini kaydet") {Task {await model.saveNotificationLimit(limit,hour:hour)}}.disabled(model.experienceBusy)
            Text("Bu saat ve 22.00–08.00 sessiz saatleri otomatik takip bildirimleri içindir. Ajanda hatırlatmaları ayarladığın saatte gelir.").font(.caption).foregroundStyle(DailyTheme.muted)
        }.dailyCard().task {limit=model.companionDailyLimit;hour=model.companionPreferredHour}
    }
}
