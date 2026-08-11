import Foundation
import Testing
@testable import AxonCore

@Test func axnV2RoundTripPreservesUnknownTargetMetadata() throws {
    let source = """
    version: 2
    owner: local-test
    actions:
      - id: a001
        tool: click
        target:
          app: Example
          name: toolbar/save
          locator:
            role: AXButton
            title: Save
          vendorHint:
            generation: 7
        extensionField: retained
    """

    let reparsed = try Axn(source: Axn(source: source).yamlString(includeEditorMetadata: false))
    #expect(reparsed.version == 2)
    #expect(reparsed.unknownTopLevelFields["owner"] == .string("local-test"))
    #expect(reparsed.blocks[0].jsonValue["target"]?["vendorHint"]?["generation"] == .int(7))
    #expect(reparsed.blocks[0].jsonValue["extensionField"] == .string("retained"))
}

@Test func axnFileParsesEditorMetadataAndBlocks() throws {
    let source = """
    # axon-editor: {"breakpoints":["a001"],"notes":{"a001":"auth fails here"}}
    version: 2
    args:
      - name: recipient
        type: email
        description: Recipient address
    actions:
      - id: intro
        note: Sign in first
      - id: a001
        tool: type
        target: { app: Example, name: fixture/s1-2, locator: { role: AXButton, title: Fixture } }
        value: "{{recipient}}"
        custom:
          nested: true
    """

    let axn = try Axn(source: source)

    #expect(axn.version == 2)
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
    version: 2
    actions:
      - note: Explain the setup
      - tool: click
        target: { app: Example, name: fixture/s1-2, locator: { role: AXButton, title: Fixture } }
      - id: existing
        tool: keyboard
        app: Safari
        key: Return
    """)

    axn.assignMissingBlockIDs(prefix: "x")

    #expect(axn.blocks.map(\.id) == ["x001", "x002", "existing"])
}

@Test func axnFileRoundTripsMetadataNotesAndUnknownFields() throws {
    var axn = try Axn(source: """
    # axon-editor: { breakpoints: [a001], notes: { a001: "auth fails here" }, panel: expanded }
    version: 2
    owner: local-test
    actions:
      - id: n001
        note: Prepare account state
      - id: a001
        tool: type
        target: { app: Example, name: fixture/s1-2, locator: { role: AXButton, title: Fixture } }
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

@Test func axnFileRoundTripsAdditiveLocatorScoringFields() throws {
    let axn = try Axn(source: """
    version: 2
    actions:
      - id: a001
        tool: click
        target:
          app: Example
          name: fixture/deploy
          locator:
            role: AXButton
            title: Deploy
            window:
              title: Build
            nearbyText:
              - Billing
              - contains: Invoice
            frame:
              x: 10
              y: 20
              width: 100
              height: 30
    """)

    let rendered = try axn.yamlString(includeEditorMetadata: false)
    let reparsed = try Axn(source: rendered)

    #expect(reparsed.blocks == axn.blocks)
    guard case let .action(action) = reparsed.blocks.first else {
        Issue.record("expected action block")
        return
    }
    let locator = action.fields["target"]?["locator"]
    #expect(locator?["window"]?["title"] == .string("Build"))
    #expect(locator?["nearbyText"]?[0] == .string("Billing"))
    #expect(locator?["nearbyText"]?[1]?["contains"] == .string("Invoice"))
    #expect(locator?["frame"]?["x"] == .int(10))
}

@Test func axnFileSerializationUsesCanonicalDocumentOrder() throws {
    let axn = try Axn(source: """
    owner: local-test
    actions:
      - value: Hello
        target: { app: Example, name: fixture/s1-2, locator: { role: AXButton, title: Fixture } }
        tool: type
        id: a001
    args:
      - default: Mitch
        type: string
        name: recipient
    version: 2
    """)

    let rendered = try axn.yamlString(includeEditorMetadata: false)

    guard let version = rendered.range(of: "version: 2")?.lowerBound,
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

@Test func axnArgumentResolverUsesModelDeclarations() throws {
    let axn = try Axn(source: """
    version: 2
    args:
      - name: recipient
        type: email
      - name: retry_count
        type: number
        default: 2
      - name: upload_name
        type: path
        source: env://UPLOAD_NAME
    actions: []
    """)
    let resolver = AxnArgumentResolver(sourceResolvers: [
        "env": { source in
            #expect(axnEnvironmentName(from: source) == "UPLOAD_NAME")
            return "report.csv"
        }
    ])

    let resolved = try resolver.resolve(axn.args, callerArgValues: [
        "recipient": .string("ada@example.com")
    ])

    #expect(axn.args.map(\.argumentType) == [.email, .number, .path])
    #expect(resolved["recipient"]?.value == "ada@example.com")
    #expect(resolved["retry_count"]?.value == "2")
    #expect(resolved["upload_name"]?.value == "report.csv")
}

@Test func axnArgumentResolverRejectsInvalidModelDeclarations() throws {
    let axn = try Axn(source: """
    version: 2
    args:
      - name: api_token
        type: secret
        default: literal-secret
    actions: []
    """)

    do {
        _ = try AxnArgumentResolver(sourceResolvers: [:]).resolve(axn.args, callerArgValues: [:])
        Issue.record("secret defaults should be rejected by the model-level resolver")
    } catch let error as AxnRunError {
        #expect(error.description == "secret arg cannot have default: api_token")
    }
}

@Test func axnFileInsertsRecordedBlocksBeforeTargetAndRemapsDuplicateIDs() throws {
    var axn = try Axn(source: """
    version: 2
    actions:
      - id: a001
        tool: click
        target: { app: Example, name: fixture/existing, locator: { role: AXButton, title: Fixture } }
      - id: a002
        tool: click
        target: { app: Example, name: fixture/after, locator: { role: AXButton, title: Fixture } }
    """)
    let recording = try Axn(source: """
    version: 2
    actions:
      - id: a001
        tool: type
        target: { app: Example, name: fixture/inserted, locator: { role: AXButton, title: Fixture } }
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
        key: Return
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

@Test func axnHealingUpdatesLocatorWithoutRenamingSemanticTarget() throws {
    let axn = try Axn(source: """
    version: 2
    actions:
      - id: a001
        tool: click
        target:
          app: Example
          name: toolbar/save
          locator:
            role: AXButton
            title: Save
    """)
    let event = LocatorHealEvent(
        actionID: "a001",
        actionIndex: 0,
        status: .proposed,
        confidence: "high",
        path: "fullSnapshot",
        evidence: [],
        proposal: .object(["role": .string("AXButton"), "identifier": .string("save-button")]),
        diff: "locator changed",
        reason: nil
    )

    let revised = AxnHealing.revise(axn, with: [event])

    #expect(revised.blocks[0].jsonValue["target"]?["name"] == .string("toolbar/save"))
    #expect(revised.blocks[0].jsonValue["target"]?["locator"]?["identifier"] == .string("save-button"))
}
