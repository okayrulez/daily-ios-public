import SwiftUI

struct AtlasMotionControls: View {
    @AppStorage("atlas-motion-running") private var running = true
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        DailyCanvas {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Işık akışı").font(.largeTitle.bold()).foregroundStyle(DailyTheme.ink)
                    Text("Haritalarındaki bağlantılar boyunca hafif ışık hareketleri.")
                        .foregroundStyle(DailyTheme.muted)
                    FlowMotionPreview(running: running && !reduced && scenePhase == .active)
                        .frame(height: 220)
                        .dailyCard(accent: DailyTheme.energy)
                    Toggle("Bağlantıları hareketlendir", isOn: $running)
                        .tint(DailyTheme.mint)
                        .disabled(reduced)
                        .dailyCard()
                    Text(reduced
                         ? "iPhone’un Hareketi Azalt tercihi açık. Işık hareketleri durduruldu."
                         : "Bu tercih yalnızca görünümü değiştirir. Notların ve bağlantıların korunur.")
                        .font(.callout).foregroundStyle(DailyTheme.muted)
                }.padding(20)
            }
        }.navigationTitle("Işık akışı").navigationBarTitleDisplayMode(.inline)
    }
}

private struct FlowMotionPreview: View {
    let running: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !running)) { timeline in
            Canvas { context, size in
                let start = CGPoint(x: 25, y: size.height * 0.7)
                let end = CGPoint(x: size.width - 25, y: size.height * 0.3)
                let c1 = CGPoint(x: size.width * 0.5, y: start.y)
                let c2 = CGPoint(x: size.width * 0.5, y: end.y)
                var path = Path()
                path.move(to: start)
                path.addCurve(to: end, control1: c1, control2: c2)
                context.stroke(path, with: .color(DailyTheme.energy.opacity(0.12)),
                               style: StrokeStyle(lineWidth: 12, lineCap: .round))
                context.stroke(path, with: .color(DailyTheme.energy),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
                for point in [start, end] {
                    let rect = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
                    context.fill(Path(ellipseIn: rect), with: .color(DailyTheme.paper))
                    context.stroke(Path(ellipseIn: rect), with: .color(DailyTheme.energy), lineWidth: 2)
                }
                if running {
                    let t = CGFloat((timeline.date.timeIntervalSinceReferenceDate * 0.18).truncatingRemainder(dividingBy: 1))
                    let u = 1 - t
                    let x = u*u*u*start.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*end.x
                    let y = u*u*u*start.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*end.y
                    context.fill(Path(ellipseIn: CGRect(x: x-7, y: y-7, width: 14, height: 14)), with: .color(DailyTheme.energy.opacity(0.18)))
                    context.fill(Path(ellipseIn: CGRect(x: x-3, y: y-3, width: 6, height: 6)), with: .color(DailyTheme.energy))
                }
            }
        }.accessibilityHidden(true)
    }
}
