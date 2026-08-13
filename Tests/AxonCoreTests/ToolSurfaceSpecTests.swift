import Foundation
import Testing
@testable import AxonCore

@Test func toolSurfaceGeneratesMCPToolSchemasFromSpec() throws {
    let tools = ToolSurfaceSchema.mcpToolJSONValues()

    #expect(toolNames(in: tools) == ToolSurfaceSpec.toolNames)
    #expect(tool(named: "click", in: tools)?["inputSchema"]?["properties"]?["target"]?["anyOf"]?[0]?["type"] == .string("object"))
    #expect(tool(named: "click", in: tools)?["inputSchema"]?["properties"]?["target"]?["anyOf"]?[2] != nil)
    #expect(tool(named: "invoke", in: tools)?["inputSchema"]?["properties"]?["target"]?["anyOf"]?[0] != nil)
    #expect(tool(named: "invoke", in: tools)?["inputSchema"]?["properties"]?["target"]?["anyOf"]?[1] == nil)
    #expect(tool(named: "type", in: tools)?["inputSchema"]?["required"] == .array([.string("target"), .string("value")]))
    #expect(tool(named: "wait_for_stability", in: tools)?["inputSchema"]?["properties"]?["stableMs"]?["type"] == .string("integer"))
    #expect(tool(named: "wait_for_stability", in: tools)?["inputSchema"]?["properties"]?["timeoutMs"]?["type"] == .string("integer"))
    #expect(tool(named: "wait_for_stability", in: tools)?["inputSchema"]?["properties"]?["intervalMs"]?["type"] == .string("integer"))
    #expect(tool(named: "keyboard", in: tools)?["inputSchema"]?["properties"]?["keys"] == nil)
    #expect(tool(named: "keyboard", in: tools)?["inputSchema"]?["oneOf"]?[0]?["required"] == .array([.string("text")]))
    #expect(tool(named: "keyboard", in: tools)?["inputSchema"]?["oneOf"]?[1]?["required"] == .array([.string("key")]))
    let look = ToolSurfaceSpec.tools.first { $0.name == "look" }
    #expect(look?.params.first { $0.name == "screenshot" }?.defaultValue == .bool(true))
    #expect(tool(named: "look", in: tools)?["inputSchema"]?["properties"]?["screenshot"]?["default"] == .bool(true))
    #expect(tool(named: "look", in: tools)?["inputSchema"]?["properties"]?["format"]?["enum"] == .array([
        .string("observation"), .string("debug")
    ]))
    for name in ["offset", "limit", "childDepth", "depth"] {
        #expect(tool(named: "look", in: tools)?["inputSchema"]?["properties"]?[name]?["minimum"] == .int(0))
    }
    #expect(tool(named: "keyboard", in: tools)?["inputSchema"]?["additionalProperties"] == .bool(false))
}

private func availableToolNames(for facade: ToolFacade) -> [String] {
    ToolSurfaceSpec.tools.filter { $0.availability.contains(facade) }.map(\.name)
}

@Test func toolSurfaceDeclaresExactNestedTargetSchemas() throws {
    let tools = ToolSurfaceSchema.mcpToolJSONValues()
    let clickTarget = tool(named: "click", in: tools)?["inputSchema"]?["properties"]?["target"]
    let semantic = clickTarget?["anyOf"]?[0]
    #expect(semantic?["properties"]?["app"]?["type"] == .string("string"))
    #expect(semantic?["properties"]?["name"]?["type"] == .string("string"))
    #expect(semantic?["required"] == .array([.string("app"), .string("name")]))
    #expect(semantic?["additionalProperties"] == .bool(false))

    let wrappedPoint = clickTarget?["anyOf"]?[1]
    #expect(wrappedPoint?["required"] == .array([.string("point")]))
    #expect(wrappedPoint?["properties"]?["point"]?["required"] == .array([.string("x"), .string("y")]))
    #expect(wrappedPoint?["properties"]?["point"]?["additionalProperties"] == .bool(false))

    let flatPoint = clickTarget?["anyOf"]?[2]
    #expect(flatPoint?["properties"]?["coordinateSpace"]?["enum"] == .array([
        .string("screen"), .string("window"), .string("screenshot")
    ]))
    #expect(flatPoint?["additionalProperties"] == .bool(false))
    #expect(flatPoint?["description"]?.stringValue.contains("logical macOS points") == true)
    #expect(flatPoint?["description"]?.stringValue.contains("encoded image") == true)
    #expect(flatPoint?["properties"]?["coordinateSpace"]?["description"]?.stringValue.contains("encoded-image pixels") == true)

    let textLocation = clickTarget?["anyOf"]?[3]?["properties"]?["location"]
    #expect(textLocation?["required"] == .array([.string("app"), .string("text")]))
    #expect(textLocation?["properties"]?["source"]?["default"] == .string("auto"))
    #expect(textLocation?["additionalProperties"] == .bool(false))
}

@Test func toolSurfaceDeclaresFacadeAvailability() throws {
    let all = ToolSurfaceSpec.tools
    #expect(all.allSatisfy { $0.availability.contains(.swift) })
    #expect(availableToolNames(for: .mac) == [
        "look", "find", "wait_for_value", "wait_for_stability", "run", "click", "type",
        "keyboard", "scroll", "invoke"
    ])
    #expect(availableToolNames(for: .windows) == [
        "look", "find", "run", "click", "type", "keyboard", "scroll", "invoke"
    ])
    #expect(availableToolNames(for: .linux) == [
        "look", "find", "run", "click", "type", "keyboard", "scroll", "invoke"
    ])
}

@Test func checkedInToolSurfaceArtifactMatchesGeneratedBytes() throws {
    let artifactURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("schema/tool-surface-v1.json")
    #expect(try Data(contentsOf: artifactURL) == ToolSurfaceSchema.normalizedArtifactData())
}

@Test func toolSurfaceDocsSignatureBlockMatchesSpec() throws {
    let docsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("docs/tool-surface.md")
    let docs = try String(contentsOf: docsURL, encoding: .utf8)

    #expect(docs.contains("```text\n\(ToolSurfaceSpec.mcpSignatureBlock)\n```"))
}

@Test func toolTargetParsesAllTargetKinds() throws {
    #expect(try ToolTarget(jsonValue: .object(["app": .string("Example"), "name": .string("main/submit")])) == .semanticName(app: "Example", name: "main/submit"))
    #expect(try ToolTarget(jsonValue: .object([
        "point": .object(["x": .int(25), "y": .double(40.5)])
    ])) == .point(ActionPoint(x: 25, y: 40.5)))
    #expect(try ToolTarget(jsonValue: .object([
        "x": .int(25),
        "y": .int(40)
    ])) == .point(ActionPoint(x: 25, y: 40)))

    let location = try ToolTarget(jsonValue: .object([
        "location": .object([
            "app": .string("Example"),
            "text": .string("Submit")
        ])
    ]))
    guard case let .textLocation(target) = location else {
        Issue.record("Expected text location target")
        return
    }
    #expect(target.app == "Example")
    #expect(target.source == .auto)

    #expect(throws: JSONRPCError.self) {
        try ToolTarget(jsonValue: .string("s12:4"))
    }
    #expect(throws: JSONRPCError.self) {
        try ToolTarget(jsonValue: .object([
            "app": .string("Example"),
            "locator": .object(["role": .string("AXButton")])
        ]))
    }
}

@Test func toolTargetRejectsKindsOutsideToolAcceptance() throws {
    #expect(throws: JSONRPCError.self) {
        try ToolTarget(jsonValue: .object(["x": .int(1), "y": .int(2)]), acceptedKinds: .element)
    }
    #expect(throws: JSONRPCError.self) {
        try ToolTarget(jsonValue: .object([
            "location": .object(["app": .string("Example"), "text": .string("Submit")])
        ]), acceptedKinds: .element)
    }
}

private func toolNames(in tools: [JSONValue]) -> [String] {
    tools.compactMap { tool in
        guard case let .string(name)? = tool["name"] else {
            return nil
        }
        return name
    }
}

private func tool(named name: String, in tools: [JSONValue]) -> JSONValue? {
    tools.first { tool in
        guard case let .string(toolName)? = tool["name"] else {
            return false
        }
        return toolName == name
    }
}
