import Foundation

/// A current result for the reader. Evidence/history stays in storage, outside the main note view.
public enum AtlasNoteContent {
    private static func selected(in own: [MobileAtlas.Note]) -> MobileAtlas.Note? {
        let corrections = own.filter { $0.kind == "correction" }.sorted { $0.date < $1.date }
        let observations = own.filter { $0.kind == "observation" || $0.kind == "inference" }.sorted { $0.date < $1.date }
        return corrections.last ?? own.first(where: { $0.kind == "description" }) ?? observations.last
    }

    public struct Context {
        public let dates: [String]
        public let kind: String?
        public let journalQuote: String?
        public let quoteDate: String?
        public let sourceTitle: String?
    }

    public static func context(for node: MobileAtlas.Node, notes: [MobileAtlas.Note]) -> Context {
        let own = notes.filter { $0.nodeId == node.id && !$0.text.isEmpty }
        let selected = selected(in: own)
        let dates = (own.map(\.date) + [node.updatedAt]).map { String($0.prefix(10)) }
        let evidence = own.filter { $0.kind == "observation" || $0.kind == "inference" }
        let source = evidence.max { $0.date < $1.date }
        let journal = evidence.filter { $0.sourceKind == "journal" && $0.quote?.isEmpty == false }.max { $0.date < $1.date }
        return Context(dates: Set(dates).filter(WorkspaceIdentity.validDate).sorted(),
            kind: selected?.kind, journalQuote: journal?.quote, quoteDate: journal.map { String($0.date.prefix(10)) },
            sourceTitle: source?.sourceTitle)
    }

    public static func text(for node: MobileAtlas.Node, notes: [MobileAtlas.Note]) -> String {
        let own = notes.filter { $0.nodeId == node.id && !$0.text.isEmpty }
        guard let selected = selected(in: own) else { return node.summary }
        if let id = selected.contentID {
            let parts = Dictionary(grouping: own.filter { $0.contentID == id }, by: { $0.part ?? 0 })
            return parts.keys.sorted().compactMap { parts[$0]?.first?.text }.joined()
        }
        // Older pages lack part IDs. Rejoin only the contiguous chunks sharing the
        // selected entry's metadata, never concatenate the complete dated history.
        guard let index = own.lastIndex(where: { $0.kind == selected.kind && $0.date == selected.date && $0.text == selected.text }) else { return selected.text }
        var start = index
        while start > 0 {
            let prior = own[start - 1]
            guard prior.kind == selected.kind, prior.date == selected.date,
                  prior.sourceId == selected.sourceId, prior.quote == selected.quote,
                  prior.text.unicodeScalars.count == 4000 else { break }
            start -= 1
        }
        var end = index
        while end + 1 < own.count, own[end].text.unicodeScalars.count == 4000 {
            let next = own[end + 1]
            guard next.kind == selected.kind, next.date == selected.date,
                  next.sourceId == selected.sourceId, next.quote == selected.quote else { break }
            end += 1
        }
        return own[start...end].map(\.text).joined()
    }
}
