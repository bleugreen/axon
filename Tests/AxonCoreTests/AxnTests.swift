import Foundation
import Testing
@testable import AxonCore

@Test func axnFileParsesEditorMetadataAndBlocks() throws {
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

    let axn = try Axn(source: source)

    #expect(axn.version == 1)
    #expect(axn.editorMetadata.breakpoints == ["a001"])
    #expect(axn.editorMetadata.notes == ["a001": "auth fails here"])
    #expect(axn.args.map(\.name) == ["recipient"])
    #expect(axn.blocks.count == 2)

    guard case let .note(note) = axn.blocks[0] else {
        Issue.record("first block should be a note")
        return
    }
    #expect(note.id == "intro")
    #expect(note.text == "Sign in first")

    guard case let .action(action) = axn.blocks[1] else {
        Issue.record("second block should be an action")
        return
    }
    #expect(action.id == "a001")
    #expect(action.tool == "type")
    #expect(action.fields["custom"]?["nested"] == .bool(true))
}

@Test func axnFileAssignsStableIDsToMissingBlocks() throws {
    var axn = try Axn(source: """
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

    axn.assignMissingBlockIDs(prefix: "x")

    #expect(axn.blocks.map(\.id) == ["x001", "x002", "existing"])
}

@Test func axnFileRoundTripsMetadataNotesAndUnknownFields() throws {
    var axn = try Axn(source: """
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
    axn.assignMissingBlockIDs(prefix: "b")

    let rendered = try axn.yamlString()
    let reparsed = try Axn(source: rendered)

    #expect(rendered.hasPrefix("# axon-editor:"))
    #expect(reparsed.editorMetadata.breakpoints == ["a001"])
    #expect(reparsed.editorMetadata.notes == ["a001": "auth fails here"])
    #expect(reparsed.editorMetadata.unknownFields["panel"] == .string("expanded"))
    #expect(reparsed.unknownTopLevelFields["owner"] == .string("local-test"))
    #expect(reparsed.blocks == axn.blocks)
}

@Test func axnFileSerializationUsesCanonicalDocumentOrder() throws {
    let axn = try Axn(source: """
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

    let rendered = try axn.yamlString(includeEditorMetadata: false)

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
        Issue.record("rendered axn file is missing expected fields:\n\(rendered)")
        return
    }

    #expect(version < args)
    #expect(args < actions)
    #expect(actions < owner)
    #expect(argName < argType)
    #expect(actionID < actionTool)
    #expect(actionTool < actionTarget)
    #expect(actionTarget < actionValue)

    let batch = try AxnRunner.parseSource(rendered)
    #expect(batch == axn.jsonValue)
}

@Test func axnFileInsertsRecordedBlocksBeforeTargetAndRemapsDuplicateIDs() throws {
    var axn = try Axn(source: """
    version: 1
    actions:
      - id: a001
        tool: click
        target: existing
      - id: a002
        tool: click
        target: after
    """)
    let recording = try Axn(source: """
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

    axn.insertRecordedBlocks(recording.blocks, beforeBlockID: "a002")

    #expect(axn.blocks.map(\.id) == ["a001", "a003", "a004", "a002"])
    guard case let .action(typeAction) = axn.blocks[1],
          case let .array(expects)? = typeAction.fields["expects"],
          case let .object(fact)? = expects.first,
          case let .action(keyboardAction) = axn.blocks[2]
    else {
        Issue.record("inserted actions should keep expected shape")
        return
    }
    #expect(fact["id"] == .string("a003.value.0"))
    #expect(keyboardAction.fields["requires"] == .array([.string("a003.value.0")]))
}
