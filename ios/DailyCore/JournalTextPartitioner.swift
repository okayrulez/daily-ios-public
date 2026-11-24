import Foundation

public enum JournalTextPartitioner {
    /// Scalar boundaries preserve exact UTF-8, including emoji and arbitrarily long combining runs.
    public static func segments(_ text: String, maximumBytes: Int = 120_000) -> [String] {
        precondition(maximumBytes > 0)
        var result: [String] = [], part = "", count = 0
        for character in text.unicodeScalars {
            let bytes = String(character).utf8.count
            if count + bytes > maximumBytes && !part.isEmpty {
                let boundary = part.lastIndex(of: "\n") ?? part.lastIndex(where: \.isWhitespace)
                if let boundary, part[..<part.index(after: boundary)].utf8.count >= maximumBytes * 3 / 4 {
                    let cut = part.index(after: boundary)
                    result.append(String(part[..<cut])); part = String(part[cut...]); count = part.utf8.count
                } else { result.append(part); part = ""; count = 0 }
            }
            part.unicodeScalars.append(character); count += bytes
        }
        if !part.isEmpty { result.append(part) }
        return result
    }
}
