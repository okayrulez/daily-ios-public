import SwiftUI
import DailyCore

struct CompanionInboxScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DailySectionHeading(eyebrow: "İlişkili düşünceler", title: "Sana eşlik eden", detail: "Geçmişinden gelen sorular ve zamanı gelen konular.")
                    if !model.companionActive { Text("Kişisel takip bu hesapta kapalı.") }
                    if !model.companionNotice.isEmpty { Text(model.companionNotice).font(.footnote) }
                    if model.companionCards.isEmpty {
                        Label("Şimdilik açık bir takip konusu yok.", systemImage: "sparkle")
                            .font(.subheadline).foregroundStyle(DailyTheme.muted)
                            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                            .dailyCard()
                    }
                    ForEach(model.companionCards.filter { $0.journalDate == nil && $0.kind != "deadline" }) { card in
                        CompanionCardView(card: card).id(card.id)
                    }

                }.padding(20)
            }
            .onAppear { if let id = model.selectedCompanionID { proxy.scrollTo(id, anchor: .top) } }
            .onChange(of: model.selectedCompanionID) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
        }.navigationTitle("Takip kutusu").navigationBarTitleDisplayMode(.inline)
    }
}
private struct CompanionCardView: View {
    @EnvironmentObject private var model: WorkspaceModel
    let card: CompanionCard
    @State private var text = ""
    private var draftKey: String { "companion-reply-\(model.companionScope)-\(card.id)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(card.title).font(.title2.bold())
            if card.body != card.title { Text(card.body) }
            if !card.question.isEmpty { Text(card.question).fontWeight(.medium) }
            DisclosureGroup("Neye dayanıyor?") {
                Text(card.basis).font(.footnote)
                if let timing = card.notification {
                    Text("Neden bu zaman? \(timing.reason)").font(.footnote)
                    Text(timing.basis == "inferred" ? "Bağlamdan çıkarılmış zaman önerisi" : "Kaynak veya hatırlatma tercihine dayalı").font(.caption)
                    if let date = CompanionCard.date(card.notBefore) { Text(date, style: .date); Text(date, style: .time) }
                } else { Text("Bildirim planlanmadı; bu soru takip kutusunda kalır.").font(.caption) }
                Text("\(card.sourceIds.count) kaynak · \(card.nodeIds.count) hafıza bağlantısı").font(.caption)
            }
            TextField("Cevabın", text: $text, axis: .vertical).lineLimit(3...10).textFieldStyle(.roundedBorder)
                .onAppear { text = UserDefaults.standard.string(forKey: draftKey) ?? "" }
                .onChange(of: text) { _, value in UserDefaults.standard.set(String(value.prefix(10000)), forKey: draftKey) }
            Button("Cevabı kaydet") { Task { if await model.respondCompanion(card: card, action: "answer", text: text) { UserDefaults.standard.removeObject(forKey: draftKey); text = "" } } }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf16.count > 10000 || model.companionBusy || !model.serverReady)
            HStack {
                Button("Yarına ertele") { Task { _ = await model.respondCompanion(card: card, action: "snooze") } }
                Button("Konuyu kapat") { Task { _ = await model.respondCompanion(card: card, action: "dismiss") } }
                if card.kind == "deadline" { Button("Tamamlandı") { Task { _ = await model.respondCompanion(card: card, action: "done") } } }
            }.font(.footnote).disabled(model.companionBusy || !model.serverReady)
        }.dailyCard(accent: DailyTheme.mint)
    }
}
