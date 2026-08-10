import AxonCore
import Foundation

private struct Output: Codable {
    let captures: [String: SemanticNameStudy]
    let comparisons: [String: SemanticNameStability]
}

do {
    let paths = Array(CommandLine.arguments.dropFirst())
    guard !paths.isEmpty else {
        throw StudyError.usage("usage: swift run SemanticNameStudy SNAPSHOT.json [SNAPSHOT.json ...]")
    }
    var captures: [String: SemanticNameStudy] = [:]
    for path in paths {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        captures[path] = SemanticNameDeriver.derive(from: try JSONDecoder().decode(JSONValue.self, from: data))
    }
    var comparisons: [String: SemanticNameStability] = [:]
    for (first, second) in zip(paths, paths.dropFirst()) {
        comparisons["\(first) -> \(second)"] = SemanticNameDeriver.stability(from: captures[first]!, to: captures[second]!)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(Output(captures: captures, comparisons: comparisons)), as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("semantic-name-study: \(error)\n".utf8))
    exit(2)
}

private enum StudyError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self { case let .usage(message): message }
    }
}