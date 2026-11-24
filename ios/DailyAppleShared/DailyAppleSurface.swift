import Foundation

enum DailyAppleSurface {
    static let group = "group.com.okayrulez.daily"
    static let newNote = URL(string: "dailyx://new-note")!

    static func reflection(date: String) -> URL {
        var url = URLComponents()
        url.scheme = "dailyx"
        url.host = "reflection"
        url.queryItems = [.init(name: "date", value: date)]
        return url.url!
    }

}

struct DailyWidgetSnapshot: Codable, Equatable, Sendable {
    let date: String
    let preview: String

    init(date: String, reflection: String) {
        self.date = date
        let line = reflection.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let prefix = line.prefix(180)
        self.preview = prefix.endIndex == line.endIndex ? String(prefix) : String(prefix) + "…"
    }

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DailyAppleSurface.group)?
            .appendingPathComponent("journal-widget.json")
    }

    static func read() -> Self? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    @discardableResult
    static func publish(_ snapshot: Self?) -> Bool {
        guard let file else { return false }
        if let snapshot, read() == snapshot { return false }
        if snapshot == nil, !FileManager.default.fileExists(atPath: file.path) { return false }
        do {
            if let snapshot {
                try JSONEncoder().encode(snapshot).write(to: file, options: [.atomic, .completeFileProtection])
            } else if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            return true
        } catch {
            return false
        }
    }
}
