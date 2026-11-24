import Foundation

public enum DayStatus: String, Codable, Sendable {
    case draft
    case queued
    case processing
    case complete
    case failed
}

public enum ProcessingReason: String, Codable, Sendable {
    case initial
    case answers
}

public struct DaySnapshot: Equatable, Sendable {
    public let localDate: String
    public let rawText: String
    public let revision: Int
    public let answerRevision: Int
    public let status: DayStatus
    public let processingReason: ProcessingReason?
    public let deviceID: String
    public let updatedAt: Date

    public init(
        localDate: String,
        rawText: String,
        revision: Int,
        answerRevision: Int,
        status: DayStatus,
        processingReason: ProcessingReason?,
        deviceID: String,
        updatedAt: Date
    ) {
        self.localDate = localDate
        self.rawText = rawText
        self.revision = revision
        self.answerRevision = answerRevision
        self.status = status
        self.processingReason = processingReason
        self.deviceID = deviceID
        self.updatedAt = updatedAt
    }
}

public struct ProcessingJob: Equatable, Sendable {
    public let reason: ProcessingReason
    public let sourceRevision: Int
    public let sourceAnswerRevision: Int
}

public struct JournalSavePlan: Equatable, Sendable {
    public let day: DaySnapshot
    public let jobID: String
    public let job: ProcessingJob
}

public enum JournalSaveError: Error, Equatable {
    case revisionConflict(serverRevision: Int)
}

public enum JournalSavePlanner {
    public static func plan(
        current: DaySnapshot?,
        localDate: String,
        rawText: String,
        expectedRevision: Int,
        deviceID: String,
        now: Date
    ) throws -> JournalSavePlan {
        let serverRevision = current?.revision ?? 0
        guard serverRevision == expectedRevision else {
            throw JournalSaveError.revisionConflict(serverRevision: serverRevision)
        }

        let revision = serverRevision + 1
        let answerRevision = current?.answerRevision ?? 0
        let day = DaySnapshot(
            localDate: localDate,
            rawText: rawText,
            revision: revision,
            answerRevision: answerRevision,
            status: .queued,
            processingReason: .initial,
            deviceID: deviceID,
            updatedAt: now
        )
        let job = ProcessingJob(
            reason: .initial,
            sourceRevision: revision,
            sourceAnswerRevision: answerRevision
        )
        return JournalSavePlan(
            day: day,
            jobID: "\(localDate)-initial-r\(revision)-a\(answerRevision)",
            job: job
        )
    }
}
