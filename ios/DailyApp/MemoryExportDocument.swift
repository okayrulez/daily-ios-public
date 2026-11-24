import SwiftUI
import UniformTypeIdentifiers

struct MemoryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(json: String) { data=Data(json.utf8) }
    init(configuration: ReadConfiguration) throws {
        guard let data=configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data=data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}
