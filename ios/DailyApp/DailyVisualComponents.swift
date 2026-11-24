import SwiftUI

/// An opaque, inexpensive glass-like surface. No backdrop blur or perpetual animation.
private struct DailyGlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var accent: Color

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LinearGradient(colors: [.white, DailyTheme.paleBlue.opacity(0.65)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white, accent.opacity(0.3), DailyTheme.line.opacity(0.5)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: DailyTheme.navy.opacity(0.045), radius: 16, y: 7)
    }
}

extension View {
    func dailyGlass(cornerRadius: CGFloat = 24, accent: Color = DailyTheme.line) -> some View {
        modifier(DailyGlassSurface(cornerRadius: cornerRadius, accent: accent))
    }
}

/// Decorative connection motif, not a miniature of the user's graph.
/// A single Canvas replaces dozens of tiny node views and does no record decoding.
struct DailyConnectionIllustration: View {
    var seed = "daily"
    var emphasizesChange = false

    var body: some View {
        Canvas { context, size in
            let variant = seed.utf8.reduce(0) { ($0 + Int($1)) % 11 }
            let shift = CGFloat(variant - 5) * 0.008
            let normalized: [CGPoint] = [
                .init(x: 0.12, y: 0.55 + shift), .init(x: 0.35, y: 0.22),
                .init(x: 0.48, y: 0.61), .init(x: 0.73, y: 0.25 - shift),
                .init(x: 0.86, y: 0.67), .init(x: 0.32, y: 0.85),
            ]
            let points = normalized.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            let links = [(0, 1), (0, 2), (1, 2), (2, 3), (3, 4), (2, 5)]
            for (index, link) in links.enumerated() {
                let start = points[link.0], end = points[link.1]
                var path = Path()
                path.move(to: start)
                let bend = (end.x - start.x) * 0.45
                path.addCurve(to: end, control1: .init(x: start.x + bend, y: start.y),
                              control2: .init(x: end.x - bend, y: end.y))
                let color = emphasizesChange && index == 3 ? DailyTheme.coral : DailyTheme.energy
                context.stroke(path, with: .color(color.opacity(0.1)), style: .init(lineWidth: 10, lineCap: .round))
                context.stroke(path, with: .color(color.opacity(0.75)), style: .init(lineWidth: 1.6, lineCap: .round))
            }
            for (index, point) in points.enumerated() {
                let side: CGFloat = index == 2 ? 30 : 20
                let rect = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
                let color = emphasizesChange && index == 3 ? DailyTheme.coral : DailyTheme.mint
                let shape = Path(roundedRect: rect, cornerRadius: side * 0.3)
                context.fill(shape, with: .linearGradient(.init(colors: [.white, DailyTheme.paleBlue]),
                    startPoint: rect.origin, endPoint: .init(x: rect.maxX, y: rect.maxY)))
                context.stroke(shape, with: .color(color.opacity(0.6)), lineWidth: 1)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(color))
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}


struct DailyMemoryExportCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hafızanı yanında taşı.")
                        .font(.system(size: 21, weight: .semibold)).foregroundStyle(DailyTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Seni tanıyan bağlamı yeni AI işlerine ekle.")
                        .font(.caption).foregroundStyle(DailyTheme.muted)
                }
                DailyConnectionIllustration(seed: "export", emphasizesChange: true).frame(width: 64, height: 70)
            }
            HStack {
                Label("Zihin haritalarını paylaş", systemImage: "square.and.arrow.up")
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
            }.font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(12).background(DailyTheme.navy, in: RoundedRectangle(cornerRadius: 15))
        }
        .padding(17).frame(maxWidth: .infinity, alignment: .leading)
        .dailyGlass(cornerRadius: 24, accent: DailyTheme.energy)
    }
}



enum DailyWritingProgress {
    static func characterCount(in text: String, upTo limit: Int) -> Int {
        text.lazy.filter { !$0.isWhitespace }.prefix(limit).count
    }
}

/// Shared by the live writer and the rehearsal so the field keeps its real placement.
struct DailyJournalWritingCard<Editor: View>: View {
    @AppStorage("daily.writing.appearance") private var appearance = WritingAppearance.neon.rawValue
    @AppStorage("daily.writing.serif") private var serif = false
    @AppStorage("daily.writing.size") private var writingSize = 21.0
    @AppStorage("daily.writing.spacing") private var writingSpacing = 7.0
    private var theme: WritingAppearance { WritingAppearance(rawValue: appearance) ?? .neon }

    let focused: Bool
    let progress: Double
    let editor: Editor
    init(focused: Bool = false, progress: Double = 0, @ViewBuilder editor: () -> Editor) {
        self.focused = focused
        self.progress = min(1, max(0, progress))
        self.editor = editor()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(DailyTheme.cobalt).padding(8)
                    .background(DailyTheme.paleBlue, in: RoundedRectangle(cornerRadius: 10))
                Text("Aklındaki ne?").foregroundStyle(DailyTheme.cobalt)
                Spacer()
            }.font(.caption.weight(.medium))
            editor.font(.system(size: writingSize, design: serif ? .serif : .default))
                .foregroundStyle(theme.ink).tint(theme == .night ? .cyan : DailyTheme.cobalt)
                .lineSpacing(writingSpacing).lineLimit(4...)
                .frame(minHeight: 160, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            GeometryReader { proxy in
                Capsule().fill(DailyTheme.line.opacity(0.3))
                Capsule().fill(LinearGradient(colors: [DailyTheme.energy, DailyTheme.cobalt, DailyTheme.coral],
                    startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * CGFloat(0.08 + progress * 0.92))
            }.frame(height: 2).accessibilityHidden(true).allowsHitTesting(false)
        }.padding(22).modifier(WritingSurface(theme: theme, focused: focused))
    }
}
