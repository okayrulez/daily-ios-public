import SwiftUI
import DailyCore

struct AtlasMapCard: View {
    let map: MobileAtlas.Map
    let records: [WorkspaceRecord]
    let receipts: [WorkspaceChangeReceipt]
    let open: () -> Void
    @State private var graph: MobileAtlas.Graph?
    @State private var failed = false
    @State private var recent: AtlasRecentChange?
    private var identity: [String] {
        [map.id] + map.pages.map(\.hash) + records.map(\.hash) + receipts.map { $0.id + ($0.undone == true ? "-undone" : "") + $0.resultHash }
    }

    var body: some View {
        VStack(spacing:0) {
            Button(action:open) {
                preview.frame(height:215)
                    .overlay(alignment:.topTrailing) {
                        Text("\(map.nodeCount) not").font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(DailyTheme.ink).padding(.horizontal,12).padding(.vertical,7)
                            .background(.regularMaterial,in:Capsule()).padding(12)
                    }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(map.title), \(map.nodeCount) not, haritayı aç")
                .accessibilityIdentifier("atlas-open-map-" + map.id)
            Button(action:open) {
                HStack {
                    VStack(alignment:.leading,spacing:5) {
                        Text(map.title).font(.system(size:21,weight:.semibold)).foregroundStyle(DailyTheme.ink)
                        if let recent {
                            switch recent.kind {
                            case .added: Text("Yeni not · \(recent.title)")
                            case .updated: Text("Güncellenen not · \(recent.title)")
                            case .newLink: Text("Yeni bağlantı · \(recent.title)")
                            case .updatedLink: Text("Güncellenen bağlantı · \(recent.title)")
                            case .datedNote: Text("Son güncellenen not · \(recent.title)")
                            }
                            if let date = recent.date { Text(date).font(.caption).foregroundStyle(DailyTheme.muted) }
                        } else {
                            Text("\(map.edgeCount) bağlantı").font(.caption).foregroundStyle(DailyTheme.muted)
                        }
                    }
                    Spacer()
                    Image(systemName:"arrow.up.left.and.arrow.down.right").foregroundStyle(DailyTheme.mint)
                }.padding(18).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.dailyGlass(cornerRadius:28,accent:DailyTheme.energy)
            .clipShape(RoundedRectangle(cornerRadius:28))
            .task(id:identity) {
                graph=nil;recent=nil;failed=false
                do {
                    let loaded=try await Task.detached(priority:.utility) { [map,records,receipts] in
                        let graph = try MobileAtlas.graph(for:map,records:records)
                        return (graph, AtlasRecentChange.latest(in: graph, receipts: receipts))
                    }.value
                    try Task.checkCancellation()
                    graph=loaded.0; recent=loaded.1
                } catch { if !Task.isCancelled { failed=true } }
            }
    }
    @ViewBuilder private var preview: some View {
        if let graph {
            GeometryReader { proxy in
                let expansion=max(CGFloat(1),sqrt(CGFloat(graph.nodes.count)/18))
                let canvas=CGSize(width:820*expansion,height:620*expansion)
                let scale=min(proxy.size.width/canvas.width,proxy.size.height/canvas.height)*0.94
                OrganicAtlasDrawing(nodes:graph.nodes,edges:graph.edges,selectedID:"",select:{ _ in },
                    canvasSize:canvas,lightMotion:false,zoomLevel:scale,isPreview:true)
                    .frame(width:canvas.width,height:canvas.height)
                    .scaleEffect(scale)
                    .frame(width:proxy.size.width,height:proxy.size.height)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }.clipped()
        } else {
            ZStack {
                DailyTheme.canvas
                if failed { Label("Önizleme okunamadı",systemImage:"exclamationmark.arrow.triangle.2.circlepath").font(.caption).foregroundStyle(DailyTheme.muted) }
                else { ProgressView().tint(DailyTheme.mint) }
            }
        }
    }
}

struct AtlasQualityDetail: View {
    let map: MobileAtlas.Map
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Text(map.title).font(.title2.bold())
                if let q=map.quality {
                    Text("%\(q.percent)").font(.system(size:46,weight:.bold,design:.rounded)).foregroundStyle(DailyTheme.mint)
                    Text(q.current ? "Kaydedilmiş harita değerlendirmesi" : "Bu değerlendirmeden sonra harita değişti. Yeni denetim bekleniyor.")
                        .font(.subheadline).foregroundStyle(DailyTheme.muted)
                    Text(q.rationale)
                    Text("İncelenen kapsam: \(q.reviewedNodes) / \(q.totalNodes) not")
                        .font(.caption).foregroundStyle(DailyTheme.muted)
                    dimension("Konu kapsamı",q.dimensions.coverage,"Tanımlanan konunun ne kadar açıklanabildiği · %30")
                    dimension("Kaynak desteği",q.dimensions.evidence,"Notların kaynakları ve belirsizliklerin korunması · %30")
                    dimension("İlişkilerin tutarlılığı",q.dimensions.coherence,"Bağların anlamı ve çelişkilerin ele alınması · %25")
                    dimension("Notların ayrışması",q.dimensions.distinctness,"Tekrarlar ve farklı düşüncelerin ayrılması · %15")
                    if !q.strengths.isEmpty { Text("Güçlü yanlar").font(.headline);ForEach(q.strengths,id:\.self) { Text($0) } }
                    if !q.gaps.isEmpty { Text("Geliştirilebilecekler").font(.headline);ForEach(q.gaps,id:\.self) { Text($0) } }
                    Text("Bu puan, verilen kaynak ve notlara dayalı bir AI değerlendirmesidir. Kişiliğinin veya bilgilerin kesin doğruluğunun yüzdesi değildir.")
                        .font(.footnote).foregroundStyle(DailyTheme.muted)
                } else {
                    Text("Bu haritanın bütünlük değerlendirmesi henüz oluşmadı.")
                    Text("Mevcut harita denetimi beş yeni günlükte bir çalışır. Bu ekran kaydedilmiş sonucu gösterir; ekranı açmak yeni AI sorgusu başlatmaz.")
                        .foregroundStyle(DailyTheme.muted)
                }
            }.padding(24)
        }.navigationTitle("Harita bütünlüğü").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Tamam") { dismiss() } } }
    }
    private func dimension(_ title:String,_ score:Int,_ detail:String)->some View {
        VStack(alignment:.leading,spacing:5) {
            HStack { Text(title).font(.subheadline.bold());Spacer();Text("%\(score)").monospacedDigit() }
            ProgressView(value:Double(score),total:100).tint(DailyTheme.mint)
            Text(detail).font(.caption).foregroundStyle(DailyTheme.muted)
        }
    }
}
