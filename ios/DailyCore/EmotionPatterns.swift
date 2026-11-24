import Foundation

public struct EmotionEpisode: Identifiable, Sendable {
    public let id, title: String
    public let sequence: Int
    public let observations: [EmotionObservation]
    public var orderKnown: Bool { observations.allSatisfy(\.orderKnown) }
    public var orderGroup: String { observations.first?.orderGroup ?? "" }
    public var emotions: [EmotionObservation] { observations.filter { !$0.isEnergy } }
    public var energy: [EmotionObservation] { observations.filter(\.isEnergy) }
}

public struct EmotionPattern: Identifiable, Sendable {
    public let id, title, sequence: String
    public let matching, different: [EmotionDay]
    public var conditions: [String] = []
}

/// Local indexes over grounded observations. Navigation never starts inference.
public enum EmotionPatterns {
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr"))
            .replacingOccurrences(of: "ı", with: "i")
    }
    private static let aliases: [(String, [String])] = [
        ("presentation", ["sunum", "presentation", "presenting"]),
        ("interview", ["mulakat", "is gorusmesi", "interview"]),
        ("walking", ["yuruyus", "yurum", "walking", "walk"]),
        ("deadline", ["teslim", "deadline"]), ("exam", ["sinav", "exam"]),
        ("training", ["antrenman", "egzersiz", "workout", "training"]),
        ("family", ["aile", "family"]), ("sleep", ["uyku", "sleep"])
    ]
    public static func contexts(in text: String) -> Set<String> {
        let value = normalized(text)
        return Set(aliases.filter { _, words in words.contains { value.contains($0) } }.map { $0.0 })
    }
    private static func meaningful(_ text: String) -> Bool {
        let generic: Set<String> = ["joy", "calm", "relief", "excitement", "anxiety", "tension", "sadness", "anger", "loneliness", "hope", "pride", "fatigue",
            "nese", "huzur", "rahatlama", "heyecan", "kaygi", "gerilim", "uzuntu", "ofke", "yalnizlik", "umut", "gurur", "yorgunluk",
            "gun", "icinde", "gunluk", "bugun", "duygu", "duygular", "duygusal", "his", "kendimi", "feeling", "feelings", "emotion", "emotional",
            "pattern", "cycle", "general", "daily", "personal", "work", "before", "after", "sonra", "once", "gundelik", "deneyim"]
        return normalized(text).split { !$0.isLetter }.contains { token in
            !generic.contains(String(token)) && !token.hasPrefix("hisset") && !token.hasPrefix("hissed")
        }
    }
    public static func context(of observation: EmotionObservation) -> String? {
        guard !observation.quote.isEmpty else { return nil }
        if let key = observation.contextKey, !key.isEmpty, meaningful(key) {
            let canonical = normalized(key)
            let familiar = ["work-presentation": "presentation", "presentation": "presentation", "sunum": "presentation",
                "walking": "walking", "daily-walking": "walking", "interview": "interview", "work-interview": "interview"]
            return familiar[canonical] ?? "context:" + canonical
        }
        let common = contexts(in: observation.event)
        if common.count == 1 { return common.first }
        // Old records can match an actual named event, never a shared emotion word alone.
        let event = normalized(observation.event).trimmingCharacters(in: .whitespacesAndNewlines)
        return event.count >= 8 && meaningful(event) && !["gun icindeki deneyim", "gun icinde", "bugun"].contains(event) ? "event:" + event : nil
    }
    public static func episodes(for day: EmotionDay) -> [EmotionEpisode] {
        var grouped: [String: [EmotionObservation]] = [:], order: [String] = []
        for item in day.observations {
            // Simultaneous feelings share a stage and context; unrelated unknown-time events remain separate.
            let key = String(item.sequence) + ":" + (item.contextKey ?? normalized(item.event))
                + (item.orderKnown ? "" : ":unknown:" + normalized(item.event))
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        return order.compactMap { key in
            guard let items = grouped[key], let first = items.first else { return nil }
            return EmotionEpisode(id: day.sourceID + ":" + key,
                title: first.event.isEmpty ? first.contextLabel ?? "Gün içindeki deneyim" : first.event,
                sequence: first.sequence, observations: items)
        }.sorted { $0.sequence < $1.sequence }
    }
    private static func dayContexts(_ day: EmotionDay) -> Set<String> {
        Set(day.observations.compactMap(context))
    }
    public static func related(to day: EmotionDay, in days: [EmotionDay]) -> [EmotionConnection] {
        let own = dayContexts(day)
        guard !own.isEmpty else { return [] }
        return days.filter { $0.date < day.date && (day.sourceFingerprint.isEmpty || $0.sourceFingerprint != day.sourceFingerprint) && !own.isDisjoint(with: dayContexts($0)) }
            .sorted { $0.date > $1.date }.prefix(3).map { prior in
                let shared = day.observations.first { item in context(of: item).map { dayContexts(prior).contains($0) } ?? false }
                let label = shared?.contextLabel ?? shared?.event ?? "Aynı deneyim"
                return EmotionConnection(date: prior.date, reason: label + " bağlamında başka bir kaynak gün. Hislerin ve sonuçların aynı olduğunu varsaymadan karşılaştır.", automaticContext: label)
            }
    }
    /// Connections keyed by calendar date, the identity of an emotion day.
    public static func connectionIndex(days: [EmotionDay]) -> [String: [EmotionConnection]] {
        var recent: [String: [EmotionDay]] = [:], result: [String: [EmotionConnection]] = [:]
        for day in days.sorted(by: { $0.date < $1.date }) {
            let keys = dayContexts(day)
            var candidates: [String: EmotionDay] = [:]
            for key in keys { for prior in recent[key] ?? [] { candidates[prior.date] = prior } }
            result[day.date] = related(to: day, in: Array(candidates.values))
            for key in keys { recent[key, default: []].append(day); recent[key] = Array((recent[key] ?? []).suffix(8)) }
        }
        return result
    }
    private static func signature(_ day: EmotionDay, context: String) -> String? {
        let observations = day.observations.filter { !$0.isEnergy && self.context(of: $0) == context }
        guard !observations.isEmpty, observations.allSatisfy(\.orderKnown), Set(observations.map(\.orderGroup)).count <= 1 else { return nil }
        let grouped = Dictionary(grouping: observations, by: \.sequence)
        guard grouped.count > 1 else { return nil }
        return grouped.keys.sorted().map { position in
            Set((grouped[position] ?? []).map(\.key)).sorted().joined(separator: "+")
        }.joined(separator: "|")
    }
    public static func patterns(in days: [EmotionDay]) -> [EmotionPattern] {
        var daysByContext: [String: [EmotionDay]] = [:]
        for day in days {
            if Task.isCancelled { return [] }
            for context in dayContexts(day) { daysByContext[context, default: []].append(day) }
        }
        return daysByContext.keys.sorted().compactMap { context in
            guard !Task.isCancelled, let candidates = daysByContext[context], candidates.count > 1 else { return nil }
            func conditions(_ day: EmotionDay) -> [String] {
                Set(day.observations.filter { self.context(of: $0) == context }.flatMap(\.conditions).map(normalized)).sorted()
            }
            let grouped = Dictionary(grouping: candidates.filter { signature($0, context: context) != nil }, by: {
                signature($0, context: context)! + "##" + conditions($0).joined(separator: "+")
            })
            func independentCount(_ items: [EmotionDay]) -> Int {
                Set(items.map { $0.sourceFingerprint.isEmpty ? $0.sourceID : $0.sourceFingerprint }).count
            }
            let ordered = grouped.sorted {
                independentCount($0.value) == independentCount($1.value) ? $0.key < $1.key : independentCount($0.value) > independentCount($1.value)
            }
            guard let best = ordered.first else { return nil }
            var fingerprints = Set<String>()
            let matching = best.value.sorted { $0.date > $1.date }.filter {
                fingerprints.insert($0.sourceFingerprint.isEmpty ? $0.sourceID : $0.sourceFingerprint).inserted
            }
            guard matching.count >= 2, let example = matching.first else { return nil }
            let relevant = example.observations.filter { self.context(of: $0) == context && !$0.isEnergy }
            let stages = Dictionary(grouping: relevant, by: \.sequence)
            let label = stages.keys.sorted().map { position in
                Array(Set((stages[position] ?? []).map(\.label))).sorted().joined(separator: " + ")
            }.joined(separator: " → ")
            let different = candidates.filter { signature($0, context: context).map { $0 != signature(example, context: context) } ?? false }.sorted { $0.date > $1.date }
            var pattern = EmotionPattern(id: context, title: relevant.first?.contextLabel ?? relevant.first?.event ?? "Tekrarlanan deneyim",
                sequence: label, matching: matching, different: different)
            pattern.conditions = Array(Set(relevant.flatMap(\.conditions))).sorted()
            return pattern
        }.sorted { ($0.matching.first?.date ?? "") > ($1.matching.first?.date ?? "") }
    }
    public static func relevantHistory(for text: String, before date: String, days: [EmotionDay]) -> [EmotionDay] {
        let stop: Set<String> = ["bugun", "sonra", "once", "bazen", "kendimi", "hissettim", "olarak", "kadar", "yaptim"]
        let wanted = contexts(in: text), query = Set(normalized(text).split { !$0.isLetter }.filter { $0.count > 4 }.map(String.init)).subtracting(stop)
        func relevance(_ day: EmotionDay) -> Int {
            let signals = Set(day.observations.flatMap { contexts(in: ($0.contextKey ?? "") + " " + ($0.contextLabel ?? "") + " " + $0.event) })
            let contextual = wanted.intersection(signals).count * 12
            let labels = normalized(day.observations.map { ($0.contextLabel ?? "") + " " + $0.event }.joined(separator: " "))
            let lexical = query.filter { labels.contains($0) }.count
            let base = contextual + lexical
            return base > 0 ? base + (day.userSelected ? 2 : 0) : 0
        }
        let ranked = days.filter { $0.date < date && relevance($0) > 0 }.sorted {
            relevance($0) == relevance($1) ? $0.date > $1.date : relevance($0) > relevance($1)
        }
        var signatures = Set<String>(), diverse: [EmotionDay] = [], remaining: [EmotionDay] = []
        for day in ranked {
            let signature = dayContexts(day).sorted().joined(separator: ",") + ":" + (day.sequenceSignature ?? day.keys.sorted().joined(separator: "+"))
            if signatures.insert(signature).inserted { diverse.append(day) } else { remaining.append(day) }
        }
        return diverse + remaining
    }
}
