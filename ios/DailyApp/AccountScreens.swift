import SwiftUI
import UniformTypeIdentifiers

struct AccountScreen: View {
    var showsNavigationBar = false
    @EnvironmentObject private var model: WorkspaceModel
    @State private var email = ""
    @State private var password = ""
    @State private var createAccount = false
    @State private var showEmail = false
    @State private var showConnectionHelp = false
    @State private var importingFirebase = false
    @State private var setupOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image("DailyMark").resizable().scaledToFit()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .accessibilityLabel("dAIly")
                    Spacer()
                }.padding(.top, 20)

                VStack(alignment: .leading, spacing: 14) {
                    DailyEyebrow(text: "Kendine bir yer aç")
                    Text("Aklından geçenler,\nyanında kalsın.")
                        .font(.system(size: 38, weight: .medium, design: .default))
                        .tracking(-1.3).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Gününü yaz. Düşüncelerine dön.\nSana iyi gelen küçük adımları hatırla.")
                        .font(.subheadline).lineSpacing(4).foregroundStyle(DailyTheme.muted)
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("BUGÜNDEN BİR NOT", systemImage: "square.and.pencil")
                            .font(.system(size: 10, weight: .semibold)).tracking(1)
                        Spacer()
                        Image(systemName: "sparkle").foregroundStyle(DailyTheme.orange)
                    }.foregroundStyle(DailyTheme.muted)
                    Text("“Bugün aklımda kalan…”")
                        .font(.system(size: 23, weight: .regular, design: .default)).italic()
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Tek cümleyle başlayabilirsin.")
                        .font(.caption).foregroundStyle(DailyTheme.muted)
                    Divider().overlay(DailyTheme.line)
                    HStack(spacing: 18) {
                        Label("Yazıların", systemImage: "book.closed")
                        Label("Ajandan", systemImage: "calendar")
                        Label("Takibin", systemImage: "bubble.left")
                    }.font(.caption2.weight(.medium)).foregroundStyle(DailyTheme.cobalt)
                }.dailyCard(padding: 20)

                VStack(spacing: 13) {
                    Button("Bu cihazda başla") { model.continueOnDevice() }
                        .buttonStyle(DailyPrimaryButtonStyle()).accessibilityIdentifier("start-on-device")
                    Text("Günlüklerin ve haritaların cihazında saklanır. Analiz için kendi AI hesabını bağlarsın.")
                        .font(.footnote).foregroundStyle(DailyTheme.muted).multilineTextAlignment(.center)
                    NavigationLink { GoogleCloudSetupScreen() } label: { Label("Google ile Firebase bağla", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(DailySecondaryButtonStyle()).accessibilityIdentifier("connect-own-firebase")
                    Text("İsteğe bağlı: Bilgisayarla ortak kullanmak için kendi veritabanını oluştur veya seç.")
                        .font(.caption).foregroundStyle(DailyTheme.muted).multilineTextAlignment(.center)
                    if model.legacySignInAvailable {
                        Button("Mevcut Firebase hesabıma giriş yap") { showEmail = true }.font(.footnote)
                    }
                    if let notice = model.authNotice ?? model.connectionDiagnostic {
                        Text(notice).font(.footnote).foregroundStyle(DailyTheme.orange)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                Button("Kurulum rehberi ve örnek kullanım") { setupOpen=true }.font(.subheadline)
                Text("Günün sende kalsın.")
                    .font(.system(size: 14, design: .default)).italic().foregroundStyle(DailyTheme.muted)
                    .frame(maxWidth: .infinity).padding(.bottom, 12)
            }
            .frame(maxWidth: 440).padding(.horizontal, 28).padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden).toolbar(showsNavigationBar ? .visible : .hidden, for: .navigationBar)
        .onChange(of: model.uid) { _, uid in if uid != nil { showEmail = false } }
        .sheet(isPresented: $showEmail) { emailSheet }
        .sheet(isPresented:$setupOpen) { NavigationStack { PersonalSetupScreen() } }
        .sheet(isPresented: $showConnectionHelp) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        DailySectionHeading(eyebrow: "Hesabın korunuyor", title: "Birlikte çözelim.",
                            detail: "Daha önce giriş yaptıysan, hesabına hazırlanmış güncel dAIly sürümünü yükle. Sırf bu ekranı gördüğün için yeni bir hesap oluşturma.")
                        DisclosureGroup("Gelişmiş bağlantı ayarları") {
                            Text("Kendi sunucu ayarlarını yönetiyorsan mevcut iOS yapılandırmanı buradan aktarabilirsin. Normal giriş için dosya hazırlaman gerekmez.")
                                .font(.footnote).foregroundStyle(DailyTheme.muted).padding(.vertical, 10)
                            Button("Yapılandırmayı içe aktar") { showConnectionHelp = false; importingFirebase = true }
                                .buttonStyle(DailySecondaryButtonStyle())
                        }
                    }.padding(24)
                }
                .background(DailyTheme.canvas).navigationTitle("Bağlantı yardımı")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { showConnectionHelp = false } } }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .fileImporter(isPresented: $importingFirebase, allowedContentTypes: [.propertyList]) { result in
            if case .success(let url) = result { model.importPersonalFirebase(from: url) }
        }
    }

    private var emailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DailySectionHeading(eyebrow: "dAIly", title: createAccount ? "Kendine bir alan aç." : "Kaldığın yerden devam.")
                    TextField("E-posta", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().dailyInput()
                    SecureField("Şifre", text: $password)
                        .textContentType(createAccount ? .newPassword : .password).dailyInput()
                    Button(createAccount ? "Hesap oluştur" : "Giriş yap") {
                        let submitted = password; password = ""
                        Task { await model.signIn(email: email, password: submitted, create: createAccount) }
                    }
                    .buttonStyle(DailyPrimaryButtonStyle())
                    .disabled(model.authBusy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    if model.authBusy { ProgressView("Giriş yapılıyor…") }
                    if let notice = model.authNotice ?? model.connectionDiagnostic {
                        Text(notice).font(.footnote).foregroundStyle(DailyTheme.orange)
                    }
                    Button(createAccount ? "Zaten hesabım var" : "Yeni hesap oluştur") { createAccount.toggle() }
                        .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                }.padding(24)
            }.background(DailyTheme.canvas)
                .navigationTitle("E-posta ile giriş").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { showEmail = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @EnvironmentObject private var tour: GuidedTourController
    @State private var importingFirebase = false
    @State private var settingsViewport = CGRect.zero
    @ObservedObject private var chatGPT = ChatGPTConnection.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Ayarlar").font(.system(size: 26, weight: .semibold))
                shareMindmaps
                settingsGroup("Bağlantılar") {
                    SettingsNavigationRow(title: "ChatGPT bağlantısı", detail: chatGPT.selectedModelName ?? "Kendi AI hesabın ve modelin", icon: "sparkles", kind: .chatGPT, status: chatGPT.settingsStatus) { PhoneAnalysisSettingsScreen() }

                    Divider().padding(.leading, 60)
                    SettingsNavigationRow(title: "Bildirimler", detail: "Hatırlatmalar ve bildirim saatleri", icon: "bell.badge", kind: .notifications, status: notificationConnectionStatus) { NotificationSettingsScreen() }
                    Divider().padding(.leading, 60)
                    SettingsNavigationRow(title: "Kurulum ve bağlantı kontrolü", detail: "Firebase ve hesaplarını kontrol et", icon: "checkmark.shield", kind: .firebase, status: firebaseConnectionStatus) { PersonalSetupScreen() }
                }
                settingsGroup("Kişisel alanın") {
                    SettingsNavigationRow(title: "Duygular ve emojiler", detail: "Ajandadaki duygu simgelerin", icon: "face.smiling", kind: .social) { EmotionSettingsScreen() }
                    Divider().padding(.leading, 60)
                    SettingsNavigationRow(title: "Yazma tercihleri", detail: "Tema, yazı tipi ve satır aralığı", icon: "textformat", kind: .memory) { WritingPreferencesScreen() }
                    Divider().padding(.leading, 60)

                    SettingsNavigationRow(title: "Uygulama dili", detail: "Türkçe / English", icon: "globe", kind: .language) { LanguageSettingsScreen() }
                    Divider().padding(.leading, 60)
                    SettingsNavigationRow(title: "Hafıza geçmişi", detail: "Notların ve düzeltmelerin", icon: "clock", kind: .memory) { MemoryTimelineScreen() }
                    Divider().padding(.leading, 60)
                    SettingsNavigationRow(title: "AI tüketim kaydı", detail: "Analizlerinin kullanım bilgileri", icon: "chart.bar", kind: .usage) { AIUsageScreen() }
                    Divider().padding(.leading, 60)
                    SettingsNavigationRow(title: "Işık akışı", detail: "Haritalarının hareketi", icon: "waveform.path", kind: .lightFlow) { AtlasMotionControls() }
                    Divider().padding(.leading, 60)
                    SettingsNavigationRow(title: "Sosyal profillerin", detail: "Bağlantıların ve araştırma tercihin", icon: "person.crop.circle.badge.plus", kind: .social) { SocialProfileScreen() }
                    Divider().padding(.leading, 60)
                    Button { tour.begin(model: model) } label: {
                        SettingsRowLabel(title: "Uygulama tanıtımı", detail: "Akışı yeniden keşfet", icon: "questionmark.circle", kind: .tutorial)
                    }.buttonStyle(DailySettingsPressStyle())
                }
                settingsGroup("Hesabın") {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 30)).foregroundStyle(DailyTheme.mint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.email.isEmpty ? "Bu cihazdaki alanın" : model.email).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                            Text(model.isDeviceOnly ? "Cihazda kayıt açık" : model.googleLinked ? "Google hesabın bağlı" : "Oturumun açık")
                                .font(.caption).foregroundStyle(DailyTheme.muted)
                        }
                        Spacer(minLength: 0)
                    }.padding(14)
                    if let notice = model.authNotice { Text(notice).font(.footnote).foregroundStyle(DailyTheme.orange).padding(.horizontal, 18) }
                    Divider().padding(.leading, 60)
                    SettingsNavigationRow(title: "Bağlantı ayrıntıları", detail: "Hesap ve sunucu durumu", icon: "network") { ConnectionStatusScreen() }
                }
                if model.legacySignInAvailable { DisclosureGroup("Gelişmiş bağlantı ayarları") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Hesabın zaten bağlı. Bu alan yalnız mevcut Firebase projenin bağlantı yapılandırmasını güncellemek içindir.").font(.footnote).foregroundStyle(DailyTheme.muted)
                        Button("Firebase yapılandırmasını güncelle") { importingFirebase = true }.buttonStyle(DailySecondaryButtonStyle())
                        Text(model.uid ?? "").font(.caption2).textSelection(.enabled)
                    }.padding(.top, 10)
                }.padding(18).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 22))
                }
                settingsGroup("Verilerin") {
                    Button { model.resetScreenOpen = true } label: {
                        SettingsRowLabel(title: "Sıfırla", detail: "Günlükler dahil bütün çalışma alanını temizle", icon: "arrow.counterclockwise", kind: .social)
                    }.buttonStyle(DailySettingsPressStyle())
                        .accessibilityIdentifier("settings-reset-workspace")
                }
                Button("Çıkış yap", role: .destructive) { Task { await model.signOut() } }
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(.red).padding(.top, 4)
                    .disabled(!model.busyDates.isEmpty || model.authBusy)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 28)
        }
        .scrollIndicators(.hidden).navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .environment(\.dailySettingsViewport, settingsViewport)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { settingsViewport = $0 }
        .task(id: model.companionScope) { await chatGPT.reloadAccounts() }
        .fileImporter(isPresented: $importingFirebase, allowedContentTypes: [.propertyList]) { result in
            if case .success(let url) = result { model.importPersonalFirebase(from: url, updatingCurrent: true) }
        }
    }

    private var notificationConnectionStatus: DailySettingsStatus {
        if !model.notificationsEnabled { return .init(title: "Hatırlatmalar kapalı", tone: .neutral) }
        if model.pushBusy { return .init(title: "Bildirim kaydı yapılıyor", tone: .neutral) }
        if model.remotePushEnabled { return .init(title: "Sunucu cihaz kaydı tamamlandı", tone: .success) }
        if model.companionNotificationsEnabled { return .init(title: "Yerel hatırlatmalar açık", tone: .success) }
        return .init(title: "Bildirim kurulumu gerekli", tone: .attention)
    }

    private var firebaseConnectionStatus: DailySettingsStatus {
        if model.checkingFirebase { return .init(title: "Bağlantı kontrol ediliyor", tone: .neutral) }
        if !model.cloudConnected { return .init(title: "Bu cihazda · isteğe bağlı", tone: .neutral) }
        if !model.cloudSyncNotice.isEmpty { return .init(title: "Eşitleme bekliyor", tone: .attention) }
        if model.cloudVerified { return .init(title: "Bağlantı doğrulandı", tone: .success) }
        if model.firebaseProjectID.isEmpty { return .init(title: "Kurulum gerekli", tone: .attention) }
        return .init(title: "Sunucu doğrulaması bekliyor", tone: .attention)
    }

    private var shareMindmaps: some View {
        NavigationLink { MindmapExportScreen() } label: { DailyMemoryExportCard() }
            .buttonStyle(DailySettingsPressStyle()).accessibilityIdentifier("settings-share-mindmaps")
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(title)).font(.subheadline.weight(.semibold)).foregroundStyle(DailyTheme.muted).padding(.leading, 4)
            VStack(spacing: 0, content: content)
                .background(.white.opacity(0.91), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(DailyTheme.line.opacity(0.4), lineWidth: 0.7).allowsHitTesting(false) }
        }
    }
}

private struct SettingsNavigationRow<Destination: View>: View {
    let title: String
    let detail: String
    let icon: String
    let kind: DailySettingsKind
    let status: DailySettingsStatus?
    let destination: Destination
    init(title: String, detail: String, icon: String, kind: DailySettingsKind = .general,
         status: DailySettingsStatus? = nil, @ViewBuilder destination: () -> Destination) {
        self.title = title; self.detail = detail; self.icon = icon; self.kind = kind
        self.status = status; self.destination = destination()
    }
    var body: some View {
        NavigationLink { destination } label: { SettingsRowLabel(title: title, detail: detail, icon: icon, kind: kind, status: status) }
            .buttonStyle(DailySettingsPressStyle(color: kind.color))
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let detail: String
    let icon: String
    var kind: DailySettingsKind = .general
    var status: DailySettingsStatus? = nil
    var body: some View {
        HStack(spacing: 11) {
            DailyServiceIcon(kind: kind, symbol: icon, side: 38)
            VStack(alignment: .leading, spacing: 3) {
                Group {
                    if kind == .lightFlow { DailySettingsLightTitle(title: LocalizedStringKey(title)) }
                    else { Text(LocalizedStringKey(title)).foregroundStyle(DailyTheme.ink) }
                }.font(.subheadline.weight(.semibold))
                Text(LocalizedStringKey(detail)).font(.caption).foregroundStyle(DailyTheme.muted)
                if let status {
                    status.badge
                }
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(kind.color)
        }.padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(LinearGradient(colors: [kind.surface.opacity(0.32), .white.opacity(0)], startPoint: .leading, endPoint: .trailing))
            .overlay(alignment: .leading) {
                Capsule().fill(kind.color.opacity(0.35)).frame(width: 2, height: 24)
                    .padding(.leading, 2).allowsHitTesting(false).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
    }
}

private extension View {
    func dailyInput() -> some View {
        self.padding(.horizontal, 14).frame(minHeight: 50)
            .background(DailyTheme.paleBlue)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
