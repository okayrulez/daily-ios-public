import SwiftUI

enum DailyTheme {
    static let canvas = Color(red: 0.975, green: 0.980, blue: 0.984)
    static let paper = Color.white
    static let ink = Color(red: 0.035, green: 0.12, blue: 0.25)
    static let muted = Color(red: 0.27, green: 0.38, blue: 0.51)
    static let line = Color(red: 0.71, green: 0.83, blue: 0.90)
    static let orange = Color(red: 0.65, green: 0.36, blue: 0.035)
    static let cobalt = Color(red: 0.045, green: 0.23, blue: 0.40)
    static let mint = Color(red: 0.0, green: 0.46, blue: 0.60)
    static let navy = Color(red: 0.025, green: 0.12, blue: 0.25)
    static let paleBlue = Color(red: 0.88, green: 0.96, blue: 0.99)
    static let coral = Color(red: 0.93, green: 0.32, blue: 0.30)
    static let energy = Color(red: 0.0, green: 0.79, blue: 0.94)
    static let surface = LinearGradient(colors: [.white, canvas.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct DailyPanelShape: Shape {
    var cut: CGFloat = 16
    func path(in r: CGRect) -> Path {
        RoundedRectangle(cornerRadius:min(cut,min(r.width,r.height)/3),style:.continuous).path(in:r)
    }
}

struct DailyPanelSeams: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 2, y: r.minY + 38))
        p.addLine(to: CGPoint(x: r.minX + 2, y: r.minY + 17))
        p.addLine(to: CGPoint(x: r.minX + 17, y: r.minY + 2))
        p.addLine(to: CGPoint(x: r.minX + 38, y: r.minY + 2))
        p.move(to: CGPoint(x: r.maxX - 38, y: r.maxY - 2))
        p.addLine(to: CGPoint(x: r.maxX - 17, y: r.maxY - 2))
        p.addLine(to: CGPoint(x: r.maxX - 2, y: r.maxY - 17))
        p.addLine(to: CGPoint(x: r.maxX - 2, y: r.maxY - 38))
        return p
    }
}

struct DailyCanvas<Content: View>: View {
    let content: Content
    let writingEnergy: Double

    init(writingEnergy: Double = 0, @ViewBuilder content: () -> Content) {
        self.writingEnergy = writingEnergy
        self.content = content()
    }

    var body: some View {
        ZStack {
            DailyTheme.canvas.ignoresSafeArea()
            DailyBackgroundDrawing()
            DailyWritingLight(progress: writingEnergy)
            content
        }
        .foregroundStyle(DailyTheme.ink)
    }
}

struct DailyEyebrow: View {
    let text: String
    var color: Color = DailyTheme.cobalt

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(1.6)
            .foregroundStyle(color)
    }
}

struct DailySectionHeading: View {
    let eyebrow: String
    let title: String
    var detail: String?
    var showsEyebrow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsEyebrow { DailyEyebrow(text:eyebrow) }
            Text(LocalizedStringKey(title))
                .font(.system(size: 27, weight: .semibold, design: .default))
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(LocalizedStringKey(detail)).font(.subheadline).foregroundStyle(DailyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DailyConnectionBar: View {
    let message: String
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(active ? DailyTheme.mint.opacity(0.13) : DailyTheme.orange.opacity(0.13)).frame(width: 28, height: 28)
                Image(systemName: active ? "checkmark" : "arrow.triangle.2.circlepath")
                    .font(.caption.bold()).foregroundStyle(active ? DailyTheme.mint : DailyTheme.orange)
            }
            Text(message).font(.caption).foregroundStyle(DailyTheme.muted).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(DailyTheme.paper.opacity(0.96))
        .overlay(alignment: .bottom) { Rectangle().fill(DailyTheme.line).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bağlantı durumu: \(message)")
    }
}

struct DailyPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .background(isEnabled ? (configuration.isPressed ? DailyTheme.cobalt.opacity(0.78) : DailyTheme.cobalt) : DailyTheme.line)
            .clipShape(RoundedRectangle(cornerRadius:16,style:.continuous))

            .shadow(color: isEnabled ? DailyTheme.cobalt.opacity(configuration.isPressed ? 0.08 : 0.14) : .clear, radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct DailySecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(isEnabled ? DailyTheme.ink : DailyTheme.muted.opacity(0.55))
            .background(configuration.isPressed ? DailyTheme.paleBlue : DailyTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius:14,style:.continuous))

    }
}

extension View {
    func dailyCard(accent: Color? = nil, padding: CGFloat = 18) -> some View {
        // Group with whitespace, not stacked beveled cards.
        self.padding(padding)
    }
}
