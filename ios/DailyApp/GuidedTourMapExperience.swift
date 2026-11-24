import SwiftUI
import DailyCore

struct GuidedTourMapExperience: View {
    @EnvironmentObject private var tour: GuidedTourController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var changesVisible = true
    private var graph: MobileAtlas.Graph { tour.exampleGraph }
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                OrganicAtlas(graph: graph, selectedID: tour.stage == .note ? tour.simulation.selectedNodeID : "",
                    select: { tour.openNote($0) },
                    highlightedIDs: changesVisible ? Set(graph.nodes.map(\.id)) : [],
                    changedEdgeIDs: changesVisible ? Set(graph.edges.map(\.id)) : [],
                    playbackKey: tour.runID.uuidString, spotlightNodeID: GuidedTourExample.focusNodeID,
                    usesMotionPreferences: false, minimumInitialZoom: 0.45,
                    cameraTargetID: GuidedTourExample.focusNodeID,
                    emotionNodeColors: [GuidedTourExample.focusNodeID: [EmotionStyle.color("relief")]])
                    .frame(height: max(150, proxy.size.height - 320)).padding(.top, 68)
                    .accessibilityHidden(tour.stage == .note)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Haritalar · Hareket").font(.headline)
                        Text("\(graph.nodes.count) yeni not · \(graph.edges.count) yeni bağlantı").font(.caption).foregroundStyle(DailyTheme.muted)
                    }
                    Spacer()
                    if tour.stage == .note {
                        Button { tour.closeNote() } label: {
                            Image(systemName: "xmark").frame(width: 44, height: 44)
                                .background(.white, in: Circle())
                        }.accessibilityLabel("Örnek notu kapat")
                    }
                }.padding(16).background(DailyTheme.canvas.opacity(0.94))
                if tour.stage == .note { noteWindow(size: proxy.size) }
            }
        }
        .background(DailyTheme.canvas)
        .task(id: tour.runID) {
            changesVisible = true
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { changesVisible = false }
        }
    }

    private func noteWindow(size: CGSize) -> some View {
        let node = graph.nodes.first { $0.id == tour.simulation.selectedNodeID }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(node?.label ?? "Örnek not").font(.headline)
                Spacer()
                Button { tour.closeNote() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Notu kapat")
            }.padding(.leading, 20).padding(.trailing, 8)
            Divider().padding(.horizontal, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(node?.summary ?? "").font(.body).lineSpacing(5).textSelection(.enabled)
                    Label("Kaynak: Örnek günlük", systemImage: "doc.text").font(.caption).foregroundStyle(DailyTheme.muted)
                    Text("Bağlı düşünceler").font(.subheadline.bold())
                    ForEach(graph.edges.filter { $0.source == node?.id || $0.target == node?.id }) { edge in
                        let id = edge.source == node?.id ? edge.target : edge.source
                        if let related = graph.nodes.first(where: { $0.id == id }) {
                            Button { tour.openNote(id) } label: {
                                Label(related.label, systemImage: "link").font(.subheadline)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(20)
            }
        }
        .frame(width: min(440, max(0, size.width - 40)), height: min(350, size.height * 0.46))
        .dailyGlass(cornerRadius: 28).clipShape(RoundedRectangle(cornerRadius: 28))
        .tourHighlight("note").accessibilityIdentifier("tour-note-window")
        .position(x: size.width / 2, y: size.height * 0.34)
    }
}
