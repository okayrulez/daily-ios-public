import Foundation

/// Tracks one analysis through its serial model requests, validation passes and local commit.
/// Time between these operations includes source preparation, synchronization and checkpoint I/O.
public final class AnalysisPhaseTimings: @unchecked Sendable {
    @TaskLocal public static var current: AnalysisPhaseTimings?
    public enum Phase: String, CaseIterable, Sendable {
        case preparation, inference, validation, commit
    }

    private let lock = NSLock()
    private let start = DispatchTime.now().uptimeNanoseconds
    private var durations: [Phase: UInt64] = [:]
    private var finished = false

    public init() {}

    public func record(_ phase: Phase, since: DispatchTime) {
        let elapsed = DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds
        lock.withLock {
            if !finished { durations[phase, default: 0] += elapsed }
        }
    }

    public func finish() -> [(Phase, Int)] {
        lock.withLock {
            guard !finished else { return [] }
            finished = true
            let total = DispatchTime.now().uptimeNanoseconds - start
            let classified = durations.values.reduce(0, +)
            durations[.preparation] = total - min(total, classified)
            return Phase.allCases.map { ($0, Int(durations[$0, default: 0] / 1_000_000)) }
        }
    }
}
