import SwiftUI
import UIKit
import DailyCore

struct JournalScreen: View {
    let date: String
    var allowsDailyAction = false
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.locale) private var locale
    // JournalTextEditor owns a UIKit UITextView, not a SwiftUI .focused field.
    // An unattached FocusState can reset to false during draft updates and make
    // updateUIView resign first responder on the first keystroke. Keep the
    // delegate's editing state across those updates; background dismissal and
    // analysis still explicitly clear it.
    @State private var writing = false
    @State private var replyStatusOpen = false
    @State private var newNoteOpen = false
    @State private var widgetReflectionOpen = false

    var body: some View {
        let journal = model.journal(date: date)
        let hasSavedResult = self.hasSavedResult
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(displayDate)
                        .font(.subheadline.weight(.medium)).foregroundStyle(DailyTheme.muted)
                        .accessibilityLabel(displayDate).accessibilityValue(date)
                        .accessibilityIdentifier("journal-date")
                    Spacer(minLength: 8)
                    if allowsDailyAction && date != WorkspaceModel.today {
                        Button("Bugüne dön") { model.showJournal(date: WorkspaceModel.today) }
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                            .accessibilityIdentifier("journal-return-today")
                    }
                }
                if hasSavedNote || model.drafts[date]?.inlineNote != nil {
                    if newNoteOpen {
                        JournalInlineNote(date: date, saved: model.drafts[date]?.inlineNote, existingText: model.text(date: date)) { newNoteOpen = false }
                            .id(model.companionScope + date)
                    } else {
                        Button { newNoteOpen = true } label: {
                            Label("Yeni not ekle", systemImage: "square.and.pencil")
                                .font(.headline).foregroundStyle(DailyTheme.cobalt)
                                .journalActionCard(accent: DailyTheme.energy)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .disabled(!model.canEdit(date: date) || model.phoneAnalysisBusy || model.busyDates.contains(date))
                            .accessibilityIdentifier("journal-add-note")
                    }
                } else {
                    DailyJournalWritingCard(focused: writing, progress: writingProgress) {
                        JournalTextEditor(text:Binding(get:{ model.text(date:date) },set:{ model.editText(date:date,text:$0) }),
                            focused:$writing,editable:model.canEdit(date: date) && !model.phoneAnalysisBusy,
                            accessibilityName:"\(date) günlüğü")
                            .id(date)
                    }
                }
                if model.unreadableDraftDates.contains(date) {
                    Label("Taslak okunamadı", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.semibold))
                    Button("Taslağı yeniden oku") { model.open(date: date, retry: true) }
                        .buttonStyle(DailySecondaryButtonStyle())
                }
                if model.remoteChanged(date: date) {
                    Label("Başka cihazdaki sürüm değişti. Taslağın korunuyor; kaydederken karşılaştırılacak.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(DailyTheme.orange)
                        .dailyCard(accent: DailyTheme.orange, padding: 14)
                }
                if model.text(date: date).contains(where: { !$0.isWhitespace }) { saveStatus }
                if model.connectionDiagnostic != nil {
                    Text("Bulut bağlantısı doğrulanamadı. Bağlantı ayrıntıları Ayarlar’da.")
                        .font(.footnote).foregroundStyle(DailyTheme.orange)
                }
                if !newNoteOpen && allowsDailyAction && date == WorkspaceModel.today && model.canStartDailyAnalysis(date:date) && !model.phoneAnalysisBusy {
                    Label("Hazır olduğunda Daily butonuna dokun.", systemImage: "arrow.up")
                        .font(.footnote).foregroundStyle(DailyTheme.muted)
                } else if !newNoteOpen && (!allowsDailyAction || date != WorkspaceModel.today) && model.canStartDailyAnalysis(date:date) {
                    Button("Değişiklikleri analiz et") {
                        writing=false
                        model.startPhoneAnalysis(date:date,requiresNewInput:true)
                        replyStatusOpen=true
                    }.buttonStyle(DailyPrimaryButtonStyle()).disabled(model.phoneAnalysisBusy || !model.canEdit(date: date))
                }
                if let journal {
                    if let task = journal.payload.object?["daily_task"] {
                        if task.object?["status"] != .string("completed") {
                            TaskResultCard(task: task)
                        }
                        if task.object?["status"] == .string("needs_input") {
                            ForEach(journal.pendingQuestions) { question in
                                QuestionEditor(date: date, question: question) { replyStatusOpen = true }
                            }
                        }
                    }
                    if !journal.questions.isEmpty && journal.payload.object?["daily_task"]?.object?["status"] != .string("needs_input") {
                        NavigationLink { JournalQuestionsScreen(date: date) } label: {
                            Label("Sorularını aç", systemImage: "bubble.left.and.bubble.right")
                        }.buttonStyle(DailySecondaryButtonStyle())
                    }
                }
                if hasSavedNote || hasSavedResult {
                    VStack(spacing: 10) {
                        if hasSavedResult {
                            JournalChangesLink(date: date)
                        }
                        if let journal, let reflection = journal.dayReflection {
                            JournalReflectionButton(date: date, reflection: reflection, advice: journal.dayAdvice,
                                previousReflection: journal.previousDayReflection)
                        }
                    }
                }
            }.padding(.horizontal,22).padding(.top,22).padding(.bottom,40)
        }
        .scrollIndicators(.hidden).background(Color.clear)
        .scrollDismissesKeyboard(.interactively)
        .background { BackgroundKeyboardDismissal { writing = false } }
        .onChange(of: model.phoneAnalysisBusy) { _, busy in
            if busy { writing = false }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .workspaceToolbar(date:date,allowsAnalysis:allowsDailyAction && date == WorkspaceModel.today && !newNoteOpen)
        .sheet(isPresented: $replyStatusOpen) { AnalysisStatusSheet(date: date) }
        .sheet(isPresented: $widgetReflectionOpen) {
            if let journal = model.journal(date: date), let reflection = journal.dayReflection {
                JournalReflectionSheet(date: date, reflection: reflection, advice: journal.dayAdvice,
                    previousReflection: journal.previousDayReflection)
            }
        }
        .onChange(of: date) { _, _ in newNoteOpen = false }
        .onChange(of: model.navigation.journalRoute) { _, _ in openWidgetDestination() }
        .onAppear { openWidgetDestination() }
        // The workspace snapshot already supplies journals. Opening a calendar
        // day must not re-read Firebase; pull-to-refresh remains explicit.
        .task(id: date) { model.open(date: date) }
        .onDisappear { model.flushDraftWrites(date: date) }
        .refreshable { await model.refreshFromFirebase(date: date) }
    }

    private func openWidgetDestination() {
        guard model.navigation.tab == .today, date == model.navigation.journalDate else { return }
        switch model.pendingAppleRoute {
        case .newNote where date == WorkspaceModel.today:
            model.pendingAppleRoute = nil
            guard model.canEdit(date: date), !model.phoneAnalysisBusy else { return }
            if hasSavedNote || model.drafts[date]?.inlineNote != nil { newNoteOpen = true }
            else { writing = true }
        case .reflection(let selected) where selected == date:
            model.pendingAppleRoute = nil
            widgetReflectionOpen = model.journal(date: date)?.dayReflection != nil
        default: break
        }
    }

    private var hasSavedNote: Bool {
        model.journal(date: date)?.rawText.contains { !$0.isWhitespace } == true
    }

    private var hasSavedResult: Bool {
        model.changeReceipts.contains(where: { $0.date == date }) ||
            model.journal(date: date).map { !$0.analyses.isEmpty || $0.analysisStatus == "complete" } == true
    }

    private var writingProgress: Double {
        Double(DailyWritingProgress.characterCount(in: model.text(date: date), upTo: 1_200)) / 1_200
    }

    private var displayDate: String {
        let parser=DateFormatter()
        parser.locale=Locale(identifier:"en_US_POSIX");parser.dateFormat="yyyy-MM-dd"
        parser.timeZone=TimeZone(identifier:"Europe/Istanbul")
        guard let value=parser.date(from:date) else { return date }
        let formatter=DateFormatter();formatter.locale=locale
        formatter.timeZone=parser.timeZone
        formatter.dateFormat=date == WorkspaceModel.today ? "d MMMM EEEE" : "d MMMM yyyy"
        return formatter.string(from:value)
    }
    private var saveStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.busyDates.contains(date) {
                    ProgressView("Kaydediliyor…").tint(DailyTheme.cobalt)
                } else {
                    Label(saveStatusText, systemImage: model.isDirty(date: date) ? "circle.fill" : "checkmark")
                        .foregroundStyle(model.isDirty(date: date) ? DailyTheme.orange : DailyTheme.muted)
                }
                Spacer()
            }.font(.footnote)
            if model.isDirty(date: date) && !model.message.isEmpty && !model.busyDates.contains(date) {
                Text(model.message).font(.footnote).foregroundStyle(DailyTheme.muted)
                    .textSelection(.enabled)
            }
        }.accessibilityIdentifier("journal-save-status")
    }

    private var saveStatusText: String {
        if model.isDirty(date: date) { return "Yeni taslak" }
        return model.journal(date: date) == nil ? "Taslak" : "Kaydedildi"
    }

}

private struct JournalInlineNote: View {
    let date: String
    let onClose: () -> Void
    @EnvironmentObject private var model: WorkspaceModel
    @State private var text: String
    @State private var focused = false
    @State private var applyFailed = false

    init(date: String, saved: InlineJournalDraft?, existingText: String, onClose: @escaping () -> Void) {
        self.date = date
        self.onClose = onClose
        let savedText = saved?.text ?? ""
        // An older edit draft can include the full original note as its prefix.
        let note = saved?.editingTextHash != nil && savedText.hasPrefix(existingText)
            ? String(savedText.dropFirst(existingText.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            : savedText
        _text = State(initialValue: note)
    }

    private func updateText(_ updated: String) {
        text = updated
        let note = updated.isEmpty ? nil : InlineJournalDraft(text: updated, editingTextHash: nil)
        model.updateInlineNote(date: date, note: note)
    }

    private var canEdit: Bool {
        model.canEdit(date: date) && !model.phoneAnalysisBusy && !model.busyDates.contains(date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Kapat") {
                    if model.flushDraftWrites(date: date) { onClose() } else { applyFailed = true }
                }
                    .accessibilityIdentifier("journal-close-note")
                Spacer()
                Button("Notu ekle", action: applyNote)
                    .fontWeight(.bold)
                    .disabled(!canEdit || !text.contains(where: { !$0.isWhitespace }))
                    .accessibilityIdentifier("journal-append-note")
            }
            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            DailyJournalWritingCard(focused: focused,
                progress: Double(DailyWritingProgress.characterCount(in: text, upTo: 1_200)) / 1_200) {
                JournalTextEditor(text: Binding(get: { text }, set: { updateText($0) }), focused: $focused, editable: canEdit,
                    accessibilityName: String(localized: "Yeni not ekle"), accessibilityID: "journal-new-note-editor")
            }
            if applyFailed {
                Text(model.message).font(.footnote).foregroundStyle(DailyTheme.orange)
            }
        }
    }

    private func applyNote() {
        guard canEdit else { return }
        if model.appendInlineNote(date: date, text: text) { onClose() } else { applyFailed = true }
    }

}

struct QuestionEditor: View {
    let date: String
    let question: JournalQuestion
    var onSubmit: () -> Void = {}
    @EnvironmentObject private var model: WorkspaceModel
    @State private var answering = false
    @State private var knownOpen=false
    private var hasAnswer: Bool { question.kind == .open ? !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : bit != nil }
    private var pending: DraftAnswer? { model.pendingAnswer(date: date, id: question.id) }
    private var text: String {
        if case .text(let value) = pending { return value ?? "" }
        return question.answerText ?? ""
    }
    private var bit: Int? {
        if case .boolean(let value) = pending { return value }
        return question.answerBoolean
    }
    private var isReminder: Bool { question.fields["reminder_proposal"]?.object != nil }
    private var editable: Bool { model.canEdit(date: date) && !model.phoneAnalysisBusy && !model.busyDates.contains(date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: question.kind == .open ? "text.quote" : "checkmark.circle")
                    .foregroundStyle(question.kind == .open ? DailyTheme.cobalt : DailyTheme.mint)
                Text(question.prompt).font(.system(size: 20, weight: .semibold)).foregroundStyle(DailyTheme.ink).fixedSize(horizontal: false, vertical: true)
            }
            if !question.rationale.isEmpty { Text(question.rationale).font(.footnote).foregroundStyle(DailyTheme.muted) }
            if question.kind == .open {
                JournalTextView(
                    text: Binding(get: { text }, set: {
                        model.editAnswer(date: date, id: question.id, answer: .text($0), savedText: question.answerText)
                    }),
                    focused: $answering, editable: editable, accessibilityName: "Yanıt: \(question.prompt)",
                    accessibilityID: "question-answer-\(question.id)", fontSize: 17, spacing: 3, serif: false,
                    ink: UIColor(DailyTheme.ink), caret: UIColor(DailyTheme.cobalt), viewportHeight: 98)
                    .overlay(alignment: .topLeading) {
                        Text("Yanıtın").font(.body).foregroundStyle(DailyTheme.muted)
                            .padding(.top, 10).opacity(text.isEmpty ? 1 : 0)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .padding(.horizontal, 13)
                    .background(DailyTheme.paleBlue).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            } else {
                HStack {
                    bitButton("Evet", value: 1)
                    bitButton("Hayır", value: 0)
                    if !isReminder { bitButton("Boş", value: nil) }
                }
            }
            if !question.isFunctional {
                Button("Bunu zaten söyledim") { knownOpen=true }.font(.caption).disabled(model.experienceBusy || model.phoneAnalysisBusy)
            }
            if question.isFunctional && (!isReminder || pending != nil || question.hasPendingFunctionalAnswer) {
                HStack(alignment: .center, spacing: 12) {
                    if pending != nil {
                        Text("İşlem onayın doğrudan uygulanır.")
                            .font(.caption).foregroundStyle(DailyTheme.muted)
                    }
                    Spacer(minLength: 0)
                    Button {
                        answering = false
                        model.submitFunctionalQuestionAnswer(date: date, id: question.id)
                    } label: {
                        Label(LocalizedStringKey(isReminder ? "Yeniden dene" : "Onayı uygula"), systemImage: "checkmark")
                            .font(.subheadline.bold()).padding(.horizontal, 16).frame(minHeight: 44)
                            .foregroundStyle(.white).background(DailyTheme.navy,in:Capsule())
                    }.buttonStyle(.plain)
                        .disabled(!hasAnswer || (pending == nil && !question.hasPendingFunctionalAnswer) || !model.canEdit(date: date) || !model.serverReady || model.phoneAnalysisBusy || model.phoneMemoryBusy || model.mapLinkBusy || model.busyDates.contains(date))
                        .accessibilityIdentifier("question-reply-\(question.id)")
                        .accessibilityHint("Yanıtını kaydeder ve işlem onayını uygular; AI analizi başlatmaz")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .dailyGlass(accent: hasAnswer ? DailyTheme.energy : DailyTheme.line)

        .sheet(isPresented:$knownOpen) { QuestionKnownSheet(question:question,date:date) }
        .accessibilityElement(children: .contain)
    }

    private func bitButton(_ title: String, value: Int?) -> some View {
        Button {
            model.editAnswer(date: date, id: question.id, answer: .boolean(value))
            if isReminder { model.submitFunctionalQuestionAnswer(date: date, id: question.id) }
        } label: {
            Label(title, systemImage: bit == value ? "checkmark.circle.fill" : "circle")
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .disabled(!editable || (isReminder && (!model.serverReady || model.phoneMemoryBusy || model.mapLinkBusy || bit == value)))
        .buttonStyle(.plain)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(bit == value ? DailyTheme.navy : DailyTheme.muted)
        .background(bit == value ? DailyTheme.energy.opacity(0.16) : .white, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(bit == value ? DailyTheme.mint : DailyTheme.line.opacity(0.6), lineWidth: bit == value ? 1.5 : 1) }
        .accessibilityLabel("\(question.prompt): \(title)")
        .accessibilityAddTraits(bit == value ? [.isSelected] : [])
    }
}
