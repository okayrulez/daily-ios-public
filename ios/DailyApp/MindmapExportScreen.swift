import SwiftUI
import UniformTypeIdentifiers
import DailyCore

enum MindmapExportFailure: LocalizedError {
    case unavailable, offline, empty, purposeTooLong
    var errorDescription: String? {
        switch self {
        case .unavailable: "Hesabına giriş yap ve devam eden işlemin tamamlanmasını bekle."
        case .offline: "Kişisel alanın henüz hazır değil. Biraz sonra yeniden dene."
        case .empty: "Henüz dışa aktarılacak zihin haritası yok. Önce bir analiz tamamla."
        case .purposeTooLong: "İş açıklamasını 2000 karakterden kısa tut. Haritaların kısaltılmaz."
        }
    }
}

private struct MindmapPromptDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "md") ?? .plainText] }
    let data: Data
    init(markdown: String) { data = Data(markdown.utf8) }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private enum ContextExportScope: String, CaseIterable, Identifiable {
    case task, complete
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .task: "Bu iş için"
        case .complete: "Tüm haritam"
        }
    }
}

private struct ContextExportReview {
    struct Group: Identifiable {
        let id: String
        let title: String
        let notes: [MindmapContextPreview.Note]
    }

    let snapshot: MindmapContextSnapshot
    let groups: [Group]
    let notes: [String: MindmapContextPreview.Note]
    let suggested: Set<String>

    init(snapshot: MindmapContextSnapshot, preview: MindmapContextPreview) {
        self.snapshot = snapshot
        suggested = Set(preview.suggestedNoteIDs)
        notes = Dictionary(uniqueKeysWithValues: preview.notes.map { ($0.id, $0) })
        var orderedIDs = Set<String>()
        let grouped = Dictionary(grouping: preview.notes, by: \.mapId)
        groups = preview.notes.compactMap { note in
            guard orderedIDs.insert(note.mapId).inserted, let items = grouped[note.mapId] else { return nil }
            return Group(id: note.mapId, title: note.mapTitle, notes: items)
        }
    }

    func toggled(_ ids: Set<String>, in current: Set<String>, including: Bool) -> Set<String> {
        var next = current
        if including {
            var pending = Array(ids)
            while let id = pending.popLast() {
                guard next.insert(id).inserted else { continue }
                pending.append(contentsOf: notes[id]?.requiredNoteIDs ?? [])
            }
        } else {
            next.subtract(ids)
            // Remove inferences without their supporting notes until the selection is closed.
            while let dependent = next.first(where: { id in
                notes[id]?.requiredNoteIDs.contains(where: { !next.contains($0) }) == true
            }) {
                next.remove(dependent)
            }
        }
        return next
    }

    func emotions(for selection: Set<String>) -> [JSONValue] {
        let sources = Set(selection.flatMap { notes[$0]?.quotes.map(\.sourceID) ?? [] })
        return (snapshot.emotionHistory.array ?? []).filter { day in
            day.object?["sourceID"]?.string.map { sources.contains($0) } ?? false
        }
    }
}

struct MindmapExportScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @State private var purpose = ""
    @State private var scope: ContextExportScope = .task
    @State private var includeEmotions = false
    @State private var review: ContextExportReview?
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var exporting = false
    @State private var document: MindmapPromptDocument?
    @State private var filename = "daily-zihin-haritalarim.md"
    @State private var notice: String?
    private var account: String { model.companionScope }
    private var unavailable: Bool {
        busy || model.uid == nil || !model.serverReady || model.phoneAnalysisBusy || model.phoneMemoryBusy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let review {
                    reviewControls(review)
                } else {
                    DailySectionHeading(eyebrow: "", title: "AI seni tanıyarak başlasın.",
                        detail: "Haritalarını bir bağlam dosyasına dönüştür, görevi vermeden önce kullandığın AI aracına yükle.")
                    GuidedTourTip(kind: .export)
                    options
                    PersonalContextUsageSteps()
                    DisclosureGroup("Dosyanın içeriği ve gizliliği") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Dosya, seçtiğin notlardan kaynak alıntıları ve aralarındaki bağlantıları içerir. Tam günlük metinleri ve giriş anahtarları dosyaya eklenmez.")
                            Text("Dosya kişisel bilgiler içerir. Yalnız kullanmak istediğin araca kendin ver. Dosyayı oluşturmak herhangi bir AI aracına göndermez.")
                        }.padding(.top, 10)
                    }.font(.footnote).foregroundStyle(DailyTheme.muted).dailyCard()
                }
                if let notice { Text(notice).font(.footnote).textSelection(.enabled) }
            }.padding(20)
        }.navigationTitle("Zihin haritalarını paylaş").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DailyTheme.canvas, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: account) { _, _ in
                document = nil
                exporting = false
                notice = nil
                purpose = ""
                includeEmotions = false
                scope = .task
                clearReview()
            }
            .fileExporter(isPresented: $exporting, document: document,
                contentType: MindmapPromptDocument.readableContentTypes[0], defaultFilename: filename) { result in
                if case .success = result { notice = "Dosya kaydedildi. Kullanacağın araca ekleyip yapmak istediğin işi yazabilirsin." }
                else if case .failure = result { notice = "Dosya kaydedilemedi. Yeniden deneyebilirsin." }
                document = nil
            }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ne için kullanacaksın?").font(.headline)
            TextField("Örneğin: Konuşma tarzıma uygun bir yazı hazırlamak.", text: $purpose, axis: .vertical)
                .lineLimit(3...6).padding(14).background(DailyTheme.paleBlue)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .accessibilityIdentifier("context-export-purpose")
                .disabled(busy)
            Picker("Dosya kapsamı", selection: $scope) {
                ForEach(ContextExportScope.allCases) { option in Text(option.title).tag(option) }
            }.pickerStyle(.segmented).disabled(busy)
            Text(LocalizedStringKey(scope == .task
                 ? "dAIly görevindeki sözcüklerden ilgili notları önerir. Dosyayı oluşturmadan önce seçimini düzenleyebilirsin."
                 : "Tüm harita notlarını ve bağlantılarını tek dosyada alabilirsin."))
                .font(.footnote).foregroundStyle(DailyTheme.muted)
            Toggle("Duygu geçmişimi ve örüntülerimi ekle", isOn: $includeEmotions).disabled(busy)
            Button { Task { await prepare() } } label: {
                Label(LocalizedStringKey(scope == .task ? "İlgili notları önizle" : "Bağlam dosyamı hazırla"), systemImage: "doc.text")
            }.buttonStyle(DailyPrimaryButtonStyle())
                .accessibilityIdentifier("context-export-prepare")
                .disabled(unavailable)
            if busy { ProgressView("Haritaların dosyaya hazırlanıyor…") }
        }.padding(18).dailyGlass(accent: DailyTheme.energy)
    }

    @ViewBuilder private func reviewControls(_ review: ContextExportReview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dosyaya eklenecek notlar").font(.title2.bold())
            if !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(purpose).font(.subheadline).foregroundStyle(DailyTheme.muted)
            }
            if review.suggested.isEmpty {
                Text("Öneri bulunamadı. Dosyanda kullanmak istediğin notları seç.")
                    .font(.footnote).foregroundStyle(DailyTheme.muted)
            }
            HStack {
                Text("\(selected.count) not seçili").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Kapsamı değiştir") { clearReview() }.font(.subheadline).disabled(busy)
            }
            Button { Task { await saveSelected(review) } } label: {
                Label("Bağlam dosyamı hazırla", systemImage: "square.and.arrow.up")
            }.buttonStyle(DailyPrimaryButtonStyle())
                .accessibilityIdentifier("context-export-save-selection")
                .disabled(selected.isEmpty || unavailable)
            if busy { ProgressView("Haritaların dosyaya hazırlanıyor…") }
        }.dailyCard()
        .accessibilityIdentifier("context-export-selection")
        .padding(.bottom, 4)
        selectionList(review)
    }

    private func selectionList(_ review: ContextExportReview) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(review.groups) { group in
                let ids = Set(group.notes.map(\.id))
                let groupSelection = selected.intersection(ids)
                DisclosureGroup {
                    Button(LocalizedStringKey(groupSelection.isEmpty ? "Haritadaki tüm notları ekle" : "Haritadaki notları çıkar")) {
                        selected = review.toggled(ids, in: selected, including: groupSelection.isEmpty)
                    }.font(.footnote.weight(.semibold)).padding(.vertical, 8)
                    ForEach(group.notes) { note in
                        noteRow(note, review: review)
                    }
                } label: {
                    HStack {
                        Text(group.title).font(.headline)
                        Spacer()
                        Text("\(groupSelection.count) / \(ids.count)").font(.caption).monospacedDigit()
                            .foregroundStyle(DailyTheme.muted)
                    }
                }.dailyCard()
            }
            if includeEmotions {
                emotionPreview(review.emotions(for: selected))
            }
        }.disabled(busy)
    }

    private func noteRow(_ note: MindmapContextPreview.Note, review: ContextExportReview) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(note.label, isOn: Binding(get: { selected.contains(note.id) }, set: { include in
                selected = review.toggled([note.id], in: selected, including: include)
            }))
            if !note.requiredNoteIDs.isEmpty {
                Text("Bu çıkarım dayandığı notlarla birlikte paylaşılır.")
                    .font(.caption).foregroundStyle(DailyTheme.muted)
            }
            if !note.quotes.isEmpty {
                DisclosureGroup("Kaynak alıntıları (\(note.quotes.count))") {
                    ForEach(Array(note.quotes.enumerated()), id: \.offset) { _, quote in
                        quoteRow(date: quote.date, text: quote.quote)
                    }
                }.font(.footnote)
            }
        }.padding(.vertical, 7)
    }

    private func emotionPreview(_ days: [JSONValue]) -> some View {
        DisclosureGroup("Duygu geçmişi (\(days.count) gün)") {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                let date = day.object?["date"]?.string ?? ""
                if let reflection = day.object?["reflection"]?.string, !reflection.isEmpty {
                    quoteRow(date: date, text: reflection)
                }
                let items = (day.object?["observations"]?.array ?? []) + (day.object?["helpfulEvidence"]?.array ?? [])
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    if let quote = item.object?["quote"]?.string, !quote.isEmpty {
                        quoteRow(date: date, text: quote)
                    }
                }
            }
        }.dailyCard()
    }

    private func quoteRow(date: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date).font(.caption2).foregroundStyle(DailyTheme.muted)
            Text(text).font(.footnote).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
    }

    @MainActor private func prepare() async {
        guard !unavailable else { return }
        let owner = account
        let purpose = purpose
        guard purpose.utf16.count <= 2000 else {
            notice = MindmapExportFailure.purposeTooLong.localizedDescription
            return
        }
        let scope = scope
        let includeEmotions = includeEmotions
        busy = true
        notice = nil
        defer { busy = false }
        do {
            let snapshot = try await model.mindmapContextSnapshot(includeEmotions: includeEmotions)
            if scope == .task {
                let preview = try await Task.detached(priority: .userInitiated) {
                    try snapshot.preview(purpose: purpose, includeEmotions: includeEmotions)
                }.value
                guard account == owner else { return }
                guard !preview.notes.isEmpty else { throw MindmapExportFailure.empty }
                review = ContextExportReview(snapshot: snapshot, preview: preview)
                selected = Set(preview.suggestedNoteIDs)
            } else {
                let result = try await makeExport(snapshot, purpose: purpose, includeEmotions: includeEmotions)
                guard account == owner else { return }
                try openFileExporter(result)
            }
        } catch {
            guard account == owner else { return }
            notice = errorNotice(error)
        }
    }

    @MainActor private func saveSelected(_ review: ContextExportReview) async {
        guard !unavailable, !selected.isEmpty else { return }
        let owner = account
        busy = true
        notice = nil
        defer { busy = false }
        do {
            let result = try await makeExport(review.snapshot, purpose: purpose,
                                              includeEmotions: includeEmotions, noteIDs: selected)
            guard account == owner else { return }
            try openFileExporter(result)
        } catch {
            guard account == owner else { return }
            notice = errorNotice(error)
        }
    }

    private func makeExport(_ snapshot: MindmapContextSnapshot, purpose: String, includeEmotions: Bool,
                            noteIDs: Set<String>? = nil) async throws -> MindmapContextExport {
        try await Task.detached(priority: .userInitiated) {
            try MindmapContextExport(snapshot: snapshot, purpose: purpose, includeEmotions: includeEmotions,
                                     selectedNoteIDs: noteIDs)
        }.value
    }

    private func openFileExporter(_ result: MindmapContextExport) throws {
        guard result.nodeCount > 0 else { throw MindmapExportFailure.empty }
        filename = "daily-zihin-haritalarim-v\(result.revision).md"
        document = MindmapPromptDocument(markdown: result.markdown)
        notice = "\(result.mapCount) harita · \(result.nodeCount) düğüm · \(result.edgeCount) bağlantı · sürüm \(result.revision)"
        exporting = true
    }

    private func clearReview() {
        review = nil
        selected = []
        notice = nil
    }

    private func errorNotice(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Haritalar alınamadı. Bağlantını kontrol edip yeniden dene."
    }
}

/// The same short instructions appear in the real export and its onboarding rehearsal.
struct PersonalContextUsageSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            step("1", title: "Dosyanı kaydet.", detail: "Haritaların ve kullanım amacın tek bir kişisel bağlam dosyasında hazırlanır.")
            step("2", title: "Görevi vermeden önce yükle.", detail: "Dosyayı ChatGPT'ye veya kullanacağın AI aracına ekle. Dosya yükleyemiyorsan içeriğini ilk mesaja yapıştır.")
            step("3", title: "Sonra görevini yaz.", detail: "“Bu dosyayı kişisel bağlamım olarak kullan; yalnız bu işle ilgili bilgileri değerlendir.” diyerek istediğin işi ver.")
        }.accessibilityElement(children: .contain)
    }
    private func step(_ number: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.bold()).foregroundStyle(DailyTheme.cobalt)
                .frame(width: 26, height: 26).background(DailyTheme.paleBlue, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(DailyTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
