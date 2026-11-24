import SwiftUI
import DailyCore

private let atlasChangeRed = Color(red: 0.88, green: 0.13, blue: 0.22)
private let atlasCanvas = DailyTheme.canvas

/// The map owns the entire viewport; the only navigation is pan and pinch.
struct OrganicAtlas: View {
    let graph: MobileAtlas.Graph
    let selectedID: String
    let select: (String) -> Void
    var highlightedIDs: Set<String> = []
    var updatedIDs: Set<String> = []
    var changedEdgeIDs: Set<String> = []
    var removedIDs: Set<String> = []
    var removedEdgeIDs: Set<String> = []
    var playbackKey = ""
    var selectionMode = false
    var selectedNodeIDs: Set<String> = []
    var onAreaSelection: ([String]) -> Void = { _ in }
    var spotlightNodeID: String? = nil
    var usesMotionPreferences = true
    var minimumInitialZoom: CGFloat = 0.55
    var cameraTargetID: String? = nil
    var emotionNodeColors: [String: [Color]] = [:]
    @AppStorage("atlas-motion-running") private var motionRunning = true
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var zoom: CGFloat = 0.8
    @State private var hasFitted = false
    @GestureState private var magnification: CGFloat = 1
    private var displayedZoom: CGFloat { boundedZoom(zoom * magnification) }
    private var canvasSize: CGSize {
        let expansion = max(1, sqrt(CGFloat(graph.nodes.count) / 18))
        return CGSize(width: 820 * expansion, height: 620 * expansion)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView([.horizontal, .vertical]) {
                    OrganicAtlasDrawing(nodes: graph.nodes, edges: graph.edges, selectedID: selectedID,
                                        select: select, highlightedIDs: highlightedIDs, updatedIDs: updatedIDs, changedEdgeIDs: changedEdgeIDs, removedIDs: removedIDs, removedEdgeIDs: removedEdgeIDs, playbackKey: playbackKey, canvasSize: canvasSize,
                                        selectionMode: selectionMode, selectedNodeIDs: selectedNodeIDs, onAreaSelection: onAreaSelection,
                                        lightMotion: usesMotionPreferences && motionRunning && !reducedMotion && scenePhase == .active && !selectionMode,
                                        zoomLevel: displayedZoom, spotlightNodeID: spotlightNodeID, emotionNodeColors: emotionNodeColors)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .scaleEffect(displayedZoom, anchor: .topLeading)
                        .frame(width: canvasSize.width * displayedZoom, height: canvasSize.height * displayedZoom, alignment: .topLeading)
                        .padding(.horizontal, max(0, (proxy.size.width - canvasSize.width * displayedZoom) / 2))
                        .padding(.vertical, max(0, (proxy.size.height - canvasSize.height * displayedZoom) / 2))
                }
                .defaultScrollAnchor(.center)
                .scrollIndicators(.hidden)
                .scrollDisabled(selectionMode)
                .background(atlasCanvas)
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($magnification) { value, state, _ in state = value.magnification }
                        .onEnded { value in zoom = boundedZoom(zoom * value.magnification) }
                )
                .onChange(of: proxy.size, initial: true) { _, size in
                    guard !hasFitted, size.width > 0, size.height > 0 else { return }
                    zoom = boundedZoom(max(minimumInitialZoom, min(size.width / canvasSize.width, size.height / canvasSize.height)))
                    hasFitted = true
                }
                .task(id: cameraTargetID) {
                    guard let cameraTargetID else { return }
                    do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                    guard !Task.isCancelled else { return }
                    withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.6)) {
                        reader.scrollTo(cameraTargetID, anchor: .center)
                    }
                }
                .accessibilityAction(named: Text("Yakınlaştır")) { zoom = boundedZoom(zoom + 0.2) }
                .accessibilityAction(named: Text("Uzaklaştır")) { zoom = boundedZoom(zoom - 0.2) }
            }
        }
    }
    private func boundedZoom(_ value: CGFloat) -> CGFloat { min(3, max(0.1, value)) }
}

struct OrganicAtlasDrawing: View {
    let nodes: [MobileAtlas.Node]
    let edges: [MobileAtlas.Edge]
    let selectedID: String
    let select: (String) -> Void
    var highlightedIDs: Set<String> = []
    var updatedIDs: Set<String> = []
    var changedEdgeIDs: Set<String> = []
    var removedIDs: Set<String> = []
    var removedEdgeIDs: Set<String> = []
    var playbackKey = ""
    var canvasSize = CGSize(width: 820, height: 620)
    var selectionMode = false
    var selectedNodeIDs: Set<String> = []
    var onAreaSelection: ([String]) -> Void = { _ in }

    var lightMotion = false
    var zoomLevel: CGFloat = 1
    var spotlightNodeID: String? = nil
    var emotionNodeColors: [String: [Color]] = [:]
    var isPreview = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var linkProgress: CGFloat = 1
    @State private var selectionRect: CGRect?
    @State private var positions: [String: CGPoint] = [:]
    @State private var prominentNodeIDs: Set<String> = []
    // Compute layout only when topology changes, not on every pinch or note selection.
    private var layoutKey: [String] {
        nodes.map(\.id) + edges.flatMap { [$0.id, $0.source, $0.target] }
            + [String(Double(canvasSize.width)), String(Double(canvasSize.height))]
    }

    var body: some View {
        ZStack {
            atlasCanvas
            if !emotionNodeColors.isEmpty { emotionGlow }
            AtlasBranches(positions: positions, edges: edges, selectedID: selectedID, changedEdgeIDs: changedEdgeIDs, removedEdgeIDs: removedEdgeIDs, progress: linkProgress, running: lightMotion && !reduceMotion)
            ForEach(nodes) { node in
                if let point = positions[node.id] {
                    AtlasNodeButton(node: node, isSelected: selectedNodeIDs.contains(node.id) || node.id == selectedID,
                                    isNew: highlightedIDs.contains(node.id), isUpdated: updatedIDs.contains(node.id),
                                    showsLabel: zoomLevel >= 0.7 || selectionMode || prominentNodeIDs.contains(node.id) || node.id == selectedID || selectedNodeIDs.contains(node.id) || highlightedIDs.contains(node.id) || updatedIDs.contains(node.id),
                                    labelScale: min(1.45, max(1, 1 / max(0.45, zoomLevel)))) { select(node.id) }
                        .tourHighlight("map-node", enabled: node.id == spotlightNodeID)
                        .accessibilityIdentifier(isPreview ? "atlas-preview-node-" + node.id :
                            spotlightNodeID == nil ? "atlas-node-" + node.id : "tour-map-node-" + node.id)
                        .opacity(removedIDs.contains(node.id) ? 0.28 : 1)
                        .overlay { if removedIDs.contains(node.id) { Text("Kaldırıldı").font(.caption.bold()).foregroundStyle(atlasChangeRed) } }
                        .allowsHitTesting(!removedIDs.contains(node.id))
                        .id(node.id + ":" + playbackKey)
                        .position(x: point.x, y: point.y + 38.5).id(node.id)
                }
            }
            if let rect = selectionRect, selectionMode {
                RoundedRectangle(cornerRadius: 12)
                    .fill(DailyTheme.cobalt.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(DailyTheme.cobalt, style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .highPriorityGesture(areaGesture, including: selectionMode ? .all : .none)
        .onChange(of: selectionMode) { _, _ in selectionRect = nil }
        .task(id: playbackKey + changedEdgeIDs.sorted().joined(separator: "|")) {
            guard !changedEdgeIDs.isEmpty, !reduceMotion else { linkProgress = 1; return }
            linkProgress = 0
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            withAnimation(.easeInOut(duration: 2.4)) { linkProgress = 1 }
        }
        .onChange(of: layoutKey, initial: true) { _, _ in
            // Rank once per topology, never sort the graph during a pinch.
            var degree: [String: Int] = [:]
            for edge in edges { degree[edge.source, default: 0] += 1; degree[edge.target, default: 0] += 1 }
            prominentNodeIDs = Set(nodes.sorted {
                let left = degree[$0.id, default: 0], right = degree[$1.id, default: 0]
                return left == right ? $0.id < $1.id : left > right
            }.prefix(8).map(\.id))
            let next = AtlasOrganicLayout.positions(ids: nodes.map(\.id), edges: edges, canvasSize: canvasSize)
            if positions.isEmpty || reduceMotion { positions = next }
            else { withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) { positions = next } }
        }
    }
    private var emotionGlow: some View {
        Canvas { context, _ in
            let radius: CGFloat = 103
            for node in nodes where !removedIDs.contains(node.id) {
                guard let point = positions[node.id], let colors = emotionNodeColors[node.id] else { continue }
                let visible = Array(colors.prefix(4))
                for (index, color) in visible.enumerated() {
                    let offset = (CGFloat(index) - CGFloat(visible.count - 1) / 2) * 26
                    let center = CGPoint(x: point.x + offset, y: point.y + 24)
                    let bounds = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    let fade = Gradient(stops: [
                        .init(color: color.opacity(visible.count == 1 ? 0.34 : 0.22), location: 0),
                        .init(color: color.opacity(0.10), location: 0.55),
                        .init(color: color.opacity(0), location: 1),
                    ])
                    context.fill(Path(ellipseIn: bounds), with: .radialGradient(fade, center: center, startRadius: 0, endRadius: radius))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private var areaGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    selectionRect = CGRect(x: min(drag.startLocation.x, drag.location.x),
                        y: min(drag.startLocation.y, drag.location.y),
                        width: abs(drag.location.x - drag.startLocation.x), height: abs(drag.location.y - drag.startLocation.y))
                }
            }
            .onEnded { _ in
                guard let rect = selectionRect else { return }
                let ids = positions.compactMap { id, point in
                    rect.intersects(CGRect(x: point.x - 75, y: point.y, width: 150, height: 95)) ? id : nil
                }
                onAreaSelection(ids)
                selectionRect = nil
            }
    }

}

private struct AtlasNodeButton: View {
    let node: MobileAtlas.Node
    let isSelected: Bool
    let isNew: Bool
    var isUpdated = false
    var showsLabel = true
    var labelScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    private var changed: Bool { isNew || isUpdated }
    let select: () -> Void

    private var labelColor: Color { changed ? Color(red: 1, green: 0.95, blue: 0.96) : Color(uiColor: .systemBackground) }
    private var borderColor: Color { changed ? atlasChangeRed : isSelected ? DailyTheme.cobalt : DailyTheme.line }
    private var labelWeight: Font.Weight { isSelected ? .bold : .medium }

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                marker
                if showsLabel { label.scaleEffect(labelScale, anchor: .top) }
            }
            .frame(width: 150, height: 100, alignment: .top)
            .contentShape(Rectangle())
        }
        .opacity(changed && !reduceMotion && !revealed ? 0 : 1)
        .task(id: changed) {
            guard changed, !reduceMotion else { revealed = true; return }
            revealed = false
            withAnimation(.easeInOut(duration: 0.55)) { revealed = true }
        }
        .buttonStyle(.plain).foregroundStyle(DailyTheme.ink)
        .accessibilityLabel("\(node.label), \(node.statusLabel)\(isNew ? ", yeni not" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Bağlı notları okumak için aç")
    }

    private var marker: some View {
        Circle().fill(changed ? atlasChangeRed : node.status == "retracted" ? DailyTheme.orange : DailyTheme.cobalt)
            .frame(width: 9, height: 9).padding(7)
            .background((changed ? atlasChangeRed : DailyTheme.cobalt).opacity(isSelected || changed ? 0.18 : 0.06), in: Circle())
    }

    private var label: some View {
        Text(node.label).font(.system(size: 14, weight: labelWeight, design: .rounded))
            .lineLimit(2).truncationMode(.tail).multilineTextAlignment(.center)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(width: 150, height: 65)
            .background(labelColor, in: DailyPanelShape(cut: 12))
            .overlay(DailyPanelShape(cut: 12).stroke(changed ? atlasChangeRed : DailyTheme.energy, lineWidth: isSelected || changed ? 2 : 1))
            .shadow(color: changed ? atlasChangeRed.opacity(0.16) : DailyTheme.ink.opacity(isSelected ? 0.12 : 0.05), radius: 8, y: 4)
            .overlay(alignment: .topTrailing) {
                if changed {
                    Text(isNew ? "Yeni" : "Güncellendi").font(.caption2.bold()).foregroundStyle(DailyTheme.paper)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(atlasChangeRed, in: Capsule()).offset(y: -10)
                }
            }
    }
}

private struct AtlasBranches: View, @preconcurrency Animatable {
    let positions: [String: CGPoint]
    let edges: [MobileAtlas.Edge]
    let selectedID: String
    var changedEdgeIDs: Set<String> = []
    var removedEdgeIDs: Set<String> = []
    var progress: CGFloat = 1
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }


    var running = true
    @State private var started = Date()
    @State private var elapsed = 0.0
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/24, paused: !running)) { timeline in
            let time = elapsed + (running ? timeline.date.timeIntervalSince(started) : 0)
            Canvas { context, _ in
                for (index, edge) in edges.enumerated() {
                    guard let a = positions[edge.source], let b = positions[edge.target] else { continue }
                    let active = edge.source == selectedID || edge.target == selectedID
                    let changed = changedEdgeIDs.contains(edge.id), removed = removedEdgeIDs.contains(edge.id)
                    let color: Color = changed || removed ? atlasChangeRed : DailyTheme.energy
                    let middle = (a.x + b.x) / 2
                    let c1 = CGPoint(x: middle, y: a.y)
                    let c2 = CGPoint(x: middle, y: b.y)
                    var route = Path()
                    route.move(to: a)
                    route.addCurve(to: b, control1: c1, control2: c2)
                    let fraction = changed ? max(0, min(1, progress)) : 1
                    let visible = route.trimmedPath(from: 0, to: fraction)
                    context.stroke(visible, with: .color(color.opacity(removed ? 0.05 : 0.12)),
                                   style: StrokeStyle(lineWidth: active ? 12 : 8, lineCap: .round))
                    context.stroke(visible, with: .color(color.opacity(removed ? 0.4 : 0.85)),
                                   style: StrokeStyle(lineWidth: changed || active ? 2.5 : 1.6, lineCap: .round, dash: removed ? [7, 5] : []))
                    if running && !removed {
                        let t = CGFloat((time * 0.18 + Double(index) * 0.23).truncatingRemainder(dividingBy: 1))
                        if t <= fraction {
                            let u = 1 - t
                            let x = u*u*u*a.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*b.x
                            let y = u*u*u*a.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*b.y
                            context.fill(Path(ellipseIn: CGRect(x: x-5, y: y-5, width: 10, height: 10)), with: .color(color.opacity(0.16)))
                            context.fill(Path(ellipseIn: CGRect(x: x-2, y: y-2, width: 4, height: 4)), with: .color(color))
                        }
                    }
                }
            }
        }
        .onChange(of: running) { wasRunning, isRunning in
            if wasRunning { elapsed += Date().timeIntervalSince(started) }
            if isRunning { started = Date() }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Bounded, deterministic relaxation: only real edges attract nodes; labels repel.
private enum AtlasOrganicLayout {
    static func positions(ids: [String], edges: [MobileAtlas.Edge], canvasSize: CGSize) -> [String: CGPoint] {
        let ordered = ids.sorted()
        guard !ordered.isEmpty else { return [:] }
        var points = ordered.enumerated().map { index, _ in
            let angle = Double(index) * 2.3999632297
            let radius = ordered.count == 1 ? 0 : 110 + sqrt(Double(index)) * 85
            return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        let indices = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
        // Full-screen maps contain every node. Bound layout work as the graph grows.
        let iterations = max(1, min(180, 2_000_000 / max(1, ordered.count * ordered.count)))
        for _ in 0..<iterations {
            var forces = points.map { CGPoint(x: -$0.x * 0.001, y: -$0.y * 0.001) }
            for i in points.indices {
                for j in (i + 1)..<points.count {
                    let dx = points[i].x - points[j].x, dy = points[i].y - points[j].y
                    let distance = max(1, hypot(dx, dy)), repel = 12000 / (distance * distance)
                    let overlap: CGFloat = abs(dx) < 170 && abs(dy) < 110 ? (110 - abs(dy)) * 0.15 : 0
                    let fx = dx / distance * repel, fy = dy / distance * repel + (dy >= 0 ? overlap : -overlap)
                    forces[i].x += fx; forces[i].y += fy; forces[j].x -= fx; forces[j].y -= fy
                }
            }
            for edge in edges {
                guard let i = indices[edge.source], let j = indices[edge.target], i != j else { continue }
                let dx = points[j].x - points[i].x, dy = points[j].y - points[i].y
                let distance = max(1, hypot(dx, dy)), pull = (distance - 230) * 0.006
                forces[i].x += dx / distance * pull; forces[i].y += dy / distance * pull
                forces[j].x -= dx / distance * pull; forces[j].y -= dy / distance * pull
            }
            for i in points.indices {
                points[i].x += min(6, max(-6, forces[i].x)); points[i].y += min(6, max(-6, forces[i].y))
            }
        }
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let scale = min(1.4, min((canvasSize.width - 200) / max(1, maxX - minX), (canvasSize.height - 180) / max(1, maxY - minY)))
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { i, id in
            (id, CGPoint(x: canvasSize.width / 2 + (points[i].x - (minX + maxX) / 2) * scale,
                         y: canvasSize.height / 2 - 30 + (points[i].y - (minY + maxY) / 2) * scale))
        })
    }
}
