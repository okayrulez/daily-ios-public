import Foundation

/// Resource Manager display names and Service Usage resource names have different constraints.
public enum GoogleProjectSetup {
    public static func displayName(_ input: String) -> String {
        let folded = input.replacingOccurrences(of: "ı", with: "i")
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-'\" !")
        let cleaned = String(folded.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : Character(" ") })
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let name = cleaned.isEmpty ? "dAIly Personal" : cleaned.count < 4 ? "dAIly " + cleaned : cleaned
        return String(name.prefix(30))
    }

    public static func serviceEnableURL(projectNumber: String) throws -> String {
        guard !projectNumber.isEmpty, projectNumber.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw WorkspaceError.malformedRecord
        }
        return "https://serviceusage.googleapis.com/v1/projects/\(projectNumber)/services/firestore.googleapis.com:enable"
    }
}
