import SwiftUI

/// Glass connections resting on a pale surface. The central writing column stays quiet.
/// Static geometry avoids a continuously running animation behind the editor.
struct DailyBackgroundDrawing: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                relief(size: size)
                Canvas { context, canvas in
                    let points = [
                        CGPoint(x: canvas.width * 0.96, y: canvas.height * 0.20),
                        CGPoint(x: canvas.width * 0.62, y: canvas.height * 0.39),
                        CGPoint(x: canvas.width * 1.15, y: canvas.height * 0.45),
                        CGPoint(x: canvas.width * 0.94, y: canvas.height * 0.62),
                        CGPoint(x: canvas.width * 0.55, y: canvas.height * 0.77),
                        CGPoint(x: canvas.width * 1.10, y: canvas.height * 0.91)
                    ]
                    let edges = [(0, 1), (0, 2), (1, 2), (1, 3), (2, 3), (3, 4), (3, 5), (4, 5)]
                    for (a, b) in edges {
                        let start = points[a], end = points[b]
                        var line = Path()
                        line.move(to: start); line.addLine(to: end)
                        var shadow = context
                        shadow.addFilter(.shadow(color: DailyTheme.navy.opacity(0.16), radius: 7, x: -5, y: 10))
                        shadow.stroke(line, with: .color(DailyTheme.navy.opacity(0.08)),
                                      style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        context.stroke(line, with: .linearGradient(Gradient(colors: [
                            .white.opacity(0.65), DailyTheme.energy.opacity(0.20), .white.opacity(0.75)
                        ]), startPoint: start, endPoint: end), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        context.stroke(line, with: .color(DailyTheme.energy.opacity(0.18)),
                                       style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                    }
                    for (index, point) in points.enumerated() {
                        drawCube(at: point, radius: index == 3 ? 27 : 23, context: context)
                    }
                }
                // A light veil keeps the glass visible at the edges without crossing text.
                LinearGradient(stops: [
                    .init(color: DailyTheme.canvas.opacity(0.90), location: 0),
                    .init(color: DailyTheme.canvas.opacity(0.58), location: 0.48),
                    .init(color: DailyTheme.canvas.opacity(0.08), location: 1)
                ], startPoint: .leading, endPoint: .trailing)
            }
            .opacity(contrast == .increased ? 0.22 : 1)
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }

    private func relief(size: CGSize) -> some View {
        ZStack {
            Ellipse().fill(DailyTheme.navy.opacity(0.075))
                .frame(width: size.width * 1.02, height: size.width * 0.36)
                .blur(radius: 14).rotationEffect(.degrees(-22))
                .position(x: size.width * 0.56, y: -14)
            Ellipse().fill(DailyTheme.canvas)
                .frame(width: size.width * 1.05, height: size.width * 0.36)
                .rotationEffect(.degrees(-22))
                .position(x: size.width * 0.57, y: -25)
            Ellipse().fill(DailyTheme.navy.opacity(0.10))
                .frame(width: size.width * 0.90, height: size.width * 0.48)
                .blur(radius: 14).rotationEffect(.degrees(-24))
                .position(x: size.width * 1.07, y: size.height * 0.95)
            Ellipse().fill(DailyTheme.canvas)
                .frame(width: size.width * 0.94, height: size.width * 0.47)
                .rotationEffect(.degrees(-24))
                .position(x: size.width * 1.09, y: size.height * 0.94)
        }
    }

    private func drawCube(at center: CGPoint, radius r: CGFloat, context: GraphicsContext) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + x * r, y: center.y + y * r)
        }
        func face(_ coordinates: [(CGFloat, CGFloat)]) -> Path {
            var path = Path()
            for (index, coordinate) in coordinates.enumerated() {
                let p = point(coordinate.0, coordinate.1)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath(); return path
        }
        let top = face([(0, -1), (0.87, -0.5), (0, 0), (-0.87, -0.5)])
        let left = face([(-0.87, -0.5), (0, 0), (0, 1), (-0.87, 0.5)])
        let right = face([(0, 0), (0.87, -0.5), (0.87, 0.5), (0, 1)])
        let shadowRect = CGRect(x: center.x - r * 1.5, y: center.y + r * 0.65,
                                width: r * 2.6, height: r * 0.9)
        var shadow = context
        shadow.addFilter(.blur(radius: 9))
        shadow.fill(Path(ellipseIn: shadowRect), with: .color(DailyTheme.navy.opacity(0.18)))
        context.fill(top, with: .linearGradient(Gradient(colors: [.white.opacity(0.82), DailyTheme.line.opacity(0.34)]),
                     startPoint: point(-1, -1), endPoint: point(1, 0)))
        context.fill(left, with: .linearGradient(Gradient(colors: [.white.opacity(0.62), DailyTheme.cobalt.opacity(0.14)]),
                     startPoint: point(-1, -0.5), endPoint: point(0, 1)))
        context.fill(right, with: .linearGradient(Gradient(colors: [DailyTheme.line.opacity(0.38), DailyTheme.cobalt.opacity(0.22)]),
                     startPoint: point(1, -0.5), endPoint: point(0, 1)))
        for polygon in [top, left, right] {
            context.stroke(polygon, with: .color(DailyTheme.cobalt.opacity(0.18)), lineWidth: 0.8)
        }
        var refraction = Path()
        refraction.move(to: point(0, -1)); refraction.addLine(to: point(0, 1))
        refraction.move(to: point(-0.87, -0.5)); refraction.addLine(to: point(0.87, 0.5))
        refraction.move(to: point(0.87, -0.5)); refraction.addLine(to: point(-0.87, 0.5))
        context.stroke(refraction, with: .color(.white.opacity(0.75)), lineWidth: 0.8)
        context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y + r - 2, width: 4, height: 4)),
                     with: .color(DailyTheme.energy.opacity(0.5)))
    }
}

/// Writing adds a broad, calm light rather than a repeating flash or pulse.
struct DailyWritingLight: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private var strength: Double { pow(min(1, max(0, progress)), 1.5) }
    var body: some View {
        GeometryReader { geometry in
            Ellipse().fill(RadialGradient(colors: [DailyTheme.energy.opacity(0.22 * strength),
                                                  DailyTheme.paleBlue.opacity(0.13 * strength), .clear],
                                          center: .center, startRadius: 8, endRadius: 170))
                .frame(width: 350, height: 260)
                .position(x: geometry.size.width * 0.5, y: 16)
        }
        .opacity(contrast == .increased ? 0.25 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.65), value: progress)
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
