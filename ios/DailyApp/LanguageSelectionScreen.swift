import SwiftUI

enum DailyLanguage: String, CaseIterable, Identifiable {
    case turkish = "tr"
    case english = "en"

    static let preferenceKey = "daily-ui-language"
    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    var name: String { self == .turkish ? "Türkçe" : "English" }
    static var saved: DailyLanguage {
        DailyLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .turkish
    }

    func text(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

struct LanguageSelectionScreen: View {
    let onChoose: (DailyLanguage) -> Void
    @State private var selection = DailyLanguage.saved

    var body: some View {
        DailyCanvas {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    DailyFlowMark(showsControl: true).frame(width: 100, height: 46)
                        .padding(.bottom, 12).accessibilityHidden(true)
                    Text("Dilini seç / Choose your language")
                        .font(.system(size: 29, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Tanıtım ve uygulama dili. Daha sonra Ayarlar’dan değiştirebilirsin.\nChoose the language for the tour and interface. You can change it in Settings.")
                        .font(.subheadline).lineSpacing(4).foregroundStyle(DailyTheme.muted)
                    ForEach(DailyLanguage.allCases) { language in
                        Button { selection = language } label: {
                            HStack {
                                Text(language.name).font(.title3.weight(.semibold))
                                Spacer()
                                Image(systemName: selection == language ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(DailyTheme.mint)
                            }.padding(22).dailyGlass(accent: selection == language ? DailyTheme.energy : DailyTheme.line)
                        }.buttonStyle(.plain).accessibilityIdentifier("language-option-" + language.rawValue)
                            .accessibilityAddTraits(selection == language ? .isSelected : [])
                    }
                    Button { onChoose(selection) } label: {
                        Label(selection == .turkish ? "Devam et" : "Continue", systemImage: "arrow.right")
                    }.buttonStyle(DailyPrimaryButtonStyle()).accessibilityIdentifier("language-confirm")
                }.padding(24).frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
            }
        }.accessibilityIdentifier("language-selection-screen")
    }
}

struct LanguageSettingsScreen: View {
    @AppStorage(DailyLanguage.preferenceKey) private var language = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        LanguageSelectionScreen { selected in
            language = selected.rawValue
            dismiss()
        }.navigationTitle("Uygulama dili").navigationBarTitleDisplayMode(.inline)
    }
}
