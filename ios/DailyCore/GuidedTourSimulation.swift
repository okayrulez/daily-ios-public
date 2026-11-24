import Foundation

/// A deterministic local rehearsal. It has no workspace, account or AI dependencies.
public struct GuidedTourSimulation: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case writing, daily, analysing, map, note, questions, agenda, emotionDay, emotionFlow, savedDay, export, exportPreview, firebase, account

        public var tab: WorkspaceTab {
            switch self {
            case .writing, .daily, .analysing, .savedDay: .today
            case .map, .note: .maps
            case .questions: .questions
            case .agenda, .emotionDay, .emotionFlow: .agenda
            case .export, .exportPreview, .firebase, .account: .settings
            }
        }
        public var progress: Int {
            switch self {
            case .writing: 1
            case .daily, .analysing: 2
            case .map, .note: 3
            case .questions: 4
            case .agenda: 5
            case .emotionDay: 6
            case .emotionFlow: 7
            case .savedDay: 8
            case .export, .exportPreview: 9
            case .firebase: 10
            case .account: 11
            }
        }
    }

    public private(set) var stage: Stage = .writing
    public private(set) var reminder: Bool?
    public private(set) var selectedNodeID = GuidedTourExample.focusNodeID
    private var skippedExample = false
    public let isIntroduction: Bool
    public init(isIntroduction: Bool = false) { self.isIntroduction = isIntroduction }

    public var progress: Int {
        if isIntroduction && stage == .savedDay { return 4 }
        if isIntroduction && stage == .account { return 5 }
        return stage.progress
    }
    public var totalSteps: Int { isIntroduction ? 5 : Stage.account.progress }

    /// Next cannot bypass the actions being taught.
    public mutating func advance(firebaseConnected: Bool = false, continueLocally: Bool = false) {
        switch stage {
        case .writing: stage = .daily
        case .note: stage = isIntroduction ? .savedDay : .questions
        case .questions where reminder != nil: stage = .agenda
        case .agenda: stage = .emotionDay
        case .emotionDay: stage = .emotionFlow
        case .emotionFlow: stage = .savedDay
        case .savedDay: stage = isIntroduction ? .account : .export
        case .exportPreview: stage = .firebase
        case .firebase where firebaseConnected || continueLocally: stage = .account
        default: break
        }
    }
    public mutating func startAnalysis() {
        guard stage == .daily else { return }
        stage = .analysing
    }
    public mutating func analysisFinished() {
        guard stage == .analysing else { return }
        stage = .map
    }
    public mutating func openNote(_ id: String) {
        guard stage == .map || stage == .note,
              GuidedTourExample.graph.nodes.contains(where: { $0.id == id }) else { return }
        selectedNodeID = id; stage = .note
    }
    public mutating func closeNote() { if stage == .note { stage = .map } }
    public mutating func skipExample() {
        guard isIntroduction else { return }
        skippedExample = true
        stage = .account
    }
    public mutating func answer(_ value: Bool) { if stage == .questions { reminder = value } }
    public mutating func openExport() { if stage == .export { stage = .exportPreview } }
    public mutating func back() {
        switch stage {
        case .writing, .analysing: break
        case .daily: stage = .writing
        case .map: stage = .daily
        case .note: stage = .map
        case .questions: stage = .map
        case .agenda: stage = .questions
        case .emotionDay: stage = .agenda
        case .emotionFlow: stage = .emotionDay
        case .savedDay: stage = isIntroduction ? .note : .emotionFlow
        case .export: stage = .savedDay
        case .exportPreview: stage = .export
        case .firebase: stage = .exportPreview
        case .account:
            if skippedExample { skippedExample = false; stage = .writing }
            else { stage = isIntroduction ? .savedDay : .firebase }
        }
    }
}

public enum GuidedTourExample {
    public static func graph(language: String) -> MobileAtlas.Graph {
        language == "en" ? englishGraph : graph
    }
    private static let englishGraph: MobileAtlas.Graph = {
        let labels = ["tour-self": "Time for myself", "tour-movement": "Regular movement",
                      focusNodeID: "Swimming", "tour-routine": "Weekly routine"]
        let summaries = [
            "tour-self": "You want to make time for yourself after work.",
            "tour-movement": "You wrote that regular movement makes you feel good.",
            focusNodeID: "You want to swim on Tuesdays and Thursdays at 6 pm. This plan connects regular movement with making time for yourself.",
            "tour-routine": "Your plan is two swimming sessions each week, on Tuesday and Thursday."
        ]
        let nodes = graph.nodes.map { node in
            MobileAtlas.Node(id: node.id, label: labels[node.id] ?? node.label, status: node.status,
                             summary: summaries[node.id] ?? node.summary, updatedAt: node.updatedAt,
                             topicPath: [labels[node.id] ?? node.label])
        }
        let relations = ["tour-edge-1": "supports", "tour-edge-2": "example", "tour-edge-3": "scheduled"]
        let edges = graph.edges.map { edge in
            MobileAtlas.Edge(id: edge.id, source: edge.source, target: edge.target,
                             relation: relations[edge.id] ?? edge.relation)
        }
        return MobileAtlas.Graph(nodes: nodes, edges: edges)
    }()
    /// Prepared demo data. Never derived from or written to the real workspace.
    public static func emotionDay(date: String, previousDate: String, language: String) -> EmotionDay {
        let english = language == "en"
        let keys = ["tension", "relief", "fatigue"]
        let labels = english ? ["Tension", "Relief", "Fatigue"] : ["Gerilim", "Rahatlama", "Yorgunluk"]
        let events = english ? ["Workload", "After swimming", "Evening"] : ["İş yükü", "Yüzme sonrası", "Akşam"]
        let quotes = english ? ["I felt tense at work today", "I felt relieved after swimming", "I was a little tired in the evening"] : ["Bugün işte gerildim", "yüzdükten sonra rahatladım", "Akşam biraz yorgundum"]
        let contexts = ["workload", "swimming", "evening"]
        let observations = keys.indices.map { index in
            var observation = EmotionObservation(id: "tour-" + date + "-" + keys[index], key: keys[index], label: labels[index],
                definition: EmotionDefinition.find(keys[index])?.meaning ?? "", intensity: [3, 4, 2][index],
                event: events[index], quote: quotes[index], sequence: index)
            observation.contextKey = contexts[index]
            observation.contextLabel = events[index]
            observation.orderGroup = "tour-example"
            return observation
        }
        return EmotionDay(date: date, sourceID: "tour-emotion-" + date,
            reflection: english ? "The tension at work turned into relief after swimming. Some tiredness remained in the evening." : "İşteki gerilim, yüzmeden sonra rahatlamaya dönüşmüş. Akşama biraz yorgunluk kalmış.",
            observations: observations,
            helpful: [english ? "You wrote that swimming helped." : "Yüzmenin iyi geldiğini yazmışsın."],
            connections: [EmotionConnection(date: previousDate, reason: english ? "The earlier sample day also moved from tension to relief." : "Önceki örnek günde de gerilimden rahatlamaya benzer bir geçiş vardı.")],
            userSelected: false)
    }
    public static let text = "Salı ve perşembe 18.00’de yüzmek istiyorum. Düzenli hareket etmek bana iyi geliyor. İşten sonra kendime zaman ayırmak istiyorum. Bugün işte gerildim; yüzdükten sonra rahatladım. Akşam biraz yorgundum."
    public static let focusNodeID = "tour-swimming"
    public static let graph = MobileAtlas.Graph(nodes: [
        .init(id: "tour-self", label: "Kendime zaman", status: "observation", summary: "İşten sonra kendine zaman ayırmak istiyorsun.", updatedAt: "", topicPath: ["Kişisel zaman"]),
        .init(id: "tour-movement", label: "Düzenli hareket", status: "observation", summary: "Düzenli hareket etmenin sana iyi geldiğini yazdın.", updatedAt: "", topicPath: ["Hareket"]),
        .init(id: focusNodeID, label: "Yüzme", status: "observation", summary: "Salı ve perşembe 18.00’de yüzmek istiyorsun. Bu plan, kendine zaman ayırma isteğin ve düzenli hareketle bağlantılı.", updatedAt: "", topicPath: ["Hareket", "Yüzme"]),
        .init(id: "tour-routine", label: "Haftalık düzen", status: "observation", summary: "Planın haftada iki yüzme seansı: salı ve perşembe.", updatedAt: "", topicPath: ["Düzen"]),
    ], edges: [
        .init(id: "tour-edge-1", source: "tour-self", target: "tour-movement", relation: "destekliyor"),
        .init(id: "tour-edge-2", source: "tour-movement", target: focusNodeID, relation: "örneği"),
        .init(id: "tour-edge-3", source: focusNodeID, target: "tour-routine", relation: "planlanıyor"),
    ])
    public static let prompt = """
    # Kişisel bağlamım · tanıtım örneği
    - İşten sonra kendime zaman ayırmak istiyorum.
    - Düzenli hareket etmek bana iyi geliyor.
    - Salı ve perşembe 18.00’de yüzmek istiyorum.

    Bağlantılar: Kişisel zaman → Düzenli hareket → Yüzme → Haftalık düzen
    Kaynak: Örnek günlük

    Bu bağlamdan yalnız verdiğim işle ilgili parçaları kullan.
    """
}
