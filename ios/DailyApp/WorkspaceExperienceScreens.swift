import SwiftUI
import DailyCore

struct WorkspaceChangesScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    var date: String? = nil
    @State private var pendingUndo: WorkspaceChangeReceipt?
    @State private var undoMessage = ""

    private var applePlans: [ManagedAgenda.ApplePlan] {
        guard let record = model.records[WorkspaceHash.sha256(ManagedAgenda.key)] else { return [] }
        return (try? ManagedAgenda.applePlans(record)) ?? []
    }

    private var dates: [String] {
        if let date { return [date] }
        return Array(Set(model.changeReceipts.filter { $0.undone != true }.map(\.date))
            .union(model.dates.filter { guard let journal = model.journal(date: $0) else { return false }
                return journal.dayReflection != nil || journal.payload.object?["daily_task"] != nil ||
                    journal.payload.object?["reminder_results"]?.array?.isEmpty == false })).sorted(by: >)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text(date == nil ? "Gün özetleri" : "Günün özeti").font(.largeTitle.bold())
                ForEach(dates, id: \.self) { day in
                    summary(day)
                }
                if dates.isEmpty { Text("Henüz bir gün özeti yok.").foregroundStyle(DailyTheme.muted) }
            }.padding(24)
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let latest = model.changeReceipts.first, latest.undone != true, date == nil || date == latest.date {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Son analizi geri al", systemImage: "arrow.uturn.backward") { pendingUndo = latest }
                            .disabled(model.experienceBusy || model.phoneAnalysisBusy)
                    } label: {
                        Label("Diğer işlemler", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog("Son analiz geri alınsın mı?", isPresented: Binding(
            get: { pendingUndo != nil }, set: { if !$0 { pendingUndo = nil } }), titleVisibility: .visible) {
            if let receipt = pendingUndo {
                Button("Geri al", role: .destructive) {
                    Task {
                        _ = await model.undoAnalysis(receipt)
                        undoMessage = model.experienceNotice
                    }
                }
            }
            Button("Vazgeç", role: .cancel) { pendingUndo = nil }
        }
        .safeAreaInset(edge: .bottom) {
            if !undoMessage.isEmpty {
                Text(undoMessage).font(.footnote).padding(12).background(.regularMaterial)
            }
        }
    }

    private func summary(_ day: String) -> some View {
        let receipts = model.changeReceipts.filter { $0.date == day && $0.undone != true }
        let changes = AnalysisChanges.combined(receipts.map(\.changes))
        let noteCount = changes.newNotes + changes.updatedNotes
        let journal = model.journal(date: day)
        let reminderResults = journal?.payload.object?["reminder_results"]?.array?.compactMap(\.string) ?? []
        let plans = applePlans.filter { $0.sourceID == journal?.id && model.appleAgendaResults[$0.id] != nil }
        let hasAgenda = !plans.isEmpty || receipts.contains { !$0.agenda.isEmpty } || !reminderResults.isEmpty
        let task = journal?.payload.object?["daily_task"]
        let hasTaskResult = task?.object?["reply"]?.string?.isEmpty == false
        return VStack(alignment: .leading, spacing: 12) {
            if let selectedDay = JournalCalendar.day(forKey: day) {
                Text(selectedDay, style: .date)
                    .font(.headline)
                    .accessibilityValue(day)
                    .accessibilityIdentifier("daily-summary-date")
            }
            if let journal, let reflection = journal.dayReflection {
                Text("Günün yorumu").font(.headline)
                Text(reflection).textSelection(.enabled)
                ForEach(journal.dayAdvice, id: \.self) { advice in
                    Label(advice, systemImage: "sparkles").font(.subheadline)
                }
            }
            if noteCount > 0 || changes.newLinks > 0 {
                Label("\(noteCount) harita notu etkilendi · \(changes.newLinks) yeni bağlantı",
                      systemImage: "point.3.connected.trianglepath.dotted")
                NavigationLink { AtlasScreen() } label: { Text("Haritaları aç") }
            }
            ForEach(plans, id: \.id) { plan in
                if let result = model.appleAgendaResults[plan.id] {
                    Label("\(plan.title) · \(result.message)", systemImage: result.saved ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(result.saved ? DailyTheme.muted : DailyTheme.orange)
                }
            }
            if hasAgenda {
                NavigationLink { PhoneAgendaScreen() } label: { Label("Ajandayı aç", systemImage: "calendar") }
            }
            if hasTaskResult || !reminderResults.isEmpty {
                JournalAnalysisResultButton(date: day, changes: changes)
            }
            if journal?.dayReflection == nil && !hasTaskResult && !hasAgenda && noteCount == 0 && changes.newLinks == 0 {
                Text("Bu gün için henüz özet oluşmadı.").foregroundStyle(DailyTheme.muted)
            }
        }.dailyCard()
    }
}

struct WorkspaceTasksScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @State private var showCompleted=false
    @State private var statusDate:String?
    private struct Item: Identifiable {
        let id,date,goal,status,reply:String
        let task:JSONValue?
        let reportKey:String?
        let current:Bool
    }
    private var tasks:[Item] {
        var items:[String:Item]=[:]
        for date in model.dates {
            guard let journal=model.journal(date:date) else { continue }
            for analysis in journal.analyses.sorted(by:{$0.version < $1.version}) {
                guard let report=analysis.fields["task_report_key"]?.string else { continue }
                let identity=date+":"+(analysis.fields["task_raw_text_hash"]?.string ?? report)
                items[identity]=Item(id:identity,date:date,goal:analysis.fields["task_goal"]?.string ?? "Önceki görev",
                    status:analysis.fields["task_status"]?.string ?? "archived",reply:analysis.reflection,task:nil,reportKey:report,current:false)
            }
            if let task=journal.payload.object?["daily_task"],let f=task.object {
                let identity=date+":"+(f["rawTextHash"]?.string ?? date)
                items[identity]=Item(id:identity,date:date,goal:f["goal"]?.string ?? "Görev",status:f["status"]?.string ?? "blocked",
                    reply:f["reply"]?.string ?? "",task:task,reportKey:nil,current:true)
            }
        }
        return items.values.sorted { $0.date > $1.date }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:20) {
                DailySectionHeading(eyebrow:"İsteklerin",title:"İşlerin",detail:"Netleştirilen, araştırılan ve tamamlanan görevlerin. Bu ekranı açmak AI çalıştırmaz.")
                if model.phoneAnalysisBusy {
                    ProgressView(model.phoneAnalysisNotice)
                    Button("Çalışan işlemin durumunu aç") {statusDate=model.phoneAnalysisDate}
                }
                Toggle("Tamamlananları da göster",isOn:$showCompleted)
                if tasks.isEmpty { Text("Bugün'e yapmak istediğin işi yaz. Görev olarak değerlendirildiğinde burada takip edebilirsin.") }
                ForEach(tasks.filter { showCompleted || !["completed","archived"].contains($0.status) }) { item in
                    VStack(alignment:.leading,spacing:12) {
                        Text(item.date).font(.caption).foregroundStyle(DailyTheme.muted)
                        Text(item.goal).font(.headline)
                        Label(statusLabel(item.status),systemImage:item.status == "blocked" ? "exclamationmark.circle" : "circle.dotted").font(.subheadline)
                        if let task=item.task { TaskResultCard(task:task,showContinuation:false,compact:true) }
                        else if let key=item.reportKey { ArchivedTaskReplyButton(key:key) }
                        if item.current && item.status == "needs_input" {
                            NavigationLink { JournalQuestionsScreen(date:item.date) } label: { Label("Eksik bilgileri yanıtla",systemImage:"bubble.left") }
                        }
                        if item.current && ["in_progress","blocked"].contains(item.status) {
                            Button(item.status == "blocked" ? "Yeniden dene" : "Araştırmaya devam et") {
                                model.startPhoneAnalysis(date:item.date);statusDate=item.date
                            }.buttonStyle(DailySecondaryButtonStyle()).disabled(model.phoneAnalysisBusy || model.experienceBusy)
                        }
                        if !item.current && item.status != "completed" { Text("Bu eski aşamanın üzerine yeni bir günlük sürümü geldi. Kaynak yazıdan devam edebilirsin.").font(.caption) }
                        NavigationLink { JournalScreen(date:item.date) } label: { Label("Kaynak günlüğe git",systemImage:"book") }
                    }.dailyCard()
                }
            }.padding(24)
        }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented:Binding(get:{statusDate != nil},set:{if !$0 { statusDate=nil }})) { AnalysisStatusSheet(date:statusDate ?? WorkspaceModel.today) }
    }
    private func statusLabel(_ value:String)->String {
        switch value {case "needs_input":"Netleştirme bekliyor";case "in_progress":"Araştırılıyor · kaydedilmiş aşama var";case "blocked":"Engel var · ayrıntıyı oku";case "completed":"Tamamlandı";case "archived":"Arşivlenmiş aşama · raporu oku";default:"Bekliyor"}
    }
}

struct MemoryTimelineScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @State private var search=""
    private struct Entry:Identifiable { let id,title:String;let note:MobileAtlas.Note }
    private var entries:[Entry] {
        let records=Array(model.records.values)
        guard let atlas=try? MobileAtlas.load(records:records) else { return [] }
        return atlas.maps.flatMap { map in
            (try? MobileAtlas.notes(for:map,records:records))?.enumerated().compactMap { index,note -> Entry? in
                guard !note.date.isEmpty,search.isEmpty || note.text.localizedCaseInsensitiveContains(search) || map.title.localizedCaseInsensitiveContains(search) else { return nil }
                return Entry(id:map.id+":"+String(index),title:map.title,note:note)
            } ?? []
        }.sorted { $0.note.date > $1.note.date }
    }
    var body:some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:20) {
                DailySectionHeading(eyebrow:"Zaman içinde",title:"Düşüncelerinin izi",detail:"Kaynaklar ve düzeltmeler tarih sırasıyla. Yan yana görünen notlar kendiliğinden bir kişilik değişimi veya neden-sonuç kanıtı değildir.")
                if entries.isEmpty { Text("Bu aramada tarihli not bulunamadı.").foregroundStyle(DailyTheme.muted) }
                ForEach(entries) { entry in
                    VStack(alignment:.leading,spacing:10) {
                        Text(String(entry.note.date.prefix(10))+" · "+entry.title).font(.caption.bold()).foregroundStyle(DailyTheme.cobalt)
                        Text(entry.note.kind == "correction" ? "Senin düzeltmen" : entry.note.kind == "inference" ? "AI çıkarımı" : "AI gözlemi").font(.caption)
                        Text(entry.note.text).textSelection(.enabled)
                        if let quote=entry.note.quote,!quote.isEmpty { Text("“"+quote+"”").font(.subheadline).foregroundStyle(DailyTheme.muted).textSelection(.enabled) }
                        if WorkspaceIdentity.validDate(String(entry.note.date.prefix(10))),entry.note.sourceId?.hasPrefix("research_") != true {
                            NavigationLink { JournalScreen(date:String(entry.note.date.prefix(10))) } label: { Label("O günün yazısını aç",systemImage:"book") }
                        }
                    }.dailyCard()
                }
            }.padding(24)
        }.searchable(text:$search,prompt:"Bir düşüncenin geçmişini ara").navigationTitle("").navigationBarTitleDisplayMode(.inline)
    }
}

struct QuestionKnownSheet:View {
    @EnvironmentObject private var model:WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let question:JournalQuestion
    let date:String
    @State private var answer=""
    var body:some View {
        NavigationStack {
            Form {
                Section { Text(question.prompt) }
                Section("Daha önce verdiğin yanıt (isteğe bağlı)") {
                    TextField("Kısa bir hatırlatma ekle…",text:$answer,axis:.vertical).lineLimit(3...6)
                    Text("Bu soruyu yeniden sormama tercihin Firebase'e kaydedilir. Yeni bilgi veya koşul değişikliği olursa AI bunun nedenini açıklamalıdır.").font(.footnote)
                }
                Section {
                    Button("Bunu zaten belirttim") {
                        Task {
                            guard let event=try? ExperienceEvent(kind:"question_known",subjectID:WorkspaceHash.sha256(question.prompt),title:question.prompt,text:answer,value:"known") else { return }
                            if await model.markQuestionKnown(event,question:question,date:date) { dismiss() }
                        }
                    }.disabled(model.experienceBusy || answer.utf16.count > 2000)
                    Text(model.experienceNotice).font(.footnote)
                }
            }.navigationTitle("Tekrar sorma").toolbar { ToolbarItem(placement:.cancellationAction) { Button("Vazgeç") { dismiss() } } }
        }
    }
}

struct NodeCorrectionSheet:View {
    @EnvironmentObject private var model:WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let nodeID,label:String
    @State private var text=""
    @State private var verdict="context"
    var body:some View {
        NavigationStack {
            Form {
                Text(label).font(.headline)
                Picker("Düzeltme",selection:$verdict) {
                    Text("Bağlam ekle").tag("context");Text("Yanlış çıkarım").tag("incorrect");Text("Artık geçerli değil").tag("no_longer")
                }
                TextField("Doğrusunu kendi sözlerinle yaz…",text:$text,axis:.vertical).lineLimit(4...10)
                Text("Kaynak yazı silinmez. Yanlış veya artık geçersiz düğüm geri çekilir; düzeltmen sonraki analizlerde öncelikli kalır.").font(.footnote)
                Button("Düzeltmeyi kaydet") { Task { if await model.correctNode(id:nodeID,text:text,verdict:verdict) { dismiss() } } }
                    .disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || text.utf16.count > 2000 || model.experienceBusy || model.phoneAnalysisBusy)
                Text(model.experienceNotice).font(.footnote)
            }.navigationTitle("Notu düzelt").toolbar { ToolbarItem(placement:.cancellationAction) { Button("Vazgeç") { dismiss() } } }
        }
    }
}
