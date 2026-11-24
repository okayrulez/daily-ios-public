import Foundation
import CryptoKit
import JavaScriptCore

public enum WorkspaceError: Error, Equatable, Sendable {
    case malformedRecord
    case invalidHash
    case invalidAddress
    case oversizedRecord
    case conflict
    case missingQuestion
    case invalidAccount
    case invalidDraft
}

/// Lossless field preservation for portable records, including future extension fields.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? box.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try box.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .null: try box.encodeNil()
        case .bool(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .string(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .object(let value): try box.encode(value)
        }
    }

    public var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    public var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var number: Double? { if case .number(let value) = self { return value }; return nil }
    public var integer: Int? {
        guard let value = number, value.isFinite, value.rounded() == value, abs(value) <= 9_007_199_254_740_991 else { return nil }
        return Int(value)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        do { return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        catch { throw WorkspaceError.malformedRecord }
    }

    /// PC canonicalJson sorts object keys by UTF-16 and uses ECMAScript number strings.
    /// The system JS engine converts numeric values only: no record text is executed.
    public func canonical() throws -> String {
        guard let context = JSContext() else { throw WorkspaceError.malformedRecord }
        return try canonical(context: context)
    }

    private func canonical(context: JSContext) throws -> String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            guard value.isFinite, let text = JSValue(double: value, in: context)?.toString() else { throw WorkspaceError.malformedRecord }
            return text
        case .string(let value): return Self.quote(value)
        case .array(let values): return "[" + (try values.map { try $0.canonical(context: context) }.joined(separator: ",")) + "]"
        case .object(let values):
            let keys = values.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return "{" + (try keys.map { key in
                Self.quote(key) + ":" + (try values[key]!.canonical(context: context))
            }.joined(separator: ",")) + "}"
        }
    }

    private static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x0c: result += "\\f"
            case 0x0a: result += "\\n"
            case 0x0d: result += "\\r"
            case 0x09: result += "\\t"
            case 0..<0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

public enum WorkspaceHash {
    public static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func valid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public enum WorkspaceIdentity {
    public static func validateUID(_ uid: String) throws {
        guard (1...128).contains(uid.utf8.count), uid.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { throw WorkspaceError.invalidAccount }
    }

    public static func validDate(_ value: String) -> Bool {
        guard value.utf8.count == 10 else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    public static func recordsPath(uid: String) throws -> String {
        try validateUID(uid)
        return "users/\(uid)/dailyXRecords"
    }
}
