import AxonCore
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: tool-surface-exporter <output-path>\n".utf8))
    exit(2)
}
do {
    try ToolSurfaceSchema.normalizedArtifactData().write(
        to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic
    )
} catch {
    FileHandle.standardError.write(Data("tool-surface-exporter: \(error)\n".utf8))
    exit(1)
}
