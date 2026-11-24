import SwiftUI
import DailyCore

struct AIUsageScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @State private var rows: [AIUsageEntry] = []
    @State private var review: JSONValue?
    @State private var notice = ""
    private func count(_ value: Int?) -> String { value.map(String.init) ?? "bildirilmedi" }
    private func stage(_ name: String) -> String {
        switch name {
        case "emotionBackfill": return "Geçmiş duygu analizi"
        case "journal": return "Günlük analizi"
        case "journalRepair": return "Günlük yanıtı biçim düzeltmesi"
        case "dayReflection": return "Günün yorumu"
        case "dayReflectionRepair": return "Günün yorumu biçim düzeltmesi"
        case "crossMap": return "5 günlük harita denetimi"
        case "crossMapRepair": return "Denetim biçim düzeltmesi"
        case "routeTask": return "İsteği değerlendirme"
        case "executeTask": return "Görevi uygulama / araştırma"
        case "taskRepair": return "Görev yanıtı biçim düzeltmesi"
        case "questionRepair": return "Soru biçim düzeltmesi"
        case "mapQuestions": return "Harita soruları"
        case "mapLinks": return "Harita bağları"
        case "responseFormatRepair": return "AI yanıtı biçim düzeltmesi"
        case "connectionProbe": return "Bağlantı kontrolü"
        default: return "Diğer"
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                DailySectionHeading(eyebrow:"Şeffaf tüketim",title:"AI tüketim kaydı",
                    detail:"Bu cihazdaki son 500 çağrı. Günlük metnin ve AI yanıtın kayda alınmaz.")
                VStack(alignment:.leading,spacing:10) {
                    Text("\(rows.count) çağrı · \(rows.filter { !$0.succeeded }.count) tamamlanamadı").font(.headline)
                    Text("Bildirilen giriş: \(rows.compactMap { $0.usage?.inputTokens }.reduce(0,+)) · çıkış: \(rows.compactMap { $0.usage?.outputTokens }.reduce(0,+)) token")
                    Text("\(rows.filter { $0.usage == nil }.count) çağrıda token sayısı bildirilmedi. Önbellek girişin, düşünme çıkışın parçasıdır; toplama tekrar eklenmez. Bu kayıt hesabının kalan kotası veya faturası değildir.").font(.footnote).foregroundStyle(DailyTheme.muted)
                }.dailyCard()
                if let state = review?.object {
                    VStack(alignment:.leading,spacing:10) {
                        Text("Harita işlevsellik denetimi").font(.headline)
                        let total = state["journalIds"]?.array?.count ?? 0
                        let attempted = state["lastAttemptCount"]?.integer ?? 0
                        Text("Bir sonraki otomatik denetime \(max(0,5-(total-attempted))) yeni günlük kaldı.")
                        Text("Aynı günlüğün yanıtları sayacı artırmaz. Önceki günlükler başlangıç sayısına dahildir.").font(.footnote)
                        if state["status"]?.string == "failed" {
                            Text("Son denetim tamamlanamadı. Günlük analizin kaydedildi; sonraki 5 yeni günlükte tekrar denenecek.").foregroundStyle(DailyTheme.orange)
                        }
                        if let report = state["report"]?.object {
                            Text(report["summary"]?.string ?? "")
                            ForEach(Array((report["findings"]?.array ?? []).enumerated()),id:\.offset) { _, finding in
                                VStack(alignment:.leading,spacing:6) {
                                    Text(finding.object?["explanation"]?.string ?? "").font(.subheadline.bold())
                                    Text(finding.object?["recommendation"]?.string ?? "").font(.subheadline)
                                }.padding(.vertical,6)
                            }
                        }
                        Text("Cihazın son analiz kaydı gösterilir. Bu ekran Firebase'i yeniden okumaz.").font(.caption).foregroundStyle(DailyTheme.muted)
                    }.dailyCard()
                } else {
                    Text("Her 5 yeni günlük analizinden sonra haritaların başlıkları, yerleşimi, tekrarları ve bağları ayrıca denetlenir. İlk analizden sonra sayaç burada görünür.").dailyCard()
                }
                if !notice.isEmpty { Text(notice).foregroundStyle(DailyTheme.orange) }
                ForEach(rows.reversed()) { entry in
                    VStack(alignment:.leading,spacing:7) {
                        Text(stage(entry.stage)).font(.headline)
                        Text(entry.date.formatted(date:.abbreviated,time:.standard)).font(.caption)
                        Text("\(entry.model) · \(entry.succeeded ? "Yanıt alındı" : "Tamamlanamadı") · \(Int(entry.duration)) sn").font(.subheadline)
                        Text("Giriş: \(count(entry.usage?.inputTokens)) · Çıkış: \(count(entry.usage?.outputTokens)) · Toplam: \(count(entry.usage?.totalTokens))").font(.footnote)
                        Text("Önbellek: \(count(entry.usage?.cachedTokens)) · Düşünme: \(count(entry.usage?.reasoningTokens))").font(.footnote).foregroundStyle(DailyTheme.muted)
                    }.dailyCard()
                }
            }.padding(20)
        }.navigationTitle("Tüketim kaydı").navigationBarTitleDisplayMode(.inline)
        .task(id:model.companionScope) {
            let scope=model.companionScope
            rows=[];review=nil;notice=""
            do {
                let loaded=try await AIUsageLedger.shared.entries(scope:scope)
                guard scope==model.companionScope else { return }
                rows=loaded
                do {
                    let saved=try await model.localMapReview()
                    guard scope==model.companionScope else { return }
                    review=saved
                } catch { if scope==model.companionScope { notice="Tüketim kaydı hazır; yerel harita denetimi kaydı okunamadı." } }
            } catch { if scope==model.companionScope { notice="Cihazdaki tüketim kaydı okunamadı." } }
        }
    }
}
