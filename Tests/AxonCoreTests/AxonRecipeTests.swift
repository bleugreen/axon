import Foundation
import Testing
@testable import AxonCore

@Test func axonRecipeParsesEditorMetadataAndBlocks() throws {
    let source = """
    # axon-editor: {"breakpoints":["a001"],"notes":{"a001":"auth fails here"}}
    version: 1
    args:
      - name: recipient
        type: email
        description: Recipient address
    actions:
      - id: intro
        note: Sign in first
      - id: a001
        tool: type
        target: s1:2
        value: "{{recipient}}"
        custom:
          nested: true
    """

    let recipe = try AxonRecipe(source: source)

    #expect(recipe.version == 1)
    #expect(recipe.editorMetadata.breakpoints == ["a001"])
    #expect(recipe.editorMetadata.notes == ["a001": "auth fails here"])
    #expect(recipe.args.map(\.name) == ["recipient"])
    #expect(recipe.blocks.count == 2)

    guard case let .note(note) = recipe.blocks[0] else {
        Issue.record("first block should be a note")
        return
    }
    #expect(note.id == "intro")
    #expect(note.text == "Sign in first")

    guard case let .action(action) = recipe.blocks[1] else {
        Issue.record("second block should be an action")
        return
    }
    #expect(action.id == "a001")
    #expect(action.tool == "type")
    #expect(action.fields["custom"]?["nested"] == .bool(true))
}

@Test func axonRecipeAssignsStableIDsToMissingBlocks() throws {
    var recipe = try AxonRecipe(source: """
    version: 1
    actions:
      - note: Explain the setup
      - tool: click
        target: s1:2
      - id: existing
        tool: keyboard
        app: Safari
        keys: Return
    """)

    recipe.assignMissingBlockIDs(prefix: "x")

    #expect(recipe.blocks.map(\.id) == ["x001", "x002", "existing"])
}

@Test func axonRecipeRoundTripsMetadataNotesAndUnknownFields() throws {
    var recipe = try AxonRecipe(source: """
    # axon-editor: { breakpoints: [a001], notes: { a001: "auth fails here" }, panel: expanded }
    version: 1
    owner: local-test
    actions:
      - id: n001
        note: Prepare account state
      - id: a001
        tool: type
        target: s1:2
        value: Hello
        extra:
          survives: true
    """)
    recipe.assignMissingBlockIDs(prefix: "b")

    let rendered = try recipe.yamlString()
    let reparsed = try AxonRecipe(source: rendered)

    #expect(rendered.hasPrefix("# axon-editor:"))
    #expect(reparsed.editorMetadata.breakpoints == ["a001"])
    #expect(reparsed.editorMetadata.notes == ["a001": "auth fails here"])
    #expect(reparsed.editorMetadata.unknownFields["panel"] == .string("expanded"))
    #expect(reparsed.unknownTopLevelFields["owner"] == .string("local-test"))
    #expect(reparsed.blocks == recipe.blocks)
}

@Test func axonRecipeSerializationUsesCanonicalDocumentOrder() throws {
    let recipe = try AxonRecipe(source: """
    owner: local-test
    actions:
      - value: Hello
        target: s1:2
        tool: type
        id: a001
    args:
      - default: Mitch
        type: string
        name: recipient
    version: 1
    """)

    let rendered = try recipe.yamlString(includeEditorMetadata: false)

    guard let version = rendered.range(of: "version: 1")?.lowerBound,
          let args = rendered.range(of: "args:")?.lowerBound,
          let actions = rendered.range(of: "actions:")?.lowerBound,
          let owner = rendered.range(of: "owner: local-test")?.lowerBound,
          let argName = rendered.range(of: "- name: recipient")?.lowerBound,
          let argType = rendered.range(of: "  type: string")?.lowerBound,
          let actionID = rendered.range(of: "- id: a001")?.lowerBound,
          let actionTool = rendered.range(of: "  tool: type")?.lowerBound,
          let actionTarget = rendered.range(of: "  target:")?.lowerBound,
          let actionValue = rendered.range(of: "  value: Hello")?.lowerBound
    else {
        Issue.record("rendered recipe is missing expected fields:\n\(rendered)")
        return
    }

    #expect(version < args)
    #expect(args < actions)
    #expect(actions < owner)
    #expect(argName < argType)
    #expect(actionID < actionTool)
    #expect(actionTool < actionTarget)
    #expect(actionTarget < actionValue)

    let batch = try ActionBatchExecutor.parseSource(rendered)
    #expect(batch == recipe.jsonValue)
}

@Test func axonRecipeInsertsRecordedBlocksBeforeTargetAndRemapsDuplicateIDs() throws {
    var recipe = try AxonRecipe(source: """
    version: 1
    actions:
      - id: a001
        tool: click
        target: existing
      - id: a002
        tool: click
        target: after
    """)
    let recording = try AxonRecipe(source: """
    version: 1
    actions:
      - id: a001
        tool: type
        target: inserted
        value: Ada
        expects:
          - id: a001.value.0
            kind: value
            target:
              app: Example
            state:
              value:
                equals: Ada
      - id: a002
        tool: keyboard
        app: Example
        keys: Return
        requires:
          - a001.value.0
    """)

    recipe.insertRecordedBlocks(recording.blocks, beforeBlockID: "a002")

    #expect(recipe.blocks.map(\.id) == ["a001", "a003", "a004", "a002"])
    guard case let .action(typeAction) = recipe.blocks[1],
          case let .array(expects)? = typeAction.fields["expects"],
          case let .object(fact)? = expects.first,
          case let .action(keyboardAction) = recipe.blocks[2]
    else {
        Issue.record("inserted actions should keep expected shape")
        return
    }
    #expect(fact["id"] == .string("a003.value.0"))
    #expect(keyboardAction.fields["requires"] == .array([.string("a003.value.0")]))
}
