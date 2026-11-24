import Foundation

public enum FirestorePathError: Error, Equatable {
    case invalidSegment(String)
}

public enum FirestorePaths {
    public static func validatedSegment(_ value: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy(allowed.contains),
              value != ".",
              value != ".." else {
            throw FirestorePathError.invalidSegment(value)
        }
        return value
    }

    public static func day(uid: String, localDate: String) -> String {
        "users/\(uid)/days/\(localDate)"
    }

    public static func questions(uid: String, localDate: String) -> String {
        "\(day(uid: uid, localDate: localDate))/questions"
    }

    public static func processingJob(uid: String, jobID: String) -> String {
        "users/\(uid)/processingJobs/\(jobID)"
    }
}
