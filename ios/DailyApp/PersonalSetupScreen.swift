import SwiftUI
import UniformTypeIdentifiers
import DailyCore

struct PersonalSetupScreen: View {
    var firebaseOnly = false
    @EnvironmentObject private var model: WorkspaceModel
    @ObservedObject private var connection = ChatGPTConnection.shared
    @State private var importing = false
    @State private var accountOpen = false
    @State private var resolveConflict = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DailySectionHeading(eyebrow: "Kontrol sende", title: "Kendi alanın.",
                    detail: "Günlüklerin ve haritaların cihazında. Firebase, farklı cihazlarını eşitlemek için isteğe bağlıdır.")
                VStack(alignment: .leading, spacing: 12) {
                    Label("Cihazda kayıt", systemImage: "iphone").font(.headline)
                    Text("Yazıların, yanıtların, ajandan ve haritaların Firebase olmadan da kaydedilir. AI analizi için internet ve kendi AI hesabın gerekir.").font(.subheadline)
                }.dailyCard()
                VStack(alignment: .leading, spacing: 12) {
                    Label("Kendi Firebase veritabanın", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                    Text("Bilgisayarla ortak kullanmak istersen Google hesabınla giriş yap. Kendi projeni seç veya yeni bir proje oluştur; dosya indirmen gerekmez.").font(.subheadline)
                    NavigationLink { GoogleCloudSetupScreen() } label: { Label("Google ile bağlan", systemImage: "person.crop.circle.badge.checkmark") }
                        .buttonStyle(DailyPrimaryButtonStyle()).accessibilityIdentifier("setup-google-firebase")
                    NavigationLink { GoogleCloudSetupScreen() } label: { Label("Yeni Firebase projesi oluştur", systemImage: "plus.circle.fill") }
                        .buttonStyle(DailySecondaryButtonStyle()).accessibilityIdentifier("setup-create-firebase-project")
                    if model.cloudConnected {
                        Text(model.firebaseProjectID).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Bekleyen eşitleme: \(model.pendingCloudWrites)").font(.caption)
                        Button("Şimdi eşitle") { Task { await model.syncCloudNow() } }.disabled(model.cloudBusy)
                        Button("Yalnız bu cihazda devam et") { model.pauseCloudSync() }.font(.footnote).disabled(model.cloudBusy)
                    }
                    if !model.cloudNotice.isEmpty { Text(model.cloudNotice).font(.footnote).textSelection(.enabled) }
                    if !model.cloudSyncNotice.isEmpty { Text(model.cloudSyncNotice).font(.footnote).foregroundStyle(DailyTheme.orange).textSelection(.enabled) }
                    if model.cloudHasConflict {
                        Button("Bulut sürümünü aç; cihaz sürümünü ayrı koru") { resolveConflict = true }
                            .buttonStyle(DailySecondaryButtonStyle()).disabled(model.cloudBusy)
                    }
                    DisclosureGroup("Geliştirici ayarları") {
                        Text("Mevcut bir geliştirici yapılandırmasını kullanıyorsan iOS bağlantı dosyanı buradan aktarabilirsin. Normal Google bağlantısında bu adım gerekmez.").font(.caption).padding(.vertical, 8)
                        if model.hasPreviousFirebaseSetup && !model.cloudConnected && !model.legacySignInAvailable {
                            Button("Cihazda saklanan önceki Firebase kurulumunu aç") { model.restorePreviousFirebaseSetup() }
                        }
                        Button("Geliştirici yapılandırmasını içe aktar") { importing = true }
                            .disabled(model.cloudBusy || model.phoneAnalysisBusy)
                        if model.legacySignInAvailable { Button("Mevcut Firebase hesabına giriş yap") { accountOpen = true } }
                    }.font(.footnote)
                }.dailyCard()
                if !firebaseOnly {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Kendi AI hesabın", systemImage: "sparkles").font(.headline)
                        Text("ChatGPT'ye kendi hesabınla giriş yap. Modelini ve düşünme seviyesini seç; kullanım hakkı o hesaba aittir.").font(.subheadline)
                        NavigationLink { PhoneAnalysisSettingsScreen() } label: { Label("ChatGPT bağlantısını aç", systemImage: "sparkles") }
                        if connection.ready { Label(connection.model, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(DailyTheme.mint) }
                    }.dailyCard()
                    NavigationLink { NotificationSettingsScreen() } label: { Label("Bildirim ayarları", systemImage: "bell") }.buttonStyle(DailySecondaryButtonStyle())
                    NavigationLink { SampleWorkspaceScreen() } label: { Label("Örnek verilerle dene", systemImage: "play.rectangle") }.buttonStyle(DailySecondaryButtonStyle())
                }
                if model.deviceProfiles.count > 1 {
                    DisclosureGroup("Cihazdaki diğer çalışma alanları") {
                        ForEach(model.deviceProfiles) { profile in
                            Button { model.openDeviceProfile(profile) } label: {
                                VStack(alignment: .leading) {
                                    Text(profile.projectID == "daily-local" ? "Bu cihazdaki kişisel alan · " + String(profile.uid.prefix(6)) : profile.projectID)
                                    if !profile.email.isEmpty { Text(profile.email).font(.caption) }
                                }.padding(.vertical, 6)
                            }.disabled(model.cloudBusy || model.phoneAnalysisBusy)
                        }
                    }.font(.footnote)
                    Text("Alanlar ayrı saklanır. Başka bir alanı açmak mevcut kayıtlarını silmez.").font(.caption).foregroundStyle(DailyTheme.muted)
                }
            }.padding(24).frame(maxWidth: 600)
        }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Bulut sürümü açılsın mı?", isPresented: $resolveConflict, titleVisibility: .visible) {
                Button("Cihaz kopyasını koru ve bulut sürümünü aç") { Task { await model.useCloudVersionKeepingLocalCopy() } }
            } message: {
                Text("Cihazındaki sürüm ayrı bir yerel çalışma alanına kaydedilir. Bekleyen değişiklikleri buluta yazmadan buluttaki sürüm açılır. Yerel kopyanı aşağıdaki çalışma alanlarından tekrar açabilirsin.")
            }
            .sheet(isPresented: $accountOpen) { NavigationStack { AccountScreen(showsNavigationBar: true) } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList]) { result in
                if case .success(let url) = result { model.importPersonalFirebase(from: url, updatingCurrent: model.legacySignInAvailable) }
            }
    }
}

struct GoogleCloudSetupScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "dAIly kişisel alanım"
    @State private var region = "eur3"
    @State private var transferLocal = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DailySectionHeading(eyebrow: "", title: "Cihazların birlikte çalışsın.",
                    detail: "Telefon ve bilgisayarda aynı haritaları kullanmak için kendi Google hesabınla bir veritabanı bağla. İstersen yalnız cihazında da devam edebilirsin.")
                Button { Task { await model.beginGoogleCloudConnection() } } label: {
                    Label(model.googleCloudSignedIn ? "Google hesabını değiştir" : "Google ile giriş yap", systemImage: "person.crop.circle")
                }.buttonStyle(DailyPrimaryButtonStyle()).disabled(model.cloudBusy).accessibilityIdentifier("google-cloud-signin")
                if model.cloudBusy { ProgressView().frame(maxWidth: .infinity) }
                if !model.cloudNotice.isEmpty { Text(model.cloudNotice).font(.footnote).textSelection(.enabled).accessibilityIdentifier("google-cloud-status") }
                if model.googleCloudSignedIn {
                    if !model.googleProjects.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Mevcut projen").font(.headline)
                            ForEach(model.googleProjects) { project in
                                Button {
                                    Task { if await model.connectGoogleProject(project, transferLocal: transferLocal) { dismiss() } }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) { Text(project.name).font(.subheadline.bold()); Text(project.projectID).font(.caption) }
                                        Spacer(); Image(systemName: "chevron.right")
                                    }.padding(.vertical, 8)
                                }.disabled(model.cloudBusy)
                            }
                        }.dailyCard()
                    }
                }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Yeni Firebase projesi oluştur").font(.headline)
                        TextField("Proje adı", text: $name).textInputAutocapitalization(.sentences)
                            .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                        DisclosureGroup("Kayıt aktarımı ve konum") {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Bu cihazdaki kayıtları boş çalışma alanına aktar", isOn: $transferLocal).font(.subheadline)
                                Text("Dolu bir çalışma alanına yerel kayıtlar otomatik karıştırılmaz. Cihazdaki önceki alanın korunur; Ayarlar'dan tekrar açabilirsin.").font(.caption).foregroundStyle(DailyTheme.muted)
                                Picker("Veritabanı konumu", selection: $region) { Text("Avrupa").tag("eur3"); Text("Amerika").tag("nam5") }.font(.subheadline)
                            }.padding(.top, 10)
                        }.font(.footnote)
                        Button {
                            Task {
                                if !model.googleCloudSignedIn { await model.beginGoogleCloudConnection() }
                                guard model.googleCloudSignedIn else { return }
                                if await model.createGoogleProject(name: name, region: region, transferLocal: transferLocal) { dismiss() }
                            }
                        } label: { Label(model.googleCloudSignedIn ? "Veritabanımı oluştur ve bağla" : "Google ile giriş yap ve oluştur", systemImage: "plus.circle") }
                            .buttonStyle(DailySecondaryButtonStyle()).disabled(model.cloudBusy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("google-create-firebase-project")
                        Text("Mevcut cihaz kayıtların korunur. Aktarım seçmezsen yeni alan ayrı açılır.").font(.caption).foregroundStyle(DailyTheme.muted)
                    }.padding(18).dailyGlass(accent: DailyTheme.energy)
                if model.googleCloudSignedIn {
                    DisclosureGroup("Google izinleri hakkında") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Google, proje oluşturmak ve seçtiğin Firestore alanına yazmak için bulut izni ister. dAIly verilerini yalnız seçtiğin projedeki kendi kullanıcı alanına kaydeder.")
                            Text("Proje Google hesabında oluşturulur. Faturalandırma hesabı bağlanmaz; Google'ın ücretsiz kotaları ve proje oluşturma izinleri geçerlidir.")
                            Link("Google'da uygulama izinlerini yönet", destination: URL(string: "https://myaccount.google.com/connections")!)
                        }.padding(.top, 10)
                    }.font(.footnote).foregroundStyle(DailyTheme.muted)
                }
            }.padding(24).frame(maxWidth: 600)
        }.navigationTitle("Google bağlantısı").navigationBarTitleDisplayMode(.inline).scrollDismissesKeyboard(.interactively)
            .toolbarBackground(DailyTheme.canvas, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
    }
}

/// Production-available, local sample flow. It never signs in, invokes AI or writes Firebase.
struct SampleWorkspaceScreen:View {
    @State private var text="Salı ve perşembe 18.00'de yüzmeye zaman ayırmak istiyorum."
    @State private var result=false
    @State private var reminded=false
    @State private var note=""
    private var graph:MobileAtlas.Graph? {
        let nodes=[("plan","Düzenli hareket"),("swim","Yüzme"),("time","Salı / Perşembe 18.00")].map { id,label in
            ["id":id,"label":label,"status":"observation","summary":"Örnek günlükten türetilen örnek not.","updatedAt":"2026-11-03","topicPath":["Örnek"]] as [String:Any]
        }
        let edges=[["id":"a","source":"plan","target":"swim","relation":"etkinlik"],["id":"b","source":"swim","target":"time","relation":"planlanan zaman"]]
        guard let data=try? JSONSerialization.data(withJSONObject:["nodes":nodes,"edges":edges]) else {return nil}
        return try? JSONDecoder().decode(MobileAtlas.Graph.self,from:data)
    }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Label("Örnek veriler · AI çağrısı yok",systemImage:"testtube.2").font(.caption.bold()).foregroundStyle(DailyTheme.cobalt)
                Text("Bir yazıdan bağlantıya.").font(.title.bold())
                TextEditor(text:$text).frame(height:140).padding(10).background(DailyTheme.paper,in:RoundedRectangle(cornerRadius:16))
                Button("Örnek akışı göster",systemImage:"play.fill") {result=true}.buttonStyle(DailyPrimaryButtonStyle())
                Text("Aşağıdaki hazır sonuçlar yüzme örneğini gösterir; değiştirdiğin metin analiz edilmez. Buradaki hiçbir işlem gerçek ajandana veya Firebase'e kaydolmaz.").font(.footnote).foregroundStyle(DailyTheme.muted)
                if result {
                    Text("Örnek sonuç: 3 not · 2 bağlantı · yüzme planı").font(.headline)
                    Toggle("30 dakika önce hatırlatayım mı?",isOn:$reminded)
                    Text("Bu soruya vereceğin yanıt, gerçek kullanımda hatırlatma isteğini netleştirir.").font(.caption)
                    TextField("Hangi havuzda yüzeceksin?",text:$note,axis:.vertical).padding().background(DailyTheme.paper,in:RoundedRectangle(cornerRadius:16))
                    if let graph { OrganicAtlas(graph:graph,selectedID:"",select:{_ in}).frame(height:300).clipShape(RoundedRectangle(cornerRadius:20)) }
                    Label("Salı / Perşembe · 18.00 · Yüzme",systemImage:"calendar")
                    if reminded {Label("Örnek hatırlatma: 17.30",systemImage:"bell")}
                }
            }.padding(24)
        }.navigationTitle("Örnek kullanım").navigationBarTitleDisplayMode(.inline).scrollDismissesKeyboard(.interactively)
    }
}
