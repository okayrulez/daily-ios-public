import Foundation

/// Logical journal records are independent of Firestore's per-document size limit.
/// Content-addressed parts and a small, atomic manifest preserve exact UTF-8 and CAS identity.
public struct WorkspaceRecordStorage: Sendable {
    public let fields: JSONValue
    public let chunks: [WorkspaceRecord]
    public static let format = "dailyx-journal-chunks-v1"
    public static let prefix = "note:dailyx/chunks/journal/"

    public init(_ record: WorkspaceRecord) throws {
        let bytes = Data(record.content.utf8)
        guard record.kind == .journal && bytes.count > 650_000 else { fields = record.json; chunks = []; return }
        var parts: [WorkspaceRecord] = []
        for offset in stride(from: 0, to: bytes.count, by: 300_000) {
            let payload = bytes.subdata(in: offset..<min(offset + 300_000, bytes.count)).base64EncodedString()
            let digest = WorkspaceHash.sha256(payload)
            parts.append(try WorkspaceRecord.make(key: Self.prefix + digest, kind: .note, payload: .string(payload)))
        }
        let manifest = try JSONValue.object(["format": .string(Self.format), "logicalHash": .string(record.hash),
            "bytes": .number(Double(bytes.count)), "chunks": .array(parts.map {
                .object(["key": .string($0.key), "hash": .string($0.hash)])
            })]).canonical()
        var root = record.json.object!
        // Keep the logical hash on the root so existing version/CAS security rules still apply.
        root["content"] = .string(manifest)
        fields = .object(root); chunks = parts
    }

    public static func references(_ fields: JSONValue) throws -> [String]? {
        guard let root = fields.object, root["kind"] == .string("journal"), let content = root["content"]?.string,
              let value = try JSONValue.parse(content).object, value["format"] == .string(format) else { return nil }
        guard content.utf8.count <= 700_000, root["hash"] == value["logicalHash"],
              let hash = value["logicalHash"]?.string, WorkspaceHash.valid(hash),
              let count = value["bytes"]?.integer, count > 650_000, count < Int.max - 300_000,
              let refs = value["chunks"]?.array, !refs.isEmpty,
              refs.count == (count + 299_999) / 300_000 else { throw WorkspaceError.malformedRecord }
        return try refs.map { ref in
            guard let key = ref.object?["key"]?.string, key.hasPrefix(prefix),
                  let hash = ref.object?["hash"]?.string, WorkspaceHash.valid(hash) else { throw WorkspaceError.malformedRecord }
            return key
        }
    }

    public static func decode(_ fields: JSONValue, resolve: (String) throws -> WorkspaceRecord) throws -> WorkspaceRecord {
        guard let keys = try references(fields) else { return try WorkspaceRecord(json: fields) }
        let manifest = try JSONValue.parse(fields.object!["content"]!.string!).object!
        let refs = manifest["chunks"]!.array!
        var bytes = Data()
        for (key, ref) in zip(keys, refs) {
            let chunk = try resolve(key)
            guard chunk.key == key, chunk.hash == ref.object?["hash"]?.string,
                  let data = try chunk.payload().string.flatMap({ Data(base64Encoded: $0) }), data.count <= 300_000 else {
                throw WorkspaceError.invalidHash
            }
            bytes.append(data)
            guard bytes.count <= manifest["bytes"]!.integer! else { throw WorkspaceError.invalidHash }
        }
        guard bytes.count == manifest["bytes"]!.integer!, let content = String(data: bytes, encoding: .utf8),
              WorkspaceHash.sha256(content) == manifest["logicalHash"]?.string else { throw WorkspaceError.invalidHash }
        var root = fields.object!
        root["content"] = .string(content); root["hash"] = manifest["logicalHash"]
        return try WorkspaceRecord(json: .object(root))
    }
}
