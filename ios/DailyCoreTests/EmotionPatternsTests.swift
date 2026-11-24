import XCTest
@testable import DailyCore

final class EmotionPatternsTests: XCTestCase {
    private func day(_ date: String, context: String = "work-presentation", keys: [String] = ["tension", "relief"], ordered: Bool = true) -> EmotionDay {
        let observations = keys.enumerated().map { index, key in
            var item = EmotionObservation(id: date + key, key: key, label: EmotionDefinition.find(key)?.title ?? key,
                definition: "", intensity: nil, event: context == "work-presentation" ? "Sunum aşaması \(index)" : "Evdeki konuşma", quote: date + " kaynak \(index)", sequence: index)
            item.contextKey = context; item.contextLabel = context == "work-presentation" ? "Sunum" : "Başka deneyim"
            item.orderKnown = ordered
            return item
        }
        var day = EmotionDay(date: date, sourceID: "journal-" + date, reflection: "", observations: observations,
            helpful: [], connections: [], userSelected: false)
        day.sourceFingerprint = date
        return day
    }
    func testOverviewOnlyShowsDistinctTransitionsWithKnownSharedOrder() {
        XCTAssertEqual(day("2026-11-01").chronologicalEmotionStages.map { $0.map(\.key) }, [["tension"], ["relief"]])
        XCTAssertTrue(day("2026-11-01", ordered: false).chronologicalEmotionStages.isEmpty)
        XCTAssertTrue(withSegmentGroups(day("2026-11-01")).chronologicalEmotionStages.isEmpty)
        XCTAssertTrue(day("2026-11-01", keys: ["tension", "tension", "fatigue"]).chronologicalEmotionStages.isEmpty)
        XCTAssertEqual(day("2026-11-01", keys: ["tension", "tension", "relief", "fatigue"]).chronologicalEmotionStages.map { $0.map(\.key) }, [["tension"], ["relief"]])
    }
    func testSameEmotionOrderInUnrelatedContextsIsNotAPattern() {
        XCTAssertTrue(EmotionPatterns.patterns(in: [day("2026-11-01"), day("2026-11-02", context: "family-conversation")]).isEmpty)
    }
    func testEmotionWordsAloneDoNotBecomeAnExperienceContext() {
        var observation = EmotionObservation(id: "only-feeling", key: "tension", label: "Gerilim", definition: "", intensity: nil,
            event: "Gün içinde kaygı", quote: "Bugün kaygı hissettim", sequence: 0)
        observation.contextKey = "emotion-anxiety"
        XCTAssertNil(EmotionPatterns.context(of: observation))
    }
    func testExplicitlyDifferentConditionsAreNotCountedAsTheSameRepeatedExperience() {
        func conditioned(_ value: EmotionDay, _ condition: String) -> EmotionDay {
            var items = value.observations
            for index in items.indices { items[index].conditions = [condition] }
            return EmotionDay(date: value.date, sourceID: value.sourceID, reflection: "", observations: items, helpful: [], connections: [], userSelected: false)
        }
        let first = conditioned(day("2026-11-01"), "Hazırlık eksikliği")
        let other = conditioned(day("2026-11-02"), "İyi hazırlanma")
        XCTAssertTrue(EmotionPatterns.patterns(in: [first, other]).isEmpty)
    }
    func testPatternIncludesDifferentOutcomesAndDoesNotCountCopiedEvidence() {
        let first = day("2026-11-01"), second = day("2026-11-02")
        var duplicate = day("2026-11-03"); duplicate.sourceFingerprint = first.sourceFingerprint
        let different = day("2026-11-04", keys: ["tension", "sadness"])
        let patterns = EmotionPatterns.patterns(in: [first, second, duplicate, different])
        XCTAssertEqual(patterns.count, 1)
        XCTAssertEqual(patterns.first?.matching.count, 2)
        XCTAssertEqual(patterns.first?.different.map(\.date), [different.date])
    }
    func testUnknownOrderAndSeparateLongJournalSegmentsCannotBecomeChronologicalPatterns() {
        XCTAssertTrue(EmotionPatterns.patterns(in: [day("2026-11-01", ordered: false), day("2026-11-02", ordered: false)]).isEmpty)
        var first = day("2026-11-01"), second = day("2026-11-02")
        first = withSegmentGroups(first); second = withSegmentGroups(second)
        XCTAssertTrue(EmotionPatterns.patterns(in: [first, second]).isEmpty)
    }
    func testSimultaneousMixedFeelingsStayTogetherAndEnergyDoesNotReplaceThem() {
        var value = day("2026-11-01", keys: ["tension", "excitement", "fatigue"])
        let items = value.observations.map { item in
            var copy = EmotionObservation(id: item.id, key: item.key, label: item.label, definition: "", intensity: nil,
                event: "Sunuma hazırlık", quote: item.quote, sequence: 0)
            copy.contextKey = "work-presentation"; return copy
        }
        value = EmotionDay(date: value.date, sourceID: value.sourceID, reflection: "", observations: items, helpful: [], connections: [], userSelected: false)
        let episodes = EmotionPatterns.episodes(for: value)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.emotions.count, 2)
        XCTAssertEqual(episodes.first?.energy.map(\.key), ["fatigue"])
    }
    func testAutomaticHistoryIsContextualPastOnlyAndRetainsDifferentOutcomes() {
        let related = day("2026-11-01"), opposite = day("2026-11-02", keys: ["tension", "sadness"])
        var unrelated = day("2026-11-03", context: "family-conversation"); unrelated = selected(unrelated)
        let current = day("2026-11-04"), future = day("2026-11-05")
        let ranked = EmotionPatterns.relevantHistory(for: "Bugün sunum yaptım", before: current.date, days: [unrelated, related, opposite, future])
        XCTAssertEqual(Set(ranked.map(\.date)), [related.date, opposite.date])
        XCTAssertEqual(Set(EmotionPatterns.related(to: current, in: [related, opposite, future]).map(\.date)), [related.date, opposite.date])
    }
    private func withSegmentGroups(_ day: EmotionDay) -> EmotionDay {
        var items = day.observations
        for i in items.indices { items[i].orderGroup = "segment-\(i)" }
        return EmotionDay(date: day.date, sourceID: day.sourceID, reflection: "", observations: items, helpful: [], connections: [], userSelected: false)
    }
    private func selected(_ day: EmotionDay) -> EmotionDay {
        EmotionDay(date: day.date, sourceID: day.sourceID, reflection: "", observations: day.observations, helpful: [], connections: [], userSelected: true)
    }
}
