import Foundation

public struct EmotionDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let emoji: String
    public let meaning: String
    public static let defaults: [EmotionDefinition] = [
        .init(id: "joy", title: "Neşe", emoji: "😄", meaning: "Sevinç, keyif ve hoşnutluk"),
        .init(id: "calm", title: "Huzur", emoji: "🌿", meaning: "Sakinlik ve güven"),
        .init(id: "relief", title: "Rahatlama", emoji: "😌", meaning: "Gerilim veya yük sonrasında gelen ferahlama"),
        .init(id: "excitement", title: "Heyecan", emoji: "🤩", meaning: "Heves, coşku ve hareketli beklenti"),
        .init(id: "anxiety", title: "Kaygı", emoji: "😟", meaning: "Belirsizlik ve olası sonuçlarla ilgili endişe"),
        .init(id: "tension", title: "Gerilim", emoji: "😣", meaning: "Baskı, sıkışmışlık ve zorlanma"),
        .init(id: "sadness", title: "Üzüntü", emoji: "😔", meaning: "Keder, kırgınlık ve kayıp hissi"),
        .init(id: "anger", title: "Öfke", emoji: "😠", meaning: "Kızgınlık ve tepki"),
        .init(id: "loneliness", title: "Yalnızlık", emoji: "🥺", meaning: "Yakınlık veya bağ kurma eksikliği"),
        .init(id: "hope", title: "Umut", emoji: "🌤️", meaning: "Geleceğe yönelik olumlu beklenti"),
        .init(id: "pride", title: "Gurur", emoji: "🥹", meaning: "Kendinden veya yaptığından memnuniyet"),
        .init(id: "fatigue", title: "Yorgunluk", emoji: "😴", meaning: "Bildirilen enerji düşüklüğü ve dinlenme ihtiyacı")
    ]
    public static func canonical(_ value: String) -> String {
        let text = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr")).replacingOccurrences(of: "ı", with: "i")
        let aliases: [String: String] = [
            "mutluluk": "joy", "nese": "joy", "happy": "joy", "happiness": "joy",
            "huzur": "calm", "sakinlik": "calm", "rahatlama": "relief", "relief": "relief", "peace": "calm",
            "heyecan": "excitement", "kaygi": "anxiety", "endise": "anxiety",
            "gerilim": "tension", "stres": "tension", "stress": "tension", "overwhelmed": "tension",
            "uzuntu": "sadness", "ofke": "anger", "yalnizlik": "loneliness",
            "umut": "hope", "gurur": "pride", "yorgunluk": "fatigue", "tired": "fatigue"
        ]
        return aliases[text] ?? text
    }
    public static func find(_ key: String) -> EmotionDefinition? {
        defaults.first { $0.id == canonical(key) }
    }
}

public struct EmotionObservation: Identifiable, Equatable, Sendable {
    public let id: String
    public let key: String
    public let label: String
    public let definition: String
    public let intensity: Int?
    public let event: String
    public let quote: String
    public let sequence: Int
    public var contextKey: String? = nil
    public var contextLabel: String? = nil
    public var conditions: [String] = []
    public var topicPath: [String] = []
    public var orderKnown = true
    public var orderGroup = ""
    public var userSelected = false
    public var originalID: String? = nil
    public var originalKey: String? = nil
    public var originalLabel: String? = nil
    public var kind = "emotion"
    public var isEnergy: Bool { key == "fatigue" || kind == "energy" }
    public var correctionID: String { originalID ?? id }
    public static func identity(key: String, quote: String, sequence: Int) -> String {
        let value = JSONValue.array([.string(EmotionDefinition.canonical(key)), .string(quote), .number(Double(sequence))])
        return WorkspaceHash.sha256((try? value.canonical()) ?? "")
    }
}

public struct EmotionHelpfulAction: Identifiable, Equatable, Sendable {
    public let action, quote, date: String
    public var id: String { date + ":" + action + ":" + quote }
}

public struct EmotionConnection: Identifiable, Equatable, Sendable {
    public let date: String
    public let reason: String
    public var id: String { date }
    public var automaticContext: String? = nil
}

public struct EmotionDay: Identifiable, Equatable, Sendable {
    public let date: String
    public let sourceID: String
    public let reflection: String
    public let observations: [EmotionObservation]
    public let helpful: [String]
    public let connections: [EmotionConnection]
    public let userSelected: Bool
    public var sourceFingerprint = ""
    public var calendarKeys: [String]? = nil
    public var helpfulEvidence: [EmotionHelpfulAction] = []
    public var originalObservations: [EmotionObservation] = []
    public var id: String { date }
    public var stages: [[EmotionObservation]] {
        let grouped = Dictionary(grouping: observations, by: \.sequence)
        return grouped.keys.sorted().map { grouped[$0] ?? [] }
    }
    public var chronologicalEmotionStages: [[EmotionObservation]] {
        let emotions = observations.filter { !$0.isEnergy }
        guard emotions.allSatisfy(\.orderKnown), Set(emotions.map(\.orderGroup)).count == 1 else { return [] }
        let bySequence = Dictionary(grouping: emotions, by: \.sequence)
        var distinct: [[EmotionObservation]] = []
        var previous: Set<String> = []
        for sequence in bySequence.keys.sorted() {
            var seen: Set<String> = []
            let stage = (bySequence[sequence] ?? []).filter { seen.insert($0.key).inserted }
            if seen != previous {
                distinct.append(stage)
                previous = seen
            }
        }
        return distinct.count > 1 ? distinct : []
    }
    public var sequenceSignature: String? {
        guard observations.allSatisfy(\.orderKnown), Set(observations.map(\.orderGroup)).count <= 1, stages.count > 1 else { return nil }
        return stages.map { Set($0.map(\.key)).sorted().joined(separator: "+") }.joined(separator: "|")
    }
    public var sequenceLabel: String {
        stages.map { $0.map(\.label).sorted().joined(separator: " + ") }.joined(separator: " → ")
    }
    public var keys: [String] {
        if let calendarKeys { return calendarKeys }
        var seen = Set<String>()
        return observations.map(\.key).filter { seen.insert($0).inserted }
    }
}

public enum EmotionHistory {
    public static func export(days: [EmotionDay]) -> JSONValue {
        .array(days.map { day in .object([
            "sourceID": .string(day.sourceID), "date": .string(day.date),
            "reflection": .string(day.reflection), "userSelected": .bool(day.userSelected),
            "helpful": .array(day.helpful.map(JSONValue.string)),
            "helpfulEvidence": .array(day.helpfulEvidence.map { .object([
                "action": .string($0.action), "quote": .string($0.quote), "date": .string($0.date)]) }),
            "observations": .array(day.observations.map { item in .object([
                "key": .string(item.key), "label": .string(item.label), "event": .string(item.event),
                "quote": .string(item.quote), "sequence": .number(Double(item.sequence)),
                "intensity": item.intensity.map { JSONValue.number(Double($0)) } ?? .null,
                "contextKey": item.contextKey.map(JSONValue.string) ?? .null,
                "contextLabel": item.contextLabel.map(JSONValue.string) ?? .null,
                "orderKnown": .bool(item.orderKnown), "userSelected": .bool(item.userSelected),
                "kind": .string(item.isEnergy ? "energy" : "emotion"),
                "orderGroup": .string(item.orderGroup), "conditions": .array(item.conditions.map(JSONValue.string))
            ]) })
        ]) })
    }

    /// A projection of cached, completed records. No network, model call or persistent derived copy.
    public static func days(records: [WorkspaceRecord]) -> [EmotionDay] {
        let journals = records.filter { $0.kind == .journal }.compactMap { try? $0.journal() }
        // A migrated source ID can appear on multiple dates. Keep both days and
        // omit explicit links whose target identity is ambiguous.
        let dates = Dictionary(grouping: journals, by: \.id).compactMapValues { matches in
            matches.count == 1 ? matches.first?.date : nil
        }
        let projected = journals.compactMap { day(journal: $0, knownDates: dates) }.sorted { $0.date < $1.date }
        let connections = EmotionPatterns.connectionIndex(days: projected)
        return projected.map { day in
            day.withConnections(connections[day.date] ?? [])
        }
    }

    public static func day(journal: JournalDocument, knownDates: [String: String] = [:]) -> EmotionDay? {
        guard journal.analysisStatus == "complete",
              let latest = journal.analyses.max(by: { $0.version < $1.version }) else { return nil }
        let result = latest.fields["result"]?.object ?? [:]
        let structured = journal.payload.object?["emotional_memory"]?.object ?? result["emotional_memory"]?.object
        if let sourceHash = structured?["source_hash"]?.string,
           sourceHash != WorkspaceHash.sha256(journal.rawText) { return nil }
        let sourceTexts = [journal.rawText] + journal.answeredQuestions.compactMap(\.answerText)
            + (journal.payload.object?["supplemental_answers"]?.array ?? []).compactMap { $0.object?["answer"]?.string }
        let rows = structured?["observations"]?.array ?? []
        let legacyOrderKnown = Set(rows.compactMap { $0.object?["sequence"]?.integer }).count > 1
        var observations = rows.enumerated().compactMap { index, value -> EmotionObservation? in
            guard let fields = value.object, let key = fields["key"]?.string,
                  let label = fields["label"]?.string, let quote = fields["quote"]?.string,
                  !quote.isEmpty, sourceTexts.contains(where: { $0.contains(quote) }) else { return nil }
            var item = observation(key: key, label: label, fields: fields, index: index)
            if fields["order_basis"] == nil { item.orderKnown = legacyOrderKnown }
            return item
        }
        // Old builds already returned emotions. Their source reference may be an ID, not a quotation.
        if structured == nil {
            observations = (result["emotions"]?.array ?? []).enumerated().compactMap { index, value in
                guard var fields = value.object, let key = fields["key"]?.string,
                      let label = fields["label"]?.string else { return nil }
                let reference = fields["evidence_ref"]?.string ?? ""
                fields["quote"] = .string(!reference.isEmpty && sourceTexts.contains(where: { $0.contains(reference) }) ? reference : "")
                fields["event"] = fields["trigger"] ?? .string("")
                fields["sequence"] = .number(0)
                fields["order_basis"] = .string("unknown")
                return observation(key: key, label: label, fields: fields, index: index)
            }
        }
        let originals = observations
        let correction = journal.payload.object?["emotion_override"]?.object
        let corrected = correction?["source_hash"]?.string == WorkspaceHash.sha256(journal.rawText)
        let hasTargeted = journal.payload.object?["emotion_observation_overrides"]?.object?["source_hash"]?.string == WorkspaceHash.sha256(journal.rawText)
        if corrected, !hasTargeted, let choices = correction?["choices"]?.array {
            let keys = choices.compactMap(\.string).map(EmotionDefinition.canonical)
            observations = observations.filter { keys.contains($0.key) }.map { original in
                var copy = original; copy.userSelected = true; return copy
            }
            for key in keys where !observations.contains(where: { $0.key == key }) {
                var added = observation(key: key, label: EmotionDefinition.find(key)?.title ?? key,
                    fields: ["sequence": .number(0), "order_basis": .string("unknown")], index: observations.count)
                added.userSelected = true; observations.append(added)
            }
        }
        let overrides = journal.payload.object?["emotion_observation_overrides"]?.object
        if overrides?["source_hash"]?.string == WorkspaceHash.sha256(journal.rawText) {
            observations = observations.flatMap { original -> [EmotionObservation] in
                let candidates = (overrides?["edits"]?.array ?? []).filter { item in
                    let row = item.object
                    return row?["quote"]?.string == original.quote
                        && (row?["original_key"]?.string).map(EmotionDefinition.canonical) == original.key
                }
                let uniqueQuote = originals.filter { $0.key == original.key && $0.quote == original.quote }.count == 1
                let edit = candidates.last { $0.object?["observation_id"]?.string == original.id && $0.object?["sequence"]?.integer == original.sequence }
                    ?? (uniqueQuote && candidates.count == 1 ? candidates.first : nil)
                guard let choices = edit?.object?["choices"]?.array else { return [original] }
                var seen = Set<String>()
                return choices.compactMap { choice -> EmotionObservation? in
                    guard let raw = choice.string else { return nil }
                    let key = EmotionDefinition.canonical(raw)
                    guard seen.insert(key).inserted else { return nil }
                    var copy = observation(key: key, label: EmotionDefinition.find(key)?.title ?? originals.first(where: { $0.key == key })?.label ?? key,
                        fields: ["event": .string(original.event), "quote": .string(original.quote), "sequence": .number(Double(original.sequence)),
                                 "intensity": key == original.key ? original.intensity.map { .number(Double($0)) } ?? .null : .null], index: 0)
                    copy.contextKey = original.contextKey; copy.contextLabel = original.contextLabel; copy.topicPath = original.topicPath
                    copy.conditions = original.conditions
                    copy.kind = key == original.key ? original.kind : key == "fatigue" ? "energy" : "emotion"
                    copy.orderKnown = original.orderKnown; copy.userSelected = true
                    copy.orderGroup = original.orderGroup
                    copy.originalID = original.id; copy.originalKey = original.key; copy.originalLabel = original.label
                    return copy
                }
            }
        }
        var observationIDs = Set<String>()
        observations = observations.filter { observationIDs.insert($0.id).inserted }
        var seenDates = Set<String>()
        let connections = (result["connections"]?.array ?? []).compactMap { value -> EmotionConnection? in
            guard let row = value.object, let sourceID = row["target_journal_id"]?.string,
                  let date = knownDates[sourceID], date == row["target_date"]?.string,
                  date < journal.date, seenDates.insert(date).inserted else { return nil }
            return EmotionConnection(date: date, reason: row["reason"]?.string ?? "")
        }
        var helpfulIDs = Set<String>()
        let helpful = (structured?["helpful"]?.array ?? []).compactMap { value -> EmotionHelpfulAction? in
            guard let row = value.object, let quote = row["quote"]?.string, !quote.isEmpty,
                  sourceTexts.contains(where: { $0.contains(quote) }) else { return nil }
            guard let action = row["action"]?.string else { return nil }
            let item = EmotionHelpfulAction(action: action, quote: quote, date: journal.date)
            return helpfulIDs.insert(item.id).inserted ? item : nil
        }
        var day = EmotionDay(date: journal.date, sourceID: journal.id, reflection: journal.dayReflection ?? "",
            observations: observations.sorted { $0.sequence < $1.sequence }, helpful: helpful.map(\.action),
            connections: connections, userSelected: corrected || observations.contains(where: \.userSelected))
        day.sourceFingerprint = WorkspaceHash.sha256(journal.rawText)
        day.helpfulEvidence = helpful
        day.originalObservations = originals
        let calendar = journal.payload.object?["emotion_calendar_override"]?.object ?? (hasTargeted ? correction : nil)
        if calendar?["source_hash"]?.string == day.sourceFingerprint {
            day.calendarKeys = calendar?["choices"]?.array?.compactMap(\.string).map(EmotionDefinition.canonical)
            if overrides?["source_hash"]?.string == day.sourceFingerprint {
                for edit in overrides?["edits"]?.array ?? [] {
                    guard let key = edit.object?["original_key"]?.string else { continue }
                    let candidates = originals.filter { $0.key == EmotionDefinition.canonical(key) && $0.quote == edit.object?["quote"]?.string }
                    guard candidates.contains(where: { $0.id == edit.object?["observation_id"]?.string }) || candidates.count == 1 else { continue }
                    if !observations.contains(where: { $0.key == EmotionDefinition.canonical(key) }) {
                        day.calendarKeys?.removeAll { $0 == EmotionDefinition.canonical(key) }
                    }
                    for choice in edit.object?["choices"]?.array?.compactMap(\.string) ?? [] {
                        let canonical = EmotionDefinition.canonical(choice)
                        if !(day.calendarKeys?.contains(canonical) ?? false) { day.calendarKeys?.append(canonical) }
                    }
                }
            }
        }
        return day
    }

    private static func observation(key: String, label: String, fields: [String: JSONValue], index: Int) -> EmotionObservation {
        let canonical = EmotionDefinition.find(key)?.id ?? EmotionDefinition.find(label)?.id ?? EmotionDefinition.canonical(key)
        let quote = fields["quote"]?.string ?? "", sequence = fields["sequence"]?.integer ?? index
        var result = EmotionObservation(id: EmotionObservation.identity(key: canonical, quote: quote, sequence: sequence), key: canonical,
            label: EmotionDefinition.find(canonical)?.title ?? label,
            definition: fields["definition"]?.string ?? EmotionDefinition.find(canonical)?.meaning ?? "",
            intensity: fields["intensity"]?.integer.flatMap { (1...5).contains($0) ? $0 : nil },
            event: fields["event"]?.string ?? "", quote: fields["quote"]?.string ?? "",
            sequence: sequence)
        result.contextKey = fields["context_key"]?.string
        result.contextLabel = fields["context_label"]?.string
        result.conditions = fields["conditions"]?.array?.compactMap(\.string) ?? []
        result.topicPath = fields["topic_path"]?.array?.compactMap(\.string) ?? []
        result.orderKnown = fields["order_basis"]?.string != "unknown"
        result.orderGroup = fields["order_group"]?.string ?? ""
        result.kind = fields["kind"]?.string ?? (canonical == "fatigue" ? "energy" : "emotion")
        return result
    }
}

extension EmotionDay {
    fileprivate func withConnections(_ automatic: [EmotionConnection]) -> EmotionDay {
        let seen = Set(connections.map(\.date))
        var result = EmotionDay(date: date, sourceID: sourceID, reflection: reflection, observations: observations,
            helpful: helpful, connections: connections + automatic.filter { !seen.contains($0.date) }, userSelected: userSelected)
        result.sourceFingerprint = sourceFingerprint; result.calendarKeys = calendarKeys; result.helpfulEvidence = helpfulEvidence
        result.originalObservations = originalObservations
        return result
    }
}
