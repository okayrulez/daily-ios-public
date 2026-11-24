import Foundation

public struct EmotionMapField: Identifiable, Sendable {
    public let id, title: String
    public let graph: MobileAtlas.Graph
    public let nodeEmotions: [String: [String]]
    public let sourceDays: [String: [EmotionDay]]
}

/// The emotional layer uses actual atlas nodes, matching their dated, quoted evidence.
public enum EmotionMapLinks {
    public static func fields(records: [WorkspaceRecord], days: [EmotionDay]) throws -> [EmotionMapField] {
        guard let atlas = try MobileAtlas.load(records: records) else { return [] }
        return try atlas.maps.compactMap { map in
            try Task.checkCancellation()
            let notes = try MobileAtlas.notes(for: map, records: records)
            let (emotions, sources) = try matches(notes: notes, days: days)
            guard !emotions.isEmpty else { return nil }
            let graph = try MobileAtlas.graph(for: map, records: records)
            let ids = Set(graph.nodes.map(\.id))
            let visible = emotions.filter { ids.contains($0.key) }
            guard !visible.isEmpty else { return nil }
            return EmotionMapField(id: map.id, title: map.title, graph: graph,
                nodeEmotions: visible, sourceDays: sources.filter { ids.contains($0.key) })
        }
    }

    public static func matches(notes: [MobileAtlas.Note], days: [EmotionDay]) throws
        -> (emotions: [String: [String]], sources: [String: [EmotionDay]]) {
        let bySource = Dictionary(grouping: days, by: \.sourceID)
        var emotions: [String: Set<String>] = [:], sources: [String: [String: EmotionDay]] = [:]
        for note in notes {
            try Task.checkCancellation()
            guard let source = note.sourceId, let day = bySource[source]?.first(where: { $0.date == note.date }),
                  let quote = note.quote, !quote.isEmpty else { continue }
            let grounded = day.observations.filter { $0.quote == quote }
            guard !grounded.isEmpty else { continue }
            emotions[note.nodeId, default: []].formUnion(grounded.map(\.key))
            sources[note.nodeId, default: [:]][day.date] = day
        }
        return (emotions.mapValues { $0.sorted() }, sources.mapValues { $0.values.sorted { $0.date > $1.date } })
    }
}
