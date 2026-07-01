import AxonCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let axnFile = UTType(exportedAs: "com.bleugreen.axon.recipe", conformingTo: .yaml)
}

struct AxnEditorDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.axnFile, UTType(filenameExtension: "axn") ?? .yaml] }
    static var writableContentTypes: [UTType] { [.axnFile] }

    var recipe: Axn

    init(recipe: Axn = Axn()) {
        self.recipe = recipe
        self.recipe.assignMissingBlockIDs()
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let source = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        recipe = try Axn(source: source)
        recipe.assignMissingBlockIDs()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let source = try recipe.yamlString()
        guard let data = source.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}
