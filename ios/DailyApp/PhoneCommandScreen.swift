import SwiftUI
import DailyCore

struct PhoneCommandScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @State private var text = ""
    @State private var intent = "reflect"
    @State private var pending: PhoneCommand?
    @State private var busy = false
    @State private var notice = ""
    private var draftKey: String { "phone-command-draft-\(model.companionScope)" }
    private var pendingKey: String { "phone-command-pending-\(model.companionScope)" }
    private var commands: [(WorkspaceRecord, PhoneCommand)] {
        model.records.values.compactMap { record in (try? PhoneCommand.decode(record)).map { (record,$0) } }.sorted { $0.1.createdAt > $1.1.createdAt }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DailySectionHeading(eyebrow:"Telefonundan bilgisayarına",title:"Bir isteğin mi var?",detail:"Bir düşünceni değerlendir veya dAIly için geliştirme isteğini bırak. Bilgisayarın açıldığında buradan devam eder.")
                Picker("İsteğin türü",selection:$intent) {
                    Text("Düşüncemi değerlendir").tag("reflect")
                    Text("dAIly’yi geliştir").tag("improve_daily")
                }.pickerStyle(.menu).disabled(busy || pending != nil)
                TextEditor(text:$text).frame(minHeight:145).padding(10).background(DailyTheme.paper).clipShape(RoundedRectangle(cornerRadius:18))
                    .disabled(busy || pending != nil).accessibilityLabel("PC’ye göndereceğin istek")
                    .onChange(of:text) { _, value in UserDefaults.standard.set(value,forKey:draftKey) }
                if intent == "improve_daily" {
                    Text("İsteğin PC’deki Analiz akışına düşer. Geliştirmeyi oradan Codex’e aktarabilirsin; otomatik kod değişikliği henüz etkin değil.").font(.footnote).foregroundStyle(DailyTheme.muted)
                }
                Button(pending == nil ? "PC’ye gönder" : "Aynı isteği yeniden gönder") { Task { await send() } }
                    .buttonStyle(DailyPrimaryButtonStyle()).disabled(busy || !model.serverReady || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || text.utf16.count > 10000)
                if busy { ProgressView("Firebase onayı bekleniyor…") }
                if !notice.isEmpty { Text(notice).font(.footnote).accessibilityAddTraits(.updatesFrequently) }
                if !model.serverReady { Text("Bağlantı bekleniyor. Taslağın bu telefonda korunuyor.").font(.footnote).foregroundStyle(DailyTheme.muted) }
                Text("İsteklerin").font(.title2.bold())
                if commands.isEmpty { Text("Gönderdiğin istekler ve PC’nin sonuçları burada görünecek.").dailyCard() }
                ForEach(commands, id: \.1.id) { record, command in
                    let resultRecord = model.records.values.first { $0.key == "note:companion/command-results/\(command.id).md" }
                    let result = resultRecord.flatMap { try? PhoneCommandResult.decode($0,command:record) }
                    VStack(alignment:.leading,spacing:12) {
                        Label(result?.statusLabel ?? "Firebase’de · PC bekleniyor",systemImage:result?.status == "complete" ? "checkmark.circle" : "desktopcomputer").font(.caption.bold()).foregroundStyle(DailyTheme.cobalt)
                        Text(command.text).textSelection(.enabled)
                        if let result { Text(result.message).font(.subheadline).foregroundStyle(DailyTheme.muted).textSelection(.enabled) }
                        Text(command.createdAt.prefix(10)).font(.caption2).foregroundStyle(DailyTheme.muted)
                    }.dailyCard()
                }
            }.padding(20)
        }.navigationTitle("dAIly’ye bir istek").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                text = UserDefaults.standard.string(forKey:draftKey) ?? ""
                if let data = UserDefaults.standard.data(forKey:pendingKey), let saved = try? JSONDecoder().decode(PhoneCommand.self,from:data) {
                    pending = saved; text = saved.text; intent = saved.intent
                }
            }
    }
    private func send() async {
        busy = true; notice = ""; let scope = model.companionScope
        defer { busy = false }
        do {
            let command = try pending ?? PhoneCommand(intent:intent,text:text)
            // Persist the identity before sending; retries cannot duplicate a command.
            UserDefaults.standard.set(try JSONEncoder().encode(command),forKey:pendingKey); pending = command
            try await model.sendCommand(command)
            guard model.companionScope == scope else { return }
            UserDefaults.standard.removeObject(forKey:pendingKey); pending = nil; text = ""
            UserDefaults.standard.removeObject(forKey:draftKey)
            notice = "Firebase’e kaydedildi. PC açık ve bağlı olduğunda isteğini alacak."
        } catch { notice = "Sunucu onayı alınamadı. İsteğin korundu; aynı isteği yeniden gönderebilirsin." }
    }
}

private struct AgendaDaySelection: Identifiable {
    let date: String
    var id: String { date }
}

struct PhoneAgendaScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @State private var month = Date()
    @State private var selectedDate = WorkspaceModel.today
    @State private var openedDay: AgendaDaySelection?
    @State private var occurrences: [AgendaOccurrence] = []
    @State private var agendaError = false
    private var agendaRecord: WorkspaceRecord? { model.records[WorkspaceHash.sha256(ManagedAgenda.key)] }
    private var monthStart: Date { JournalCalendar.calendar().dateInterval(of: .month, for: month)?.start ?? month }
    private var projectionID: String { model.companionScope + (agendaRecord?.hash ?? "") + JournalCalendar.key(monthStart) }
    private var activityCounts: [String: Int] { Dictionary(grouping: occurrences, by: \.date).mapValues(\.count) }
    private var timed: [CompanionCard] { model.companionCards.filter { $0.notification != nil && ($0.kind == "deadline" || ($0.question.isEmpty && $0.kind != "followup" && $0.kind != "checkin")) }.sorted { $0.deliveryDate(events:model.companionEvents) < $1.deliveryDate(events:model.companionEvents) } }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    JournalCalendarView(month: $month, selectedDate: $selectedDate,
                        activityCounts: activityCounts, availableHeight: geometry.size.height,
                        onSelect: { date in
                            openedDay = AgendaDaySelection(date: date)
                        })
                    ManagedAgendaSection(date: selectedDate,
                        items: occurrences.filter { $0.date == selectedDate }, error: agendaError)
                    if !timed.isEmpty {
                        DisclosureGroup("Diğer hatırlatmalar · \(timed.count)") {
                            VStack(spacing: 14) {
                                ForEach(timed) { card in reminder(card) }
                            }.padding(.top, 12)
                        }.font(.subheadline.weight(.semibold))
                    }
                }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 24)
            }.refreshable { await model.refreshFromFirebase() }
        }.navigationTitle("Ajanda").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $openedDay) { selection in
                NavigationStack {
                    AgendaDayScreen(date: selection.date, items: occurrences.filter { $0.date == selection.date }, agendaError: agendaError)
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .task(id: model.pendingAppleRoute) {
                guard case .agenda(let date) = model.pendingAppleRoute,
                      let day = JournalCalendar.day(forKey: date) else { return }
                model.pendingAppleRoute = nil
                selectedDate = date
                month = day
            }
            .task(id: projectionID) {
                // Project the displayed month from the cached record; browsing never fetches Firebase.
                do {
                    let days = JournalCalendar.calendar().range(of: .day, in: .month, for: month)?.count ?? 31
                    occurrences = try agendaRecord.map { try ManagedAgenda.upcoming($0, from: JournalCalendar.key(monthStart), days: days) } ?? []
                    agendaError = false
                } catch { occurrences = []; agendaError = true }
            }
    }
    private func reminder(_ card: CompanionCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let delivery = card.deliveryDate(events: model.companionEvents)
            HStack { Text(delivery, style: .date); Spacer(); Text(delivery, style: .time) }
                .font(.caption.bold()).foregroundStyle(DailyTheme.cobalt)
            Text(card.title).font(.title2.bold())
            Text(card.body).font(.subheadline)
            Text(card.notification?.reason ?? "").font(.footnote).foregroundStyle(DailyTheme.muted)
            HStack {
                Button("Tamamlandı") { Task { _ = await model.respondCompanion(card: card, action: "done") } }
                Spacer()
                Button("Yarına ertele") { Task { _ = await model.respondCompanion(card: card, action: "snooze") } }
            }.font(.subheadline).disabled(model.companionBusy || !model.serverReady)
        }.dailyCard()
    }
}
