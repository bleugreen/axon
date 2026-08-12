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
