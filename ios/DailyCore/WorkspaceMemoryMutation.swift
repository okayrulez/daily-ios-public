import Foundation

/// Standalone memory changes use the same immutable-chunk/manifest boundary as an analysis commit.
public struct WorkspaceMemoryMutation: Sendable {
    public let memory: PortableMemory
    public let expectedManifest: WorkspaceRecord?
    public let manifest: WorkspaceRecord
    public let chunks: [WorkspaceRecord]
    public let records: [WorkspaceRecord]
    public let expectedRecords: [WorkspaceRecord]

    public init(before: PortableMemory, expectedManifest: WorkspaceRecord?, action: String,
                nodeID: String? = nil, text: String? = nil, verdict: String? = nil,
                prior: PortableMemory? = nil, additional: [WorkspaceRecord] = [], expectedRecords: [WorkspaceRecord] = [],
                now: String = CompanionCard.timestamp(Date())) throws {
        var args: [String:JSONValue] = ["memory":try JSONValue.parse(before.json),"action":.string(action),
            "id":.string(UUID().uuidString.lowercased()),"now":.string(now)]
        if let nodeID { args["nodeID"] = .string(nodeID) }
        if let text { args["text"] = .string(text) }
        if let verdict { args["verdict"] = .string(verdict) }
        if let prior { args["prior"] = try JSONValue.parse(prior.json) }
        let output = try AnalysisCore.invoke("editMemory", json: JSONValue.object(args).canonical())
        let (memory, displays) = try Self.decodeOutput(output)
        try self.init(memory: memory, expectedManifest: expectedManifest,
                      records: displays + additional, expectedRecords: expectedRecords)
    }

    public init(reviewing before: PortableMemory, expectedManifest: WorkspaceRecord, result: String?,
                changeReceipt: WorkspaceRecord? = nil) throws {
        guard expectedManifest.key == PhoneAnalysisCommit.manifestKey,
              let text = try expectedManifest.payload().string,
              let previous = try JSONValue.parse(text).object,
              previous["revision"]?.integer == before.revision,
              previous["memoryHash"]?.string == before.contentHash else { throw WorkspaceError.conflict }
        let args = try JSONValue.object(["memory": JSONValue.parse(before.json),
                                        "result": result.map(JSONValue.string) ?? .null]).canonical()
        let output = try AnalysisCore.invoke("applyMapReview", json: args)
        let (memory, displays) = try Self.decodeOutput(output)
        var records = displays
        var expectedRecords: [WorkspaceRecord] = []
        if let changeReceipt {
            let receipt = try WorkspaceChangeReceipt.decode(changeReceipt)
            guard receipt.undone != true, receipt.memoryHash == before.contentHash else { throw WorkspaceError.conflict }
            guard let text = try changeReceipt.payload().string,
                  var fields = try JSONValue.parse(text).object else { throw WorkspaceError.malformedRecord }
            // The review belongs to the same journal change and keeps its original undo target.
            fields["memoryHash"] = .string(memory.contentHash)
            let updated = try WorkspaceRecord.make(key: changeReceipt.key, kind: .note,
                payload: .string(JSONValue.object(fields).canonical()))
            records.append(updated)
            expectedRecords.append(changeReceipt)
        }
        try self.init(memory: memory, expectedManifest: expectedManifest,
                      records: records, expectedRecords: expectedRecords)
    }

    private static func decodeOutput(_ json: String) throws -> (PortableMemory, [WorkspaceRecord]) {
        guard let output = try JSONValue.parse(json).object,
              let rawMemory = output["memory"], let atlas = output["atlas"]?.array,
              let cards = output["cards"]?.array else { throw WorkspaceError.malformedRecord }
        let memory = try PortableMemory(json: rawMemory.canonical())
        let displays = try (atlas + cards).map { value -> WorkspaceRecord in
            guard let row = value.object, let key = row["key"]?.string,
                  let content = row["content"]?.string else { throw WorkspaceError.malformedRecord }
            return try WorkspaceRecord.make(key: key, kind: .note, payload: JSONValue.parse(content))
        }
        return (memory, displays)
    }

    private init(memory: PortableMemory, expectedManifest: WorkspaceRecord?, records: [WorkspaceRecord],
                 expectedRecords: [WorkspaceRecord]) throws {
        self.memory = memory
        self.expectedManifest = expectedManifest
        self.expectedRecords = expectedRecords
        self.records = records
        let bytes=Data(memory.json.utf8)
        guard bytes.count <= 16_000_000 else { throw WorkspaceError.oversizedRecord }
        var chunks:[WorkspaceRecord]=[]
        for offset in stride(from:0,to:bytes.count,by:300_000) {
            let text=bytes.subdata(in:offset..<min(bytes.count,offset+300_000)).base64EncodedString()
            chunks.append(try WorkspaceRecord.make(key:"note:dailyx/chunks/"+WorkspaceHash.sha256(JSONValue.string(text).canonical()),kind:.note,payload:.string(text)))
        }
        self.chunks=chunks
        manifest=try WorkspaceRecord.make(key:PhoneAnalysisCommit.manifestKey,kind:.note,payload:.string(
            JSONValue.object(["schemaVersion":.number(1),"revision":.number(Double(memory.revision)),"storage":.string("cloud"),
                "memoryHash":.string(memory.contentHash),"chunks":.array(chunks.map { .object(["key":.string($0.key),"hash":.string($0.hash)]) })]).canonical()))
        guard records.count+3 <= 400, records.reduce(0,{$0+$1.content.utf8.count}) < 8_000_000,
              Set(records.map(\.key)).count == records.count else { throw WorkspaceError.oversizedRecord }
    }
}
