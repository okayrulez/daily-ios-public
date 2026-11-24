import Foundation

public enum FirestoreDocumentCodec {
    public static func fields(_ value: JSONValue) throws -> JSONValue {
        guard let object = value.object else { throw WorkspaceError.malformedRecord }
        return .object(try object.mapValues(encode))
    }
    public static func decodeFields(_ value: JSONValue) throws -> JSONValue {
        guard let object = value.object else { throw WorkspaceError.malformedRecord }
        return .object(try object.mapValues(decode))
    }
    private static func encode(_ value: JSONValue) throws -> JSONValue {
        switch value {
        case .string(let text): .object(["stringValue": .string(text)])
        case .bool(let flag): .object(["booleanValue": .bool(flag)])
        case .null: .object(["nullValue": .null])
        case .number(let number): .object(["doubleValue": .number(number)])
        case .array(let values): .object(["arrayValue": .object(["values": .array(try values.map(encode))])])
        case .object: .object(["mapValue": .object(["fields": try fields(value)])])
        }
    }
    private static func decode(_ value: JSONValue) throws -> JSONValue {
        guard let row = value.object else { throw WorkspaceError.malformedRecord }
        if let text = row["stringValue"]?.string { return .string(text) }
        if let flag = row["booleanValue"], case .bool = flag { return flag }
        if row["nullValue"] != nil { return .null }
        if let text = row["integerValue"]?.string, let number = Double(text), number.isFinite { return .number(number) }
        if let number = row["doubleValue"]?.number { return .number(number) }
        if let timestamp = row["timestampValue"]?.string, let date = CompanionCard.date(timestamp) { return .number(date.timeIntervalSince1970) }
        if let map = row["mapValue"]?.object { return try decodeFields(map["fields"] ?? .object([:])) }
        if let array = row["arrayValue"]?.object { return .array(try (array["values"]?.array ?? []).map(decode)) }
        throw WorkspaceError.malformedRecord
    }
}
