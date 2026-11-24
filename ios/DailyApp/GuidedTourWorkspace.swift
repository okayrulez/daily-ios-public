import SwiftUI
import DailyCore

/// Same native tabs and shared surfaces as the app, with local-only example actions.
struct GuidedTourWorkspace: View {
    @EnvironmentObject private var tour: GuidedTourController
    var body: some View {
        TabView(selection: Binding(get: { tour.stage.tab }, set: { _ in })) {
            NavigationStack {
                Group {
                    if tour.stage == .savedDay { GuidedTourSavedDay() } else { writer }
                }.background { nativeTabProbe }
            }
                .tabItem { Label("Bugün", systemImage: "square.and.pencil") }.tag(WorkspaceTab.today)
            NavigationStack {
                Group {
                    if tour.stage == .emotionDay { GuidedTourEmotionExperience() }
                    else if tour.stage == .emotionFlow { GuidedTourEmotionExperience(showsFlow: true) }
                    else { GuidedTourAgenda() }
                }.background { nativeTabProbe }
            }
                .tabItem { Label("Ajanda", systemImage: "calendar") }.tag(WorkspaceTab.agenda)
            NavigationStack { questions.background { nativeTabProbe } }
                .tabItem { Label("Sorular", systemImage: "bubble.left.and.bubble.right") }.tag(WorkspaceTab.questions)
            NavigationStack {
                Group {
                    if tour.isMap { GuidedTourMapExperience() }
                    else { Color.clear }
                }
                .background { nativeTabProbe }
                .toolbar(.hidden, for: .navigationBar)
            }
                .tabItem { Label("Haritalar", systemImage: "point.3.connected.trianglepath.dotted") }.tag(WorkspaceTab.maps)
            NavigationStack { settings.background { nativeTabProbe } }
                .tabItem { Label("Ayarlar", systemImage: "gearshape") }.tag(WorkspaceTab.settings)
        }
        .tint(DailyTheme.cobalt)
        .toolbarBackground(DailyTheme.paper, for: .tabBar).toolbarBackground(.visible, for: .tabBar)
    }

    private var nativeTabProbe: some View {
        TourNativeTabTarget(registry: tour.spotlight, label: tour.tabLabel).frame(width: 1, height: 1)
    }

    private var writer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(Date(), style: .date).font(.subheadline.weight(.medium)).foregroundStyle(DailyTheme.muted)
                DailyJournalWritingCard(progress: min(1, Double(tour.exampleText.filter { !$0.isWhitespace }.count) / 1200)) {
                    Text(tour.exampleText.isEmpty ? tour.language.text("Buradan başla…") : tour.exampleText)
                        .frame(minHeight: 224, alignment: .topLeading)
                        .accessibilityIdentifier("tour-example-text")
                }.tourHighlight("writer")
                Text("Örnek taslak").font(.footnote).foregroundStyle(DailyTheme.muted)
            }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 300)
        }
        .background { DailyCanvas { Color.clear } }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { if tour.stage == .daily { tour.advance() } } label: {
                    DailyFlowMark(isRunning: tour.stage == .analysing, showsControl: true)
                        .frame(width: 86, height: 40).frame(width: 108, height: 44)
                }.buttonStyle(.plain).tourHighlight("daily")
                    .accessibilityLabel("Örnek Daily butonu").accessibilityIdentifier("tour-daily-logo")
            }
            ToolbarItem(placement: .topBarLeading) { exampleBadge }
            ToolbarItem(placement: .topBarTrailing) { Image(systemName: "bell").foregroundStyle(DailyTheme.cobalt).accessibilityHidden(true) }
        }
    }

    private var questions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DailySectionHeading(eyebrow: "Örnek", title: "Söz sende.", detail: "Günlüğünden doğan bir takip sorusu.")
                VStack(alignment: .leading, spacing: 14) {
                    Label("Yüzmeden 30 dakika önce hatırlatayım mı?", systemImage: "bell.badge")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Salı ve perşembe 17.30 için.").font(.footnote).foregroundStyle(DailyTheme.muted)
                    HStack(spacing: 10) {
                        answer("Evet", value: true)
                        answer("Hayır", value: false)
                    }
                    HStack {
                        Text("Örnek yanıt").font(.caption).foregroundStyle(DailyTheme.muted)
                        Spacer()
                        Button { tour.advance() } label: {
                            Label("Onayı uygula", systemImage: "checkmark").font(.subheadline.bold())
                                .padding(.horizontal, 16).frame(minHeight: 44)
                                .foregroundStyle(.white).background(DailyTheme.navy, in: Capsule())
                        }.buttonStyle(.plain).disabled(tour.simulation.reminder == nil)
                    }
                }.padding(20).dailyGlass(accent: DailyTheme.energy).tourHighlight("question")
            }.padding(20).padding(.bottom, 300)
        }
        .background { DailyCanvas { Color.clear } }
        .navigationTitle("Günlüğünün soruları").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func answer(_ title: String, value: Bool) -> some View {
        let selected = tour.simulation.reminder == value
        return Button { tour.answer(value) } label: {
            Label(LocalizedStringKey(title), systemImage: selected ? "checkmark.circle.fill" : "circle")
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                .background(selected ? DailyTheme.energy.opacity(0.16) : .white, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? DailyTheme.mint : DailyTheme.line, lineWidth: selected ? 1.5 : 1) }
        }.buttonStyle(.plain).accessibilityLabel("Örnek yanıt: \(tour.language.text(title))")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var settings: some View {
        if tour.stage == .exportPreview {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("AI seni tanıyarak başlasın.").font(.title2.bold())
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ne için kullanacaksın?").font(.headline)
                        Text("Konuşma tarzıma uygun bir yazı hazırlamak.").font(.subheadline)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(DailyTheme.paleBlue, in: RoundedRectangle(cornerRadius: 13))
                        Label("Zihin haritaların + kullanım amacın", systemImage: "doc.text")
                            .font(.footnote).foregroundStyle(DailyTheme.cobalt)
                    }.padding(18).dailyGlass().tourHighlight("export-preview")
                    PersonalContextUsageSteps()
                }.padding(20).padding(.bottom, 340)
            }.background { DailyCanvas { Color.clear } }
                .navigationTitle("Zihin haritalarını paylaş").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(DailyTheme.canvas, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
        } else if tour.stage == .firebase || tour.stage == .account {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Ayarlar").font(.system(size: 29, weight: .semibold))
                    DailyTourAccountCard(kind: tour.stage == .firebase ? .firebase : .chatGPT) {
                        tour.connectionSetup = tour.stage == .firebase ? .firebase : .chatGPT
                    }
                        .tourHighlight(tour.stage == .firebase ? "firebase" : "account")
                }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 320)
            }.background { DailyCanvas { Color.clear } }
                .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Ayarlar").font(.system(size: 29, weight: .semibold))
                    Button { tour.advance() } label: { DailyMemoryExportCard() }
                        .buttonStyle(.plain).tourHighlight("export").accessibilityIdentifier("tour-export-card")
                    HStack(spacing: 14) {
                        DailyServiceIcon(kind: .firebase, symbol: "externaldrive")
                        Text("Kendi Firebase veritabanın").font(.subheadline.weight(.semibold))
                        Spacer()
                    }.padding(18).dailyGlass()
                    HStack(spacing: 14) {
                        DailyServiceIcon(kind: .chatGPT, symbol: "sparkles")
                        Text("Kendi AI hesabın").font(.subheadline.weight(.semibold))
                        Spacer()
                    }.padding(18).dailyGlass()
                }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 300)
            }.background { DailyCanvas { Color.clear } }
                .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        }
    }
    private var exampleBadge: some View {
        Text("ÖRNEK").font(.system(size: 9, weight: .bold)).tracking(1)
            .foregroundStyle(DailyTheme.mint).padding(7).background(DailyTheme.paleBlue, in: Capsule())
    }
}

/// Read-only sample content. All rehearsal choices disappear when this stop closes.
private struct GuidedTourSavedDay: View {
    private enum Detail: String, Identifiable {
        case changes, reflection
        var id: Self { self }
    }
    @EnvironmentObject private var tour: GuidedTourController
    @State private var detail: Detail?
    @State private var editorOpen = false
    @State private var sampleAdded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Örnek salı").font(.subheadline).foregroundStyle(DailyTheme.muted)
                if editorOpen {
                    HStack {
                        Button("Kapat") { editorOpen = false }
                        Spacer()
                        Button("Notu ekle") { editorOpen = false; sampleAdded = true }
                    }.frame(minHeight: 44)
                    DailyJournalWritingCard {
                        Text("Akşam çantamı hazırladım. Perşembe yeniden yüzmeye gideceğim.")
                    }
                } else {
                    action("Yeni not ekle", "square.and.pencil") {
                        editorOpen = true; sampleAdded = false
                    }
                    if sampleAdded { Label("Örnek not güne eklendi.", systemImage: "checkmark").font(.footnote) }
                    action("Ne değiştiğini gör", "arrow.up.right") { detail = .changes }
                    action("Günün yorumunu gör", "sparkles") { detail = .reflection }
                }
            }.tourHighlight("saved-day")
                .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 320)
        }
        .background { DailyCanvas { Color.clear } }
        .navigationTitle("Bugün").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detail) { item in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if item == .changes {
                            Text("\(tour.exampleGraph.nodes.count) yeni not · \(tour.exampleGraph.edges.count) yeni bağlantı")
                            Label("Düzenli hareket → Yüzme", systemImage: "link")
                            if let reminder = tour.simulation.reminder {
                                Label("18.00 · Yüzme", systemImage: "calendar")
                                if reminder { Label("17.30 · Yüzme hatırlatması", systemImage: "bell") }
                            }
                        } else {
                            Text("İşte gerildiğini, yüzdükten sonra rahatladığını yazmışsın. Akşam hâlâ biraz yorgun olman, yüzmenin sana iyi geldiği o anı silmiyor.")
                            Text("Tavsiyeler").font(.headline)
                            Text("Bir sonraki yüzme gününde eve dönerken nasıl hissettiğini not etmek ister misin?")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                }.navigationTitle(LocalizedStringKey(item == .changes ? "Ne değişti?" : "Yorum ve tavsiyeler"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { detail = nil } } }
            }.presentationDetents([.medium, .large])
        }
    }

    private func action(_ title: LocalizedStringKey, _ icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(DailyTheme.cobalt)
                .journalActionCard(accent: DailyTheme.energy).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct GuidedTourAgenda: View {
    @EnvironmentObject private var tour: GuidedTourController
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
    private var calendar: Calendar { JournalCalendar.calendar() }
    private var sampleDate: Date {
        calendar.nextDate(after: calendar.startOfDay(for: Date()).addingTimeInterval(-1),
                          matching: DateComponents(weekday: 3), matchingPolicy: .nextTime) ?? Date()
    }
    private var count: Int { tour.simulation.reminder == true ? 2 : 1 }
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 16) {
                        HStack {
                            Text(sampleDate, format: .dateTime.month(.wide).year()).font(.system(size: 24, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.left"); Image(systemName: "chevron.right").padding(.leading, 16)
                        }
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(["Pzt", "Sal", "Çar", "Per", "Cum", "Cmt", "Paz"], id: \.self) {
                                Text(LocalizedStringKey($0)).font(.caption).foregroundStyle(DailyTheme.muted)
                            }
                            let cells = JournalCalendar.cells(in: sampleDate)
                            ForEach(cells.indices, id: \.self) { index in
                                if let date = cells[index] {
                                    let selected = calendar.isDate(date, inSameDayAs: sampleDate)
                                    VStack(spacing: 6) {
                                        Text("\(calendar.component(.day, from: date))").font(.system(size: 17, weight: selected ? .bold : .medium, design: .rounded))
                                        if selected {
                                            Text("\(count)").font(.system(size: 12, weight: .semibold)).frame(width: 20, height: 20)
                                                .background(DailyTheme.energy.opacity(0.24), in: Capsule())
                                        } else { Color.clear.frame(height: 20) }
                                    }.frame(maxWidth: .infinity).frame(height: min(64, max(44, proxy.size.height * 0.075)))
                                        .background(selected ? DailyTheme.paleBlue : .white, in: RoundedRectangle(cornerRadius: 13))
                                        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? DailyTheme.mint : DailyTheme.line.opacity(0.4), lineWidth: selected ? 1.8 : 0.5) }
                                } else { Color.clear.frame(height: 44) }
                            }
                        }
                    }.tourHighlight("agenda")
                    Text("Örnek salı · \(count) aktivite").font(.headline)
                        .accessibilityIdentifier("tour-agenda-count")
                    if tour.simulation.reminder == true { entry("17.30", "Hatırlatma", icon: "bell.badge") }
                    entry("18.00", "Yüzme", icon: "figure.pool.swim")
                }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 300)
            }
        }.background { DailyCanvas { Color.clear } }
            .navigationTitle("Ajanda").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
    private func entry(_ time: String, _ title: String, icon: String) -> some View {
        HStack(spacing: 18) {
            Text(time).font(.subheadline.bold().monospacedDigit())
            Label(LocalizedStringKey(title), systemImage: icon).font(.headline)
            Spacer()
        }.padding(18).dailyGlass(cornerRadius: 22, accent: DailyTheme.energy)
    }
}
