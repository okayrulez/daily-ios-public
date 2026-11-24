import SwiftUI

/// Geometry updates redraw only the mask, not the tour state machine or simulated tabs.
@MainActor final class TourSpotlightRegistry: ObservableObject {
    private struct Entry { let owner: UUID; let frame: CGRect }
    @Published private var entries: [String: Entry] = [:]
    func frame(for id: String) -> CGRect? { entries[id]?.frame }
    func update(_ frame: CGRect, id: String, owner: UUID) {
        guard frame.width > 0, frame.height > 0,
              entries[id]?.owner != owner || entries[id]?.frame != frame else { return }
        entries[id] = Entry(owner: owner, frame: frame)
    }
    func remove(_ id: String, owner: UUID) {
        if entries[id]?.owner == owner { entries[id] = nil }
    }
    func reset() { entries = [:] }
}

private struct TourSpotlightKey: EnvironmentKey {
    static let defaultValue: TourSpotlightRegistry? = nil
}
extension EnvironmentValues {
    var tourSpotlight: TourSpotlightRegistry? {
        get { self[TourSpotlightKey.self] }
        set { self[TourSpotlightKey.self] = newValue }
    }
}
private struct TourTargetFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private struct TourHighlightTarget: ViewModifier {
    let id: String
    let enabled: Bool
    @Environment(\.tourSpotlight) private var registry
    @State private var owner = UUID()
    func body(content: Content) -> some View {
        content.background {
            if enabled, registry != nil {
                GeometryReader { proxy in
                    Color.clear.preference(key: TourTargetFrameKey.self, value: [id: proxy.frame(in: .global)])
                }
            }
        }
        .onPreferenceChange(TourTargetFrameKey.self) { values in
            if enabled, let frame = values[id] { registry?.update(frame, id: id, owner: owner) }
        }
        .onDisappear { registry?.remove(id, owner: owner) }
    }
}
extension View {
    @ViewBuilder func tourHighlight(_ id: String, enabled: Bool = true) -> some View {
        if enabled { modifier(TourHighlightTarget(id: id, enabled: true)) }
        else { self }
    }
}

struct TourSpotlightMask: View {
    @ObservedObject var registry: TourSpotlightRegistry
    let target: String
    var secondaryTarget: String? = nil
    var accent = DailyTheme.energy
    var permitsExploration = false
    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let frame = registry.frame(for: target).map {
                $0.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -7, dy: -7).intersection(bounds)
            }.flatMap { $0.isEmpty ? nil : $0 }
            let secondaryFrame = secondaryTarget.flatMap { registry.frame(for: $0) }.map {
                $0.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -4, dy: -4).intersection(bounds)
            }.flatMap { $0.isEmpty ? nil : $0 }
            let path = Path { path in
                path.addRect(bounds)
                if let frame { path.addRoundedRect(in: frame, cornerSize: CGSize(width: 22, height: 22)) }
                if let secondaryFrame { path.addRoundedRect(in: secondaryFrame, cornerSize: CGSize(width: 20, height: 20)) }
            }
            ZStack {
                path.fill(Color.black.opacity(permitsExploration ? 0.12 : 0.32), style: FillStyle(eoFill: true))
                if let frame, let coach = registry.frame(for: "coach") {
                    let top = coach.minY - origin.y
                    if frame.maxY + 12 < top {
                        Path { path in
                            let start = CGPoint(x: frame.midX, y: frame.maxY + 3)
                            let end = CGPoint(x: min(max(frame.midX, 36), proxy.size.width - 36), y: top - 5)
                            path.move(to: start)
                            path.addCurve(to: end, control1: CGPoint(x: start.x, y: (start.y + end.y) / 2),
                                          control2: CGPoint(x: end.x, y: (start.y + end.y) / 2))
                        }.stroke(accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [3, 5]))
                            .allowsHitTesting(false)
                    }
                }
                if let frame {
                    RoundedRectangle(cornerRadius: 22).strokeBorder(accent, lineWidth: 2)
                        .shadow(color: accent.opacity(0.5), radius: 7)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY).allowsHitTesting(false)
                }
                if let secondaryFrame {
                    TourTabRing(accent: accent)
                        .frame(width: secondaryFrame.width, height: secondaryFrame.height)
                        .position(x: secondaryFrame.midX, y: secondaryFrame.midY)
                        .id(secondaryTarget.map { $0 + target } ?? target)
                }
            }
        }
        .allowsHitTesting(false)

    }
}

/// One brief light settling on each destination, not a repeating tab animation.
private struct TourTabRing: View {
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false
    var body: some View {
        RoundedRectangle(cornerRadius: 20).strokeBorder(accent, lineWidth: 2)
            .shadow(color: accent.opacity(settled ? 0.18 : 0.65), radius: settled ? 3 : 9)
            .allowsHitTesting(false)
            .onAppear {
                if reduceMotion { settled = true }
                else { withAnimation(.easeOut(duration: 0.4)) { settled = true } }
            }
    }
}
