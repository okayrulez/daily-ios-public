import SwiftUI
import DailyCore

struct AnalysisMapTourScreen: View {
    let tour: AnalysisMapTour
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var index = 0
    @State private var inspected: MobileAtlas.Node?
    @State private var connectionHint: AnalysisMapTour.ConnectionHint?
    private var stop: AnalysisMapTour.Stop { tour.stops[index] }
    private var graph: MobileAtlas.Graph? { tour.graphs[stop.id] }
    private var isLastStop: Bool { index == tour.stops.count - 1 }
    private var opensQuestions: Bool { isLastStop && !model.hasPendingMapTours }
    private var nextLabel: LocalizedStringKey {
        if opensQuestions { return "Sorulara geç" }
        return isLastStop ? "Sonraki analiz değişiklikleri" : "Sonraki değişiklik"
    }

    var body: some View {
        ZStack {
            OrganicAtlas(graph: stop.graph, selectedID: "",
                select: { id in inspected = stop.graph.nodes.first { $0.id == id } },
                highlightedIDs: stop.addedNodeIDs,
                updatedIDs: stop.updatedNodeIDs,
                changedEdgeIDs: Set(stop.graph.edges.map(\.id)),
                playbackKey: tour.id + stop.id, usesMotionPreferences: false,
                minimumInitialZoom: 0.45)
                .id(stop.id).transition(.opacity).ignoresSafeArea()
                .accessibilityIdentifier("analysis-map-tour-canvas")
            VStack {
                HStack {
                    Spacer()
                    Button { model.closeAnalysisMapTours() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                    }.accessibilityLabel("Harita gezisini kapat")
                }
                Spacer(minLength: 16)
                VStack(spacing: 12) {
                    Text("Harita \(index + 1) / \(tour.stops.count)").font(.caption.monospacedDigit())
                        .accessibilityIdentifier("analysis-map-tour-position")
                    Text(stop.mapTitle).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                    ViewThatFits {
                        HStack(spacing: 12) { changeCounts }
                        VStack(spacing: 6) { changeCounts }
                    }.font(.caption.weight(.semibold))
                        .accessibilityIdentifier("analysis-map-tour-counts")
                    if let connectionHint {
                        Button {
                            inspected = connectionHint.to
                            self.connectionHint = nil
                        } label: {
                            VStack(spacing: 4) {
                                Text("Bu günlükte “\(connectionHint.from.label)” ile “\(connectionHint.to.label)” arasında bir bağ oluştu.")
                                    .foregroundStyle(.primary).lineLimit(3)
                                Label("Bağlı notu aç", systemImage: "arrow.up.right").fontWeight(.semibold)
                            }.font(.subheadline).multilineTextAlignment(.center).frame(minHeight: 44)
                        }.accessibilityIdentifier("analysis-map-tour-first-connection")
                    } else {
                        Text("Notları açmak için üzerlerine dokun.")
                            .font(.subheadline).multilineTextAlignment(.center)
                            .accessibilityIdentifier("analysis-map-tour-instruction")
                    }
                    if tour.stops.count > 1 {
                        HStack {
                            Button { move(to: index - 1) } label: {
                                Image(systemName: "chevron.left").frame(width: 48, height: 44)
                            }.disabled(index == 0).accessibilityLabel("Önceki değişiklik")
                            Spacer()
                            nextButton
                        }
                    } else {
                        nextButton
                    }
                }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            }.padding(18)
        }
        .background(DailyTheme.canvas).accessibilityAddTraits(.isModal)
        .onChange(of: scenePhase, initial: true) { _, _ in showConnectionHintIfNeeded() }
        .onChange(of: index) { _, _ in
            connectionHint = nil
            showConnectionHintIfNeeded()
        }
        .sheet(item: $inspected) { node in
            NavigationStack {
                AtlasNoteReader(node: node, map: stop.map, notes: tour.notes[stop.id], graph: graph,
                    onSelect: { inspected = $0 })
                    .navigationTitle("Not").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Kapat") { inspected = nil } } }
            }.presentationDetents([.medium, .large])
        }
    }
    private func showConnectionHintIfNeeded() {
        guard scenePhase == .active, connectionHint == nil else { return }
        connectionHint = tour.claimConnectionHint(at: stop)
    }
    private var nextButton: some View {
        Button {
            if isLastStop { model.finishAnalysisMapTour() }
            else { move(to: index + 1) }
        } label: {
            HStack(spacing: 6) {
                if opensQuestions || tour.stops.count == 1 {
                    Text(nextLabel).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                Image(systemName: "chevron.right")
            }.frame(minWidth: 48, minHeight: 44)
        }
        .accessibilityLabel(Text(nextLabel))
        .accessibilityIdentifier(opensQuestions ? "analysis-map-tour-questions" : "analysis-map-tour-next")
    }
    @ViewBuilder private var changeCounts: some View {
        Label("\(stop.addedNodeIDs.count) yeni not", systemImage: "note.text.badge.plus")
        Label("\(stop.addedEdgeIDs.count) yeni bağlantı", systemImage: "link")
        if !stop.updatedNodeIDs.isEmpty {
            Label("\(stop.updatedNodeIDs.count) not güncellendi", systemImage: "pencil")
        }
        if !stop.updatedEdgeIDs.isEmpty {
            Label("\(stop.updatedEdgeIDs.count) bağlantı değişti", systemImage: "link")
        }
    }

    private func move(to next: Int) {
        guard tour.stops.indices.contains(next) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { index = next }
    }
}

/// One complete, current note; the source log is deliberately not repeated here.
struct AtlasNoteReader: View {
    let node: MobileAtlas.Node
    let map: MobileAtlas.Map
    let notes: [MobileAtlas.Note]?
    var graph: MobileAtlas.Graph?
    var onSelect: (MobileAtlas.Node) -> Void = { _ in }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AtlasNoteBody(node: node, map: map, notes: notes)
                if let graph {
                    let linkedIDs = Set(graph.edges.filter { $0.source == node.id || $0.target == node.id }
                        .map { $0.source == node.id ? $0.target : $0.source })
                    let linked = graph.nodes.filter { linkedIDs.contains($0.id) }
                    if !linked.isEmpty {
                        Text("Bağlı notlar").font(.headline)
                        ForEach(linked) { other in
                            Button { onSelect(other) } label: {
                                HStack { Text(other.label); Spacer(); Image(systemName: "arrow.up.right") }
                                    .frame(maxWidth: .infinity, minHeight: 44).multilineTextAlignment(.leading)
                            }.buttonStyle(.plain).foregroundStyle(DailyTheme.cobalt)
                        }
                    }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.id(node.id)
    }
}

/// Shared note rendering keeps source labels and the explicit recovery action consistent.
struct AtlasNoteBody: View {
    @EnvironmentObject private var model: WorkspaceModel
    let node: MobileAtlas.Node
    let map: MobileAtlas.Map
    let notes: [MobileAtlas.Note]?
    @State private var recovered: [MobileAtlas.Note]?
    @State private var attempt = 0
    @State private var retrying = false

    var body: some View {
        let available = notes ?? recovered
        let context = AtlasNoteContent.context(for: node, notes: available ?? [])
        let text = AtlasNoteContent.text(for: node, notes: available ?? [])
        Text(node.label).font(.title2.bold()).textSelection(.enabled)
        Group {
            if context.kind == "correction" {
                Label("Senin düzeltmen", systemImage: "pencil")
            } else if context.kind == "observation" {
                Label("AI gözlemi", systemImage: "sparkles")
            } else if context.kind == "inference" || node.status == "candidate" {
                Label("AI çıkarımı", systemImage: "sparkles")
            }
            if !context.dates.isEmpty {
                Label(context.dates.joined(separator: " · "), systemImage: "calendar")
            }
            if let title = context.sourceTitle, !title.isEmpty {
                Text("Kaynak: \(title)")
            }
        }.font(.caption).foregroundStyle(DailyTheme.muted)
        Text(text).lineSpacing(5).textSelection(.enabled).accessibilityIdentifier("atlas-note-result")
        ResearchSourceLinks(text: text)
        if let quote = context.journalQuote {
            VStack(alignment: .leading, spacing: 5) {
                Label("Günlüğünden alıntı", systemImage: "quote.opening").font(.caption.bold())
                if let date = context.quoteDate, WorkspaceIdentity.validDate(date) { Text(date).font(.caption) }
                Text(quote).font(.callout).textSelection(.enabled)
            }
        }
        if available == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notun tamamı yüklenemedi. Kayıtlı önizleme gösteriliyor.").font(.caption)
                Button("Notu yeniden yükle", systemImage: "arrow.clockwise") {
                    retrying = true
                    attempt += 1
                }.disabled(retrying)
                if retrying { ProgressView() }
            }
            .task(id: attempt) {
                guard attempt > 0 else { return }
                let reloaded = try? await model.retryAtlasNotes(for: map)
                guard !Task.isCancelled else { return }
                recovered = reloaded
                retrying = false
            }
        }
    }
}
