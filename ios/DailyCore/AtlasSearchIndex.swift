import Foundation

/// An in-memory projection of the validated atlas pages on this device.
public struct AtlasSearchIndex: Sendable {
    public struct Match: Identifiable, Sendable {
        public let mapID: String
        public let mapTitle: String
        public let nodeID: String?
        public let title: String
        public let excerpt: String?
        public let date: String?
        public let sourceTitle: String?

        public var id: String { mapID + ":" + (nodeID ?? "") }
    }

    private struct Document: Sendable {
        let map: MobileAtlas.Map
        let node: MobileAtlas.Node
        let notes: [MobileAtlas.Note]
    }

    public let hasUnavailablePages: Bool
    private let maps: [MobileAtlas.Map]
    private let documents: [Document]

    public init(atlas: MobileAtlas, records: [String: WorkspaceRecord]) throws {
        maps = atlas.maps
        var documents: [Document] = []
        var unavailable = false
        for map in atlas.maps {
            try Task.checkCancellation()
            let pages = map.pages.compactMap { records[WorkspaceHash.sha256($0.key)] }
            let details = (map.detailPages ?? []).compactMap { records[WorkspaceHash.sha256($0.key)] }
            guard let graph = try? MobileAtlas.graph(for: map, records: pages) else {
                unavailable = true
                continue
            }
            let notes = try? MobileAtlas.notes(for: map, records: details)
            if notes == nil { unavailable = true }
            let notesByNode = Dictionary(grouping: notes ?? [], by: \.nodeId)
            documents += graph.nodes.map {
                Document(map: map, node: $0, notes: notesByNode[$0.id] ?? [])
            }
        }
        try Task.checkCancellation()
        self.documents = documents
        hasUnavailablePages = unavailable
    }

    public func search(_ query: String, locale: Locale) throws -> [Match] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func includes(_ text: String, _ term: String) -> Bool {
            text.range(of: term, options: options, locale: locale) != nil
        }
        func matches(_ text: String) -> Bool { terms.allSatisfy { includes(text, $0) } }

        var results = maps.filter { matches($0.title) }.map {
            Match(mapID: $0.id, mapTitle: $0.title, nodeID: nil, title: $0.title,
                  excerpt: nil, date: nil, sourceTitle: nil)
        }
        var contentMatches: [Match] = []
        for document in documents {
            try Task.checkCancellation()
            let map = document.map
            let node = document.node
            let heading = [map.title, node.label] + node.topicPath
            let remaining = terms.filter { term in !heading.contains(where: { includes($0, term) }) }
            let labelMatch = matches(node.label)
            let contentTerms = remaining.isEmpty ? terms : remaining
            let note = document.notes.first { note in contentTerms.allSatisfy { includes(note.text, $0) } }
            let pathMatch = remaining.isEmpty && !matches(map.title)
            guard labelMatch || pathMatch || note != nil || contentTerms.allSatisfy({ includes(node.summary, $0) }) else {
                continue
            }
            let source = note ?? document.notes.last(where: { $0.sourceTitle?.isEmpty == false })
            let text = note?.text ?? node.summary
            let match = Match(mapID: map.id, mapTitle: map.title, nodeID: node.id, title: node.label,
                              excerpt: Self.excerpt(text, terms: contentTerms, locale: locale),
                              date: source?.date ?? node.updatedAt, sourceTitle: source?.sourceTitle)
            if labelMatch { results.append(match) }
            else { contentMatches.append(match) }
        }
        return results + contentMatches
    }

    private static func excerpt(_ text: String, terms: [String], locale: Locale) -> String? {
        guard !text.isEmpty else { return nil }
        let match = terms.lazy.compactMap {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        }.first
        let start = match.flatMap { text.index($0.lowerBound, offsetBy: -32, limitedBy: text.startIndex) } ?? text.startIndex
        let end = text.index(start, offsetBy: 140, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + String(text[start..<end]) + (end == text.endIndex ? "" : "…")
    }
}
