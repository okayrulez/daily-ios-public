import SwiftUI
import DailyCore

struct ConflictScreen: View {
    let comparison: WorkspaceConflict
    @EnvironmentObject private var model: WorkspaceModel
    @State private var confirmReload = false
    @State private var confirmOverwrite = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DailySectionHeading(eyebrow: comparison.date,
                        title: missing ? "Günlüğünü geri yükle" : "Değişiklikleri karşılaştır",
                        detail: missing ? "Telefondaki günlük ve cevapların korunuyor." : "Telefondaki taslağın ve sunucudaki kayıt korunuyor.")
                    Text(missing
                        ? "Bu günlük sunucuda bulunamadı. Geri yüklediğinde telefondaki günlük, sorular, analizler ve yeni yanıtların birlikte kaydedilir."
                        : "Kaydetmeden önce sunucu yeniden kontrol edilir. Arada bir değişiklik olursa hiçbir sürümün üzerine yazılmaz.")
                        .font(.subheadline).foregroundStyle(DailyTheme.muted)
                    VStack(alignment: .leading, spacing: 10) {
                        DailyEyebrow(text: missing ? "Telefonda korunan günlük" : "Sunucudaki günlük", color: DailyTheme.cobalt)
                        Text(sourceText)
                            .font(.system(size: 17, design: .default)).lineSpacing(4).textSelection(.enabled)
                    }.dailyCard(accent: DailyTheme.cobalt)
                    if let text = comparison.text {
                        VStack(alignment: .leading, spacing: 10) {
                            DailyEyebrow(text: "Yerel taslağın", color: DailyTheme.orange)
                            Text(text).font(.system(size: 17, design: .default)).lineSpacing(4).textSelection(.enabled)
                        }.dailyCard(accent: DailyTheme.orange)
                    }
                    ForEach(comparison.answers.keys.sorted(), id: \.self) { id in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(question(id: id)?.prompt ?? "Soru · \(id)").font(.headline)
                            Text("Senin yanıtın: \(answerDescription(comparison.answers[id]!))")
                            if let question = question(in: comparison.server, id: id) {
                                Text("Sunucudaki yanıt: \(question.answerText ?? question.answerBoolean.map { $0 == 1 ? "Evet" : "Hayır" } ?? "Boş")")
                                    .foregroundStyle(DailyTheme.muted)
                            }
                        }.dailyCard(padding: 15)
                    }
                    Button(missing ? "Günlüğü ve yanıtları geri yükle" : "Yanıtlarımı ve değişikliklerimi kaydet") { confirmOverwrite = true }
                        .buttonStyle(DailyPrimaryButtonStyle()).disabled(!canApply)
                    Button("Şimdilik kapat, taslağı koru") { model.conflict = nil }.buttonStyle(DailySecondaryButtonStyle())
                    Button("Taslağı bırak, sunucudan yeniden yükle", role: .destructive) { confirmReload = true }
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48).foregroundStyle(.red)
                }.padding(.horizontal, 20).padding(.vertical, 26)
            }
            .scrollIndicators(.hidden).background(DailyTheme.canvas)
            .navigationTitle(missing ? "Günlüğü kurtar" : "Kayıt karşılaştırması").navigationBarTitleDisplayMode(.inline)
            .alert(missing ? "Günlük geri yüklensin mi?" : "Değişiklikler kaydedilsin mi?", isPresented: $confirmOverwrite) {
                Button("Vazgeç", role: .cancel) {}
                Button("Uygula") { Task { await model.overwrite(comparison) } }
            } message: { Text(missing
                ? "Telefonda saklanan günlük, sorular, analizler ve yanıtların sunucuya geri yüklenir. Sunucuda yeni bir kayıt oluşmuşsa üzerine yazılmaz."
                : "Yalnızca seçtiğin metin veya yanıtlar değişir. Sunucunun önceki sürümü arşivlenir; diğer alanlar korunur.") }
            .alert("Bu günün yerel taslağı bırakılsın mı?", isPresented: $confirmReload) {
                Button("Vazgeç", role: .cancel) {}
                Button("Sunucuyu yükle", role: .destructive) { Task { await model.reloadServer(comparison) } }
            } message: { Text("Bu güne ait gönderilmemiş metin ve tüm yanıt taslakların silinir. Sunucu okunamazsa taslak korunur.") }
        }
    }

    private var missing: Bool { comparison.server == nil }
    private var canApply: Bool {
        !missing || comparison.base != nil || (comparison.text != nil && comparison.answers.isEmpty)
    }
    private var sourceText: String {
        guard let source = comparison.server ?? comparison.base else {
            return "Bu cihazda günlüğün kaynak metni bulunamadı. Yanıt taslakların korunuyor."
        }
        guard let journal = try? source.journal() else { return "Günlük kaydı okunamadı. Yanıt taslakların korunuyor." }
        return journal.rawText.isEmpty ? "Günlük metni boş." : journal.rawText
    }
    private func question(id: String) -> JournalQuestion? {
        question(in: comparison.server, id: id) ?? question(in: comparison.base, id: id)
    }
    private func question(in record: WorkspaceRecord?, id: String) -> JournalQuestion? {
        guard let journal = try? record?.journal() else { return nil }
        return (journal.questions + journal.archivedAnsweredQuestions).first { $0.id == id }
    }
    private func answerDescription(_ value: DraftAnswer) -> String {
        switch value { case .text(let text): return text ?? "Boş"; case .boolean(let bit): return bit.map { $0 == 1 ? "Evet" : "Hayır" } ?? "Boş" }
    }
}
