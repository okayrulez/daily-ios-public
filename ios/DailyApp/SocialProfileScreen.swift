import SwiftUI
import DailyCore

struct SocialProfileScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile = SocialProfile()
    @State private var introduction = ""
    @State private var busy = false
    @State private var notice = ""
    @State private var loadedScope = ""
    @State private var report: AnalysisReplyPresentation?
    @FocusState private var editing: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    DailyServiceIcon(kind: .social, symbol: "person.crop.circle.badge.plus", side: 42)
                    Text("Seni biraz daha tanısın.").font(.system(size: 25, weight: .semibold))
                }
                Text("Adını ve araştırılmasını istediğin hesapları istediğin biçimde yaz. Kullanıcı adı, bağlantı veya kısa açıklama yeterli.")
                    .font(.subheadline).foregroundStyle(DailyTheme.muted)
                TextEditor(text: $introduction)
                    .frame(minHeight: 126, idealHeight: 144, maxHeight: 160)
                    .scrollContentBackground(.hidden).textInputAutocapitalization(.sentences).autocorrectionDisabled()
                    .focused($editing).padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .topLeading) {
                        if introduction.isEmpty {
                            Text("Örn. Adım Deniz. Insta: @deniz, LinkedIn’im: deniz-yilmaz…")
                                .foregroundStyle(DailyTheme.muted).padding(.horizontal, 16).padding(.vertical, 18)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(DailySettingsKind.social.color.opacity(0.25), lineWidth: 1).allowsHitTesting(false) }
                    .accessibilityLabel("Adın ve sosyal profil bilgilerin").accessibilityIdentifier("social-profile-introduction")
                    .disabled(busy || model.profileResearchRunning)
                Toggle(isOn: $profile.researchAllowed) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Açık web üzerinden beni araştır").font(.subheadline.weight(.semibold))
                        Text("Yazdığım ad ve hesaplarla açık web araştırması başlatılmasını onaylıyorum.")
                            .font(.caption).foregroundStyle(DailyTheme.muted)
                    }
                }.tint(DailySettingsKind.social.color).padding(14)
                    .background(DailySettingsKind.social.surface, in: RoundedRectangle(cornerRadius: 22))
                    .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(DailySettingsKind.social.color.opacity(0.25), lineWidth: 1).allowsHitTesting(false) }
                    .accessibilityIdentifier("social-research-consent")
                    .disabled(busy || model.profileResearchRunning)
                DisclosureGroup("Araştırma ve gizlilik") {
                    Text("Araştırmayı başlatınca bu alandaki bilgiler kendi ChatGPT hesabın üzerinden OpenAI’a gönderilir. Gizli hesaplar, özel mesajlar ve giriş isteyen içeriklere erişim garanti edilmez. Kullanım hakkın tüketilebilir. Onayı kapatmak yeni araştırmayı durdurur; önceden oluşmuş notları Haritalar’dan yönetebilirsin.")
                        .font(.footnote).lineSpacing(4).foregroundStyle(DailyTheme.muted).padding(.top, 10)
                }.font(.subheadline.weight(.medium)).tint(DailySettingsKind.social.color)
                if !notice.isEmpty { Text(LocalizedStringKey(notice)).font(.callout).accessibilityIdentifier("social-profile-notice") }
                Button {
                    editing = false; busy = true; notice = ""
                    Task {
                        do {
                            let clean = try profile.replacingIntroduction(introduction).validated()
                            try await model.saveSocialProfile(clean)
                            guard loadedScope == model.companionScope else { busy = false; return }
                            notice = clean.researchAllowed ? "" : "Profil bilgilerin kaydedildi."
                            busy = false
                        } catch let error as SocialProfile.ProfileError {
                            busy = false
                            switch error {
                            case .missingIdentity: notice = "Araştırma için adını, bir kullanıcı adını veya profil ipucunu ekle."
                            case .invalidName, .invalidURL: notice = "Profil metnini kısalt veya bağlantı bilgilerini kontrol et."
                            }
                        } catch {
                            busy = false
                            notice = "Profilin kaydedilemedi. İnternet ve Firebase bağlantını kontrol edip yeniden dene. Başka bir cihazda değiştirdiysen bu ekranı yeniden aç."
                        }
                    }
                } label: {
                    if busy { ProgressView().tint(.white).accessibilityLabel("Kaydediliyor…") }
                    else { Text(LocalizedStringKey(profile.researchAllowed ? "Kaydet ve araştırmayı başlat" : "Bağlantılarımı kaydet")) }
                }.buttonStyle(DailySocialActionStyle()).disabled(busy || !model.canEdit || model.phoneAnalysisBusy || model.phoneMemoryBusy || model.mapLinkBusy || loadedScope != model.companionScope)
                    .accessibilityIdentifier("social-profile-save")
                if let status = model.profileResearchStatus, !model.profileResearchRunning { researchStatus(status) }
            }.padding(20)
        }.scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.profileResearchRunning, let status = model.profileResearchStatus {
                    researchStatus(status).padding(.horizontal, 20).padding(.vertical, 6)
                        .background(DailyTheme.canvas)
                }
            }
            .background { DailyCanvas { Color.clear } }
            .navigationTitle("Sosyal profillerin").navigationBarTitleDisplayMode(.inline)
            .onChange(of: model.analysisMapTour?.id) { _, id in if id != nil { dismiss() } }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { dismiss() }.disabled(busy) } }
            .popover(item: $report) { item in
                AnalysisReplyPopover(reply: item.reply) { report = nil }
                    .presentationCompactAdaptation(.popover)
            }
            .task(id: model.companionScope) {
                loadedScope = model.companionScope
                profile = model.savedSocialProfile
                introduction = profile.introductionText
                notice = ""
            }
    }

    private func researchStatus(_ status: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.profileResearchRunning {
                HStack(spacing: 10) {
                    ProgressView().tint(DailySettingsKind.social.color)
                    Text("dAIly seni tanıyor…").font(.headline)
                }
            }
            Text(LocalizedStringKey(status)).font(.subheadline)
                .accessibilityIdentifier("profile-research-progress")
            if model.profileResearchRunning {
                Button("Araştırmayı durdur", role: .cancel) { model.cancelPhoneAnalysis() }.font(.footnote)
            } else if let result = model.profileResearchReport {
                Button("Araştırma sonucunu oku", systemImage: "doc.text") {
                    report = AnalysisReplyPresentation(reply: result)
                }.font(.subheadline.weight(.semibold))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(DailySettingsKind.social.surface, in: RoundedRectangle(cornerRadius: 16))
    }

}

private struct DailySocialActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54).padding(.horizontal, 16)
            .background(DailySettingsKind.social.color, in: RoundedRectangle(cornerRadius: 17))
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
    }
}
