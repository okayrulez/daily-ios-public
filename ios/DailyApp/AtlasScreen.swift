import SwiftUI
import DailyCore

private struct AtlasMapSelection: Identifiable {
    let id: String
    var nodeID: String? = nil
}

struct AtlasScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.locale) private var locale
    @State private var search = ""
    @State private var openedMap: AtlasMapSelection?
    @State private var searchIndex: (revision: [String], value: AtlasSearchIndex)?
    @State private var searchResults: (key: [String], matches: [AtlasSearchIndex.Match])?
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var indexRevision: [String] {
        let key = WorkspaceHash.sha256("note:companion/atlas/index.md")
        let references = (model.atlasIndex?.maps ?? []).flatMap { $0.pages + ($0.detailPages ?? []) }
        return [model.companionScope, model.records[key]?.hash ?? ""]
            + references.map { model.records[WorkspaceHash.sha256($0.key)]?.hash ?? "" }
    }
    private var currentIndex: AtlasSearchIndex? {
        searchIndex?.revision == indexRevision ? searchIndex?.value : nil
    }
    private var resultKey: [String] {
        [query, locale.identifier, currentIndex == nil ? "loading" : "ready"] + indexRevision
    }
    var body: some View {
        knowledgeMaps
            .onChange(of: model.analysisMapTour?.id) { _, id in
                if id != nil { openedMap = nil }
            }
            .onChange(of: model.companionScope) {
                openedMap = nil
                search = ""
                searchIndex = nil
                searchResults = nil
            }
    }
    private var knowledgeMaps: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                DailySectionHeading(eyebrow: "Biriken izlerin", title: "Zihin atlasın", detail: "Bir konuya gir, bağlantılarını keşfet.")

                if let atlas = model.atlasIndex {
                    if atlas.maps.isEmpty { emptyState }
                    else if !query.isEmpty { searchResultsList }
                    else {
                        ForEach(atlas.maps) { map in
                            AtlasMapCard(map:map,records:map.pages.compactMap { model.records[WorkspaceHash.sha256($0.key)] }, receipts: model.changeReceipts) {
                                openedMap = AtlasMapSelection(id: map.id)
                            }
                        }
                    }
                } else if model.records[WorkspaceHash.sha256("note:companion/atlas/index.md")] != nil {
                    Label("Bu harita sürümü okunamadı. Eşitlemeyi ve uygulama güncellemesini kontrol et.", systemImage: "exclamationmark.arrow.triangle.2.circlepath").dailyCard()
                } else { emptyState }
                if query.isEmpty {
                    Text(model.atlasViewError ?? "Kaydedilmiş haritaların gösteriliyor. Yeni sürüm varsa değişimler haritayı açtığında oynatılır.")
                        .font(.footnote).foregroundStyle(DailyTheme.muted)
                }
            }.padding(20)
        }.navigationTitle("Haritalar").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Haritalarda ve notlarda ara")
            .task(id: query.isEmpty ? nil : indexRevision) { await prepareSearchIndex() }
            .task(id: resultKey) { await findMatches() }
            .fullScreenCover(item: $openedMap) { selection in
                NavigationStack { AtlasMapScreen(mapID: selection.id, initialNodeID: selection.nodeID) }
            }
    }

    @ViewBuilder private var searchResultsList: some View {
        if let result = searchResults, result.key == resultKey {
            if result.matches.isEmpty {
                Text("Eşleşen harita veya not bulunamadı.").foregroundStyle(DailyTheme.muted)
            }
            ForEach(result.matches) { match in
                Button {
                    openedMap = AtlasMapSelection(id: match.mapID, nodeID: match.nodeID)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: match.nodeID == nil ? "point.3.connected.trianglepath.dotted" : "note.text")
                            .foregroundStyle(DailyTheme.cobalt)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(match.title).font(.headline).foregroundStyle(DailyTheme.ink)
                            if match.nodeID != nil {
                                Text(detail(for: match)).font(.caption).foregroundStyle(DailyTheme.muted)
                            }
                            if let excerpt = match.excerpt {
                                Text(excerpt).font(.subheadline).foregroundStyle(DailyTheme.muted).lineLimit(3)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(DailyTheme.cobalt)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading).contentShape(Rectangle()).dailyCard()
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("atlas-search-result-" + match.id)
            }
            if currentIndex?.hasUnavailablePages == true {
                Text("Bazı harita sayfaları okunamadı. Arama cihazda açılabilen kayıtları gösteriyor.")
                    .font(.footnote).foregroundStyle(DailyTheme.muted)
            }
        } else {
            ProgressView("Haritalarda aranıyor…").tint(DailyTheme.mint)
        }
    }

    private func detail(for match: AtlasSearchIndex.Match) -> String {
        [match.mapTitle, match.date.map { String($0.prefix(10)) }, match.sourceTitle]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func prepareSearchIndex() async {
        let revision = indexRevision
        guard !query.isEmpty, searchIndex?.revision != revision, let atlas = model.atlasIndex else { return }
        let records = model.records
        let worker = Task.detached(priority: .utility) { try? AtlasSearchIndex(atlas: atlas, records: records) }
        let index = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, revision == indexRevision, let index else { return }
        searchIndex = (revision, index)
    }

    private func findMatches() async {
        let key = resultKey
        let query = query
        let locale = locale
        guard !query.isEmpty, let index = currentIndex else { return }
        do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
        let worker = Task.detached(priority: .userInitiated) { try? index.search(query, locale: locale) }
        let matches = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, key == resultKey, let matches else { return }
        searchResults = (key, matches)
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(DailyTheme.cobalt)
            Text("İlk bağlantı burada belirecek.").font(.title2.bold())
            Text("Bugün sekmesinde günlüğünü yazıp Daily butonuna dokun. Yazın kaydedilir; analizden doğan notların ve bağlantıların burada büyür.").foregroundStyle(DailyTheme.muted)
        }.dailyCard()
    }
}

struct AtlasMapScreen: View {
    @EnvironmentObject private var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let mapID: String
    var initialNodeID: String? = nil
    @State private var appliedInitialFocus = false
    @State private var selectedID = ""
    @State private var focusID = ""
    @State private var showingNotes = false
    @State private var showingQuality = false
    @State private var selectionMode = false
    @State private var selectedNodeIDs: Set<String> = []
    @State private var questionDay: QuestionDestination?
    @State private var highlightedIDs: Set<String> = []
    @State private var updatedIDs: Set<String> = []
    @State private var changedEdgeIDs: Set<String> = []
    @State private var replay = 0
    @State private var playback: AtlasPlayback?
    @State private var animating = false
    @State private var playbackWarning = ""
    @Environment(\.scenePhase) private var scenePhase
    private var playbackScope: String { model.firebaseProjectID + ":" + (model.uid ?? "") }
    private var playbackStore: AtlasPlaybackStore {
        AtlasPlaybackStore(root: URL.applicationSupportDirectory.appendingPathComponent("atlas-seen-v1"))
    }
    @State private var currentGraph: MobileAtlas.Graph?
    @State private var graphRevision = ""
    @State private var loadingGraph = true
    @State private var emotionKeys: [String: [String]] = [:]
    private var map: MobileAtlas.Map? { model.atlasIndex?.maps.first { $0.id == mapID } }
    private var graphRecords: [WorkspaceRecord] {
        (map?.pages ?? []).compactMap { model.records[WorkspaceHash.sha256($0.key)] }
    }
    private var loadIdentity: [String] {
        [playbackScope, mapID, String(map?.nodeCount ?? -1), String(map?.edgeCount ?? -1)]
            + (map?.pages.flatMap { [$0.key, $0.hash] } ?? [])
            + graphRecords.map(\.hash)
    }
    private var playbackIdentity: String { playbackScope + ":" + mapID + ":" + graphRevision }
    private var emotionIdentity: [String] {
        let pageHashes = (map?.detailPages ?? []).map {
            model.records[WorkspaceHash.sha256($0.key)]?.hash ?? $0.key
        }
        let journalHashes = model.records.values.filter { $0.kind == .journal }.sorted { $0.key < $1.key }.map(\.hash)
        return [playbackScope, mapID] + pageHashes + journalHashes
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                mapCanvas
                    .ignoresSafeArea()
                    .accessibilityHidden(showingNotes)
                VStack {
                    HStack {
                        Button {
                            selectionMode.toggle()
                            if !selectionMode { selectedNodeIDs = [] }
                        } label: {
                            Label(selectionMode ? "Seçimi bitir" : "Bağları geliştir", systemImage: "rectangle.dashed")
                                .font(.subheadline.bold()).padding(14)
                                .background(.regularMaterial, in: Capsule())
                        }.disabled(model.mapLinkBusy || model.phoneAnalysisBusy)
                        Spacer()
                        if map != nil {
                            Button { showingQuality = true } label: {
                                Image(systemName: "info.circle").frame(width: 44, height: 44)
                                    .background(.regularMaterial, in: Circle())
                            }.accessibilityLabel("Harita bütünlüğü")
                        }
                        if playback?.hasChanges == true {
                            Button { replay += 1 } label: {
                                Image(systemName: "arrow.clockwise").font(.headline)
                                    .frame(width: 48, height: 48).background(.regularMaterial, in: Circle())
                            }.accessibilityLabel("Son harita değişimini yeniden oynat")
                        }
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.headline)
                                .frame(width: 48, height: 48)
                                .background(.regularMaterial, in: Circle())
                        }.accessibilityLabel("Haritadan çık")
                    }
                    if !focusID.isEmpty {
                        Button("Tüm haritayı göster",systemImage:"arrow.up.left.and.arrow.down.right") { focusID="" }
                            .font(.subheadline).padding(10).background(.regularMaterial,in:Capsule())
                    }
                    Spacer()
                    if let change = playback, animating {
                        Text("+\(change.addedNodes.count) yeni · \(change.updatedNodes.count) güncellenen · −\(change.removedNodes.count) kaldırılan not\n\(change.changedEdges.count) yeni/değişen bağ · −\(change.removedEdges.count) kaldırılan bağ")
                            .font(.footnote.bold()).multilineTextAlignment(.center).padding(14)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    }
                    if !playbackWarning.isEmpty { Text(playbackWarning).font(.caption).padding(10).background(.regularMaterial, in: Capsule()) }
                    if selectionMode {
                        VStack(spacing: 10) {
                            Text("Basılı tutup sürükleyerek bir alan seç. Tek tek dokunarak da seçim yapabilirsin.")
                                .font(.footnote).multilineTextAlignment(.center)
                            Text("\(selectedNodeIDs.count) düşünce seçildi").font(.subheadline.bold())
                            if model.journal(date: JournalCalendar.key(Date()))?.payload.object?["map_link_session"]?.object?["phase"] == .string("answering") {
                                Button("Devam eden harita sorularını aç") {
                                    questionDay = QuestionDestination(date: JournalCalendar.key(Date()))
                                }.buttonStyle(DailySecondaryButtonStyle())
                            }
                            if !model.mapLinkNotice.isEmpty { Text(model.mapLinkNotice).font(.footnote).multilineTextAlignment(.center) }
                            if model.mapLinkBusy { ProgressView("Sorular hazırlanıyor…") }
                            Button("3 yazılı + 3 evet/hayır sorusu oluştur") {
                                Task {
                                    if let day = await model.beginMapLinkQuestions(nodes: selectedNodes) {
                                        questionDay = QuestionDestination(date: day)
                                    }
                                }
                            }.buttonStyle(DailyPrimaryButtonStyle())
                                .disabled(selectedNodeIDs.count < 2 || selectedNodeIDs.count > 30 || model.mapLinkBusy || model.phoneAnalysisBusy)
                        }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                    }
                }.padding(16).accessibilityHidden(showingNotes)
                if showingNotes {
                    Color.black.opacity(0.28).ignoresSafeArea()
                        .onTapGesture { showingNotes = false }
                        .accessibilityHidden(true)
                    VStack(spacing: 0) {
                        HStack {
                            Text("Not").font(.headline)
                            Spacer()
                            Button { showingNotes = false } label: {
                                Image(systemName: "xmark").font(.headline)
                                    .frame(width: 44, height: 44)
                            }.accessibilityLabel("Notu kapat")
                        }.padding(.leading, 20).padding(.trailing, 8).padding(.top, 8)
                        Divider().padding(.horizontal, 20)
                        AtlasNodeNotes(mapID: mapID, graph: currentGraph, selectedID: $selectedID, emotionKeys: emotionKeys) { id in focusID=id;showingNotes=false }
                    }
                    .frame(width: min(440, max(0, proxy.size.width - 40)),
                           height: min(540, proxy.size.height * 0.68))
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 28))
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                    .shadow(color: .black.opacity(0.18), radius: 28, y: 12)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { showingNotes = false }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingQuality) {
            if let map { NavigationStack { AtlasQualityDetail(map: map) }.presentationDetents([.medium, .large]) }
        }
        .sheet(item: $questionDay) { destination in
            NavigationStack { JournalQuestionsScreen(date: destination.date) }
                .presentationDetents([.large]).presentationCornerRadius(28)
        }
        .task(id: loadIdentity) {
            let identity = loadIdentity
            currentGraph = nil; graphRevision = ""; loadingGraph = true
            playback = nil; highlightedIDs = []; updatedIDs = []; changedEdgeIDs = []
            animating = false; playbackWarning = ""
            guard let map else { loadingGraph = false; return }
            let records = graphRecords
            let worker = Task.detached(priority: .userInitiated) { () -> (MobileAtlas.Graph, String)? in
                guard let graph = try? MobileAtlas.graph(for: map, records: records), !Task.isCancelled else { return nil }
                return (graph, graph.revision)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, loadIdentity == identity else { return }
            currentGraph = result?.0; graphRevision = result?.1 ?? ""; loadingGraph = false
            let ids = Set(currentGraph?.nodes.map(\.id) ?? [])
            selectedNodeIDs.formIntersection(ids)
            if !ids.contains(focusID) { focusID = "" }
            if !ids.contains(selectedID) { selectedID = ""; showingNotes = false }
            if !appliedInitialFocus, let initialNodeID, ids.contains(initialNodeID) {
                appliedInitialFocus = true
                focusID = initialNodeID
                selectedID = initialNodeID
            }
        }
        .task(id: playbackIdentity + ":" + String(replay) + ":" + String(scenePhase == .active)) {
            guard scenePhase == .active, model.uid != nil, let graph = currentGraph else { return }
            let scope = playbackScope
            let change: AtlasPlayback
            if replay > 0, let existing = playback, existing.current.revision == graph.revision {
                change = existing
            } else {
                change = AtlasPlayback(previous: playbackStore.read(scope: scope, mapID: mapID), current: graph)
            }
            playback = change
            highlightedIDs = change.addedNodes; updatedIDs = change.updatedNodes
            changedEdgeIDs = change.changedEdges
            animating = change.hasChanges
            do {
                if change.hasChanges { try await Task.sleep(for: .seconds(6)) }
                try Task.checkCancellation()
                guard scenePhase == .active, playbackScope == scope else { return }
                try playbackStore.acknowledge(graph, scope: scope, mapID: mapID)
                playbackWarning = ""
                withAnimation(.easeOut(duration: 0.8)) {
                    highlightedIDs = []; updatedIDs = []; changedEdgeIDs = []; animating = false
                }
            } catch is CancellationError { return }
            catch { playbackWarning = "Görüntüleme kaydı saklanamadı; sonraki açılışta animasyon yeniden oynayabilir." }
        }
        .task(id: emotionIdentity) {
            let identity = emotionIdentity
            emotionKeys = [:]
            guard let map else { return }
            let pages = (map.detailPages ?? []).compactMap { model.records[WorkspaceHash.sha256($0.key)] }
            guard !pages.isEmpty else { return }
            let records = model.records.values.filter { $0.kind == .journal }
            let worker = Task.detached(priority: .utility) {
                let notes = try MobileAtlas.notes(for: map, records: pages)
                return try EmotionMapLinks.matches(notes: notes, days: EmotionHistory.days(records: records)).emotions
            }
            let matches = try? await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, identity == emotionIdentity else { return }
            emotionKeys = matches ?? [:]
        }
    }

    @ViewBuilder private var mapCanvas: some View {
        if let graph = currentGraph {
            let whole = animating ? (playback?.drawing ?? graph) : graph
            let drawing = focusID.isEmpty ? whole : whole.focused(on:focusID)
            if drawing.nodes.isEmpty {
                emptyCanvas("Bu haritada henüz düşünce yok.")
            } else {
                OrganicAtlas(graph: drawing, selectedID: selectedID, select: { id in
                    if selectionMode {
                        if selectedNodeIDs.contains(id) { selectedNodeIDs.remove(id) }
                        else { selectedNodeIDs.insert(id) }
                    } else { selectedID = id; showingNotes = true }
                }, highlightedIDs: highlightedIDs, updatedIDs: updatedIDs, changedEdgeIDs: changedEdgeIDs,
                removedIDs: animating ? (playback?.removedNodes ?? []) : [],
                removedEdgeIDs: animating ? (playback?.removedEdges ?? []) : [],
                playbackKey: playbackIdentity + ":" + String(replay), selectionMode: selectionMode,
                selectedNodeIDs: selectedNodeIDs, onAreaSelection: { selectedNodeIDs.formUnion($0) },
                cameraTargetID: focusID.isEmpty ? nil : focusID,
                emotionNodeColors: emotionKeys.mapValues { $0.map(EmotionStyle.color) })
                    .id(focusID)
            }
        } else if loadingGraph {
            ProgressView("Harita hazırlanıyor…").tint(DailyTheme.mint)
        } else {
            emptyCanvas("Haritanın bu sürümü cihazda bulunmuyor. Sonraki eşitlemede güncellenecek.")
        }
    }

    private var selectedNodes: [MobileAtlas.Node] {
        currentGraph?.nodes.filter { selectedNodeIDs.contains($0.id) } ?? []
    }

    private func emptyCanvas(_ message: String) -> some View {
        ZStack {
            DailyTheme.canvas
            Text(message).multilineTextAlignment(.center).foregroundStyle(DailyTheme.muted).padding(40)
        }
    }
}

private struct AtlasNodeNotes: View {
    @EnvironmentObject private var model: WorkspaceModel
    let mapID: String
    let graph: MobileAtlas.Graph?
    @Binding var selectedID: String
    var emotionKeys: [String: [String]] = [:]
    var onFocus:(String)->Void = { _ in }
    @State private var correctionOpen=false
    @State private var notes: [MobileAtlas.Note]?
    @State private var loadingNotes = true
    private var map: MobileAtlas.Map? { model.atlasIndex?.maps.first { $0.id == mapID } }
    private var noteRecords: [WorkspaceRecord] {
        (map?.detailPages ?? []).compactMap { model.records[WorkspaceHash.sha256($0.key)] }
    }
    private var notesIdentity: [String] {
        [model.companionScope, mapID] + (map?.detailPages?.flatMap { [$0.key, $0.hash] } ?? [])
            + noteRecords.map(\.hash)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let graph, let node = graph.nodes.first(where: { $0.id == selectedID }) {
                    if loadingNotes {
                        ProgressView("Not açılıyor…").tint(DailyTheme.mint)
                    } else if let map {
                        AtlasNoteBody(node: node, map: map, notes: notes)
                            .id(notesIdentity)
                        if let keys = emotionKeys[node.id], !keys.isEmpty {
                            let labels = keys.map { DailyLanguage.saved.text(EmotionDefinition.find($0)?.title ?? $0) }
                            Label(labels.joined(separator: " · "), systemImage: "waveform")
                                .font(.caption).foregroundStyle(DailyTheme.cobalt)
                                .accessibilityIdentifier("atlas-note-emotions")
                        }
                    }
                    let linkedIDs = Set(graph.edges.filter { $0.source == node.id || $0.target == node.id }
                        .map { $0.source == node.id ? $0.target : $0.source })
                    let linked = graph.nodes.filter { linkedIDs.contains($0.id) }
                    if !linked.isEmpty {
                        Text("Bağlı notlar").font(.headline)
                        ForEach(linked) { other in
                            Button { selectedID = other.id } label: {
                                HStack { Text(other.label); Spacer(); Image(systemName: "arrow.up.right") }
                                    .frame(maxWidth: .infinity, minHeight: 44).multilineTextAlignment(.leading)
                            }.buttonStyle(.plain).foregroundStyle(DailyTheme.cobalt)
                        }
                    }
                    HStack {
                        Button("Haritada göster",systemImage:"scope") { onFocus(node.id) }
                        Spacer()
                        Button("Düzelt",systemImage:"pencil.line") { correctionOpen=true }
                    }.font(.subheadline)
                    if !model.experienceNotice.isEmpty { Text(model.experienceNotice).font(.footnote) }
                } else {
                    Text("Bu düşünce artık haritada bulunmuyor.").foregroundStyle(DailyTheme.muted)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(selectedID)
        .task(id: notesIdentity) {
            let identity = notesIdentity
            notes = nil; loadingNotes = true
            guard let map else { loadingNotes = false; return }
            let records = noteRecords
            let worker = Task.detached(priority: .utility) { try? MobileAtlas.notes(for: map, records: records) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            if !Task.isCancelled, notesIdentity == identity { notes = result; loadingNotes = false }
        }
        .sheet(isPresented:$correctionOpen) {
            NodeCorrectionSheet(nodeID:selectedID,label:currentLabel)
        }
    }
    private var currentLabel:String {
        graph?.nodes.first(where: { $0.id == selectedID })?.label ?? "Not"
    }

}
