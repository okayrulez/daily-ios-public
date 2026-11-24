import SwiftUI
import DailyCore

private struct DailySettingsViewportKey: EnvironmentKey {
    static let defaultValue: CGRect = .zero
}
extension EnvironmentValues {
    var dailySettingsViewport: CGRect {
        get { self[DailySettingsViewportKey.self] }
        set { self[DailySettingsViewportKey.self] = newValue }
    }
}

/// Colour belongs to the destination; labels and status remain readable without it.
enum DailySettingsKind: Equatable {
    case general, chatGPT, firebase, notifications, lightFlow, social, memory, usage, language, tutorial

    var color: Color {
        switch self {
        case .general: DailyTheme.mint
        case .tutorial: Color(red: 0.23, green: 0.30, blue: 0.62)
        case .chatGPT: Color(red: 0.06, green: 0.40, blue: 0.34)
        case .firebase: Color(red: 0.65, green: 0.28, blue: 0.02)
        case .notifications: Color(red: 0.58, green: 0.34, blue: 0.015)
        case .lightFlow: DailyTheme.cobalt
        case .social: Color(red: 0.65, green: 0.16, blue: 0.20)
        case .memory: Color(red: 0.40, green: 0.28, blue: 0.64)
        case .usage: Color(red: 0.12, green: 0.32, blue: 0.64)
        case .language: Color(red: 0.00, green: 0.40, blue: 0.47)
        }
    }
    var surface: Color {
        switch self {
        case .chatGPT: Color(red: 0.88, green: 0.97, blue: 0.94)
        case .firebase: Color(red: 1, green: 0.95, blue: 0.83)
        case .notifications: Color(red: 1, green: 0.96, blue: 0.82)
        case .social: Color(red: 1, green: 0.91, blue: 0.90)
        case .memory: Color(red: 0.94, green: 0.91, blue: 0.99)
        case .usage: Color(red: 0.88, green: 0.94, blue: 1)
        case .language: Color(red: 0.86, green: 0.96, blue: 0.97)
        case .tutorial: Color(red: 0.91, green: 0.92, blue: 1)
        default: color.opacity(0.09)
        }
    }
}

struct DailyServiceIcon: View {
    let kind: DailySettingsKind
    let symbol: String
    var side: CGFloat = 42
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.31).fill(kind.surface)
            if kind == .chatGPT || kind == .firebase {
                Image(kind == .chatGPT ? "ChatGPTServiceMark" : "FirebaseServiceMark")
                    .resizable().scaledToFit().frame(width: side * 0.64, height: side * 0.64)
            } else if kind == .tutorial {
                DailyFlowMark(showsControl: true).frame(width: side * 0.75, height: side * 0.38)
            } else {
                Image(systemName: symbol).font(.system(size: side * 0.43, weight: .medium)).foregroundStyle(kind.color)
            }
        }.frame(width: side, height: side).accessibilityHidden(true)
    }
}

/// Paint just the title, keeping its glyphs and layout unchanged through the sweep.
struct DailySettingsLightTitle: View {
    let title: LocalizedStringKey
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dailySettingsViewport) private var viewport
    @State private var visible = false

    var body: some View {
        let visibleBounds = viewport
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !visible || scenePhase != .active || reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5)
            let progress = reduceMotion ? 0.54 : min(1, phase / 3.5)
            let front = CGFloat(progress * 1.32 - 0.16)
            let red = Color(red: 0.69, green: 0.13, blue: 0.23)
            let blue = Color(red: 0.10, green: 0.32, blue: 0.72)
            Text(title).foregroundStyle(LinearGradient(stops: [
                .init(color: red, location: min(1, max(0, front - 0.16))),
                .init(color: blue, location: max(0, min(1, front + 0.16)))
            ], startPoint: .leading, endPoint: .trailing))
            .overlay {
                if !reduceMotion && phase > 4.4 {
                    Text(title).foregroundStyle(blue).opacity((phase - 4.4) / 0.6)
                        .accessibilityHidden(true).allowsHitTesting(false)
                }
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            !visibleBounds.isEmpty && proxy.frame(in: .global).intersects(visibleBounds)
        } action: { visible = $0 }
    }
}

struct DailySettingsStatus {
    enum Tone {
        case success, attention, neutral
        var color: Color {
            switch self {
            case .success: Color(red: 0.07, green: 0.38, blue: 0.22)
            case .attention: Color(red: 0.56, green: 0.28, blue: 0.03)
            case .neutral: DailyTheme.muted
            }
        }
        var icon: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .attention: "exclamationmark.circle"
            case .neutral: "circle.dotted"
            }
        }
    }
    let title: LocalizedStringKey
    let tone: Tone

    var badge: some View {
        Label(title, systemImage: tone.icon)
            .font(.caption2.weight(.semibold)).foregroundStyle(tone.color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tone.color.opacity(0.095), in: Capsule())
    }
}

extension ChatGPTConnection {
    var settingsStatus: DailySettingsStatus {
        if busy { return .init(title: "Bağlantı kontrol ediliyor", tone: .neutral) }
        if requiresSignIn { return .init(title: "Yeniden giriş gerekli", tone: .attention) }
        if let failure = lastFailure, failure.isRateLimited, failure.retryAt.map({ $0 > Date() }) ?? true {
            return .init(title: "Kullanım sınırı", tone: .attention)
        }
        if lastFailure != nil { return .init(title: "Son istek tamamlanamadı", tone: .attention) }
        if ready { return .init(title: "ChatGPT bağlı", tone: .success) }
        if accountReadState == .unavailable { return .init(title: "Hesaplar okunamadı", tone: .attention) }
        if hasSelectedAccount { return .init(title: "Hesap kayıtlı", tone: .neutral) }
        switch accountReadState {
        case .unread: return .init(title: "Hesap kontrol ediliyor", tone: .neutral)
        case .loaded where !accounts.isEmpty: return .init(title: "Hesap seç", tone: .attention)
        default: return .init(title: "Hesap bağla", tone: .attention)
        }
    }
}

struct DailySettingsPressStyle: ButtonStyle {
    var color = DailyTheme.mint
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(color.opacity(configuration.isPressed ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 18))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// These final tour steps use the real connection state and setup destinations.
struct DailyTourAccountCard: View {
    let kind: DailySettingsKind
    let openSetup: () -> Void
    @EnvironmentObject private var model: WorkspaceModel
    @ObservedObject private var connection = ChatGPTConnection.shared
    private var isFirebase: Bool { kind == .firebase }
    private var firebaseReady: Bool { model.cloudVerified && model.serverReady && model.cloudSyncNotice.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                DailyServiceIcon(kind: kind, symbol: "", side: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text(isFirebase ? "Firebase" : "ChatGPT").font(.title2.weight(.semibold))
                    if isFirebase {
                        DailySettingsStatus(title: firebaseReady ? "Bağlantı doğrulandı" : model.isDeviceOnly ? "İsteğe bağlı" : "Eşitleme bekliyor",
                                            tone: firebaseReady ? .success : model.isDeviceOnly ? .neutral : .attention).badge
                    } else { connection.settingsStatus.badge }
                }
            }
            Text(LocalizedStringKey(isFirebase ? "Veritabanın senin." : "AI hesabın da senin."))
                .font(.system(size: 25, weight: .semibold))
            if isFirebase, model.cloudConnected {
                Text(model.firebaseProjectID).font(.caption.monospaced()).foregroundStyle(DailyTheme.muted)
            }
            Text(LocalizedStringKey(isFirebase
                ? "Google hesabınla Firebase projenin bağlantısını aç. Kayıtlarını yalnız cihazda saklamak istersen doğrudan devam et."
                : "Kendi ChatGPT hesabını bağla. Hesabının erişebildiği modeli ve düşünme seviyesini sen seç."))
                .font(.subheadline).foregroundStyle(DailyTheme.muted)
            Button(action: openSetup) {
                Label(LocalizedStringKey(isFirebase ? "Firebase kurulumunu aç" : "ChatGPT girişini aç"), systemImage: "arrow.up.right")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(kind.color, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).accessibilityIdentifier(isFirebase ? "tour-connect-firebase" : "tour-connect-chatgpt")
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.white, kind.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 26))
            .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(kind.color.opacity(0.25), lineWidth: 1).allowsHitTesting(false) }
    }
}
