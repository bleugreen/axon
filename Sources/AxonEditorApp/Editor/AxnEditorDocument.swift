import AxonCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let axnFile = UTType(exportedAs: "com.bleugreen.axon.axn", conformingTo: .yaml)
}

struct AxnEditorDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.axnFile, UTType(filenameExtension: "axn") ?? .yaml] }
    static var writableContentTypes: [UTType] { [.axnFile] }

    var axn: Axn

    init(axn: Axn = Axn()) {
        self.axn = axn
        self.axn.assignMissingBlockIDs()
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let source = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        axn = try Axn(source: source)
        axn.assignMissingBlockIDs()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let source = try axn.yamlString()
        guard let data = source.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}
