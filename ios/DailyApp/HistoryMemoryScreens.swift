import SwiftUI
import DailyCore

struct HistoryScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                DailySectionHeading(eyebrow: "Zaman çizgisi", title: "Geçmiş", detail: "Günlüklerin ve bu cihazda korunan taslakların.")
                    .padding(.bottom, 10)
                if model.dates.isEmpty { ContentUnavailableView("Henüz günlük yok", systemImage: "calendar", description: Text("Hesabına eşitlenen günler ve bu cihazdaki taslaklar burada görünür.")) }
                ForEach(model.dates, id: \.self) { date in
                    NavigationLink { JournalScreen(date: date) } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(model.isDirty(date: date) ? DailyTheme.orange.opacity(0.12) : DailyTheme.cobalt.opacity(0.10))
                                    .frame(width: 46, height: 46)
                                Image(systemName: model.isDirty(date: date) ? "pencil.line" : "checkmark")
                                    .foregroundStyle(model.isDirty(date: date) ? DailyTheme.orange : DailyTheme.cobalt)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(date).font(.system(size: 19, weight: .semibold, design: .default))
                                Text(model.isDirty(date: date) ? "Yerel taslak var" : "Kaydedilmiş günlük").font(.caption).foregroundStyle(DailyTheme.muted)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption.bold()).foregroundStyle(DailyTheme.cobalt)
                        }.frame(minHeight: 52).dailyCard(accent: model.isDirty(date: date) ? DailyTheme.orange : DailyTheme.cobalt, padding: 15)
                    }
                    .buttonStyle(.plain)
                }
            }.padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 50)
        }.scrollIndicators(.hidden).background(Color.clear).navigationTitle("Geçmiş").navigationBarTitleDisplayMode(.inline)
    }
}

struct MemoryScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @State private var selectedKind = "Tümü"
    private let kinds = ["Tümü", "Notlar", "Çıkarımlar", "Vizyonlar"]
    private var visibleRecords: [WorkspaceRecord] {
        model.memoryRecords.filter { record in
            switch selectedKind {
            case "Notlar": return record.kind == .note
            case "Çıkarımlar": return record.kind == .inference
            case "Vizyonlar": return record.kind == .vision
            default: return true
            }
        }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                DailySectionHeading(eyebrow: "Yaşayan bağlam", title: "Hafızan", detail: "Yazdıklarından ve çalışma alanından biriken notlar, çıkarımlar ve vizyonlar.")
                if !model.memoryRecords.isEmpty {
                    Text("\(model.memoryRecords.count) kayıt birikti")
                        .font(.subheadline.weight(.medium)).foregroundStyle(DailyTheme.muted)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(kinds, id: \.self) { kind in
                                Button(kind) { selectedKind = kind }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(selectedKind == kind ? .white : DailyTheme.cobalt)
                                    .padding(.horizontal, 16).padding(.vertical, 9)
                                    .background(selectedKind == kind ? DailyTheme.cobalt : DailyTheme.paper)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(DailyTheme.line))
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
                if model.memoryRecords.isEmpty { ContentUnavailableView("Hafıza kaydı yok", systemImage: "brain.head.profile", description: Text("Notlar PC'de bu hesaba eşitlendiğinde burada görünür.")) }
                if !model.memoryRecords.isEmpty && visibleRecords.isEmpty {
                    Text("Bu konuda henüz kayıt yok.").font(.subheadline).foregroundStyle(DailyTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading).dailyCard()
                }
                ForEach(visibleRecords) { record in
                    NavigationLink { MemoryDetail(record: record) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: record.kind == .inference ? "point.3.connected.trianglepath.dotted" : record.kind == .vision ? "sparkles" : "person.text.rectangle")
                                .font(.title3).foregroundStyle(record.kind == .inference ? DailyTheme.orange : DailyTheme.cobalt)
                                .frame(width: 38)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(String(record.key.dropFirst(record.kind.rawValue.count + 1))).font(.headline)
                                Text(record.kind == .note ? "Not / kişi bilgisi" : record.kind == .inference ? "Çıkarım" : "Proje vizyonu")
                                    .font(.caption).foregroundStyle(DailyTheme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(DailyTheme.muted)
                        }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .dailyCard(accent: record.kind == .inference ? DailyTheme.orange : DailyTheme.cobalt, padding: 15)
                    }
                    .buttonStyle(.plain)
                }
            }.padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 50)
        }.scrollIndicators(.hidden).background(Color.clear).navigationTitle("Hafıza").navigationBarTitleDisplayMode(.inline)
    }
}

private struct MemoryDetail: View {
    let record: WorkspaceRecord
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DailySectionHeading(eyebrow: "Ayrıntı", title: "Hafıza kaydı")
                if let payload = try? record.payload() {
                    if let note = payload.string { Text(note).textSelection(.enabled) }
                    else if let row = payload.object {
                        ForEach(row.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 4) {
                                DailyEyebrow(text: memoryLabel(key), color: DailyTheme.muted)
                                Text(displayValue(row[key]!)).font(.system(size: 17, design: .default)).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).dailyCard(accent: DailyTheme.cobalt, padding: 15)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 26)
        }.scrollIndicators(.hidden).background(Color.clear).navigationTitle("Hafıza kaydı").navigationBarTitleDisplayMode(.inline)
    }

    private func displayValue(_ value: JSONValue) -> String {
        if value == .null { return "—" }
        return value.string ?? (try? value.canonical()) ?? "—"
    }
    private func memoryLabel(_ key: String) -> String {
        let labels = ["statement": "Çıkarım", "scope": "Kapsam", "support_count": "Destek sayısı", "active": "Etkin (1/0)",
                      "first_seen_at": "İlk gözlem", "last_seen_at": "Son gözlem", "counter_evidence_json": "Karşı kanıtlar",
                      "project_name": "Proje", "vision": "Vizyon", "project_essence_now": "Projenin özü",
                      "next_meaningful_move": "Sonraki anlamlı adım", "negative_drift": "Olumsuz sapma", "confidence": "Güven"]
        return labels[key] ?? key
    }
}
