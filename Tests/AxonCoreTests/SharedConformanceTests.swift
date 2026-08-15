import Foundation
import Testing
@testable import AxonCore

private struct SharedLookRequestControls: Decodable {
    struct Format: Decodable {
        let acceptedValues: [String]
    }
    let format: Format
    let nonnegative: [String]
}

@Test func sharedLookRequestControlsMatchGeneratedSchema() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../schema/fixtures/look-request-controls.json")
        .standardizedFileURL
    let fixture = try JSONDecoder().decode(SharedLookRequestControls.self, from: Data(contentsOf: fixtureURL))
    let look = try #require(ToolSurfaceSchema.mcpToolJSONValues().first { $0["name"] == .string("look") })
    let properties = try #require(look["inputSchema"]?["properties"])

    #expect(properties["format"]?["enum"] == .array(fixture.format.acceptedValues.map(JSONValue.string)))
    for name in fixture.nonnegative {
        #expect(properties[name]?["minimum"] == .int(0), Comment(rawValue: name))
    }
}

@Test func sharedLookApplicationsEnvelopeIsByteExact() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../schema/fixtures/look-applications-envelope.json")
        .standardizedFileURL
    let expected = try String(contentsOf: fixtureURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let response = CommandRouter(listApps: { [] }).handle(JSONRPCRequest(
        id: .string("apps"),
        method: "look"
    ))

    #expect(response.result.map(JSONValue.object)?.compactJSONString == expected)
}

@Test func sharedMCPObservationEnvelopeIsByteExact() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../schema/fixtures/mcp-look-observation-envelope.json")
        .standardizedFileURL
    let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixtureURL))
    let structuredContent = try #require(fixture["structuredContent"])
    let expected = try #require(fixture["result"])

    #expect(MCPContent.toolResult(structuredContent: structuredContent, isError: false) == expected.objectValue)
}

private struct SharedLocatorFixture: Decodable {
    let snapshot: SharedSnapshot
    let cases: [SharedLocatorCase]
}

private struct SharedLookScreenshotPolicy: Decodable {
    let defaultScreenshot: Bool
    let carveOuts: [String: Bool]
    let explicit: [String: Bool]
    let encoding: SharedScreenshotEncoding
}

private struct SharedScreenshotEncoding: Decodable {
    let maxDimension: Int
    let mediaType: String
    let quality: String
}

@Test func sharedLookScreenshotPolicyFixture() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../schema/fixtures/look-screenshot-policy.json")
        .standardizedFileURL
    let fixture = try JSONDecoder().decode(SharedLookScreenshotPolicy.self, from: Data(contentsOf: fixtureURL))

    #expect(fixture.defaultScreenshot)
    #expect(fixture.carveOuts == ["appList": false, "since": false, "childPage": false])
    #expect(fixture.explicit == ["true": true, "false": false])
    #expect(fixture.encoding.maxDimension == ScreenshotCapturer.defaultMaxEncodedDimension)
    #expect(fixture.encoding.mediaType == "image/png")
    #expect(fixture.encoding.quality == "lossless")
}

private struct SharedLookObservationNotes: Decodable {
    struct Case: Decodable {
        let name: String
        let windowCount: Int
        let note: String?
    }

    let noWindows: String
    let cases: [Case]
}

@Test func sharedLookObservationNotesFixture() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../schema/fixtures/look-observation-notes.json")
        .standardizedFileURL
    let fixture = try JSONDecoder().decode(SharedLookObservationNotes.self, from: Data(contentsOf: fixtureURL))
    #expect(fixture.noWindows == ObservationNote.noWindows)

    let formatter = SnapshotObservationFormatter()
    for testCase in fixture.cases {
        let snapshot = AppSnapshot(
            id: SnapshotID("obs"),
            app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 7),
            windows: (0..<testCase.windowCount).map { AXNode(role: "AXWindow", title: "Window \($0)") },
            screenshot: nil
        )
        let observation = formatter.observation(from: snapshot.jsonValue, frames: false)

        #expect(observation["note"]?.stringValue == testCase.note, Comment(rawValue: testCase.name))
    }
}

private struct SharedLocatorCase: Decodable {
    let name: String
    let locator: JSONValue
    let status: LocatorResolutionStatus
    let confidence: LocatorConfidence
    let bestIndex: Int?
}

private struct SharedSnapshot: Decodable {
    let id: String
    let app: SharedApplication

    var axSnapshot: AppSnapshot {
        AppSnapshot(
            id: SnapshotID(id),
            app: AppIdentity(bundleIdentifier: app.identifier, name: app.name, processIdentifier: 0),
            windows: app.windows.map { window in
                window.root.axNode(windowTitle: window.title)
            },
            screenshot: nil
        )
    }
}

private struct SharedApplication: Decodable {
    let name: String
    let identifier: String?
    let windows: [SharedWindow]
}

private struct SharedWindow: Decodable {
    let title: String?
    let root: SharedNode
}

private struct SharedNode: Decodable {
    let role: String
    let subrole: String?
    let title: String?
    let label: String?
    let value: String?
    let description: String?
    let identifier: String?
    let actions: [String]
    let frame: AXFrame?
    let editable: Bool
    let children: [SharedNode]

    private enum CodingKeys: String, CodingKey {
        case role, subrole, title, label, value, description, identifier, actions, frame, editable, children
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        role = try values.decode(String.self, forKey: .role)
        subrole = try values.decodeIfPresent(String.self, forKey: .subrole)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        label = try values.decodeIfPresent(String.self, forKey: .label)
        value = try values.decodeIfPresent(String.self, forKey: .value)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
        actions = try values.decodeIfPresent([String].self, forKey: .actions) ?? []
        frame = try values.decodeIfPresent(AXFrame.self, forKey: .frame)
        editable = try values.decodeIfPresent(Bool.self, forKey: .editable) ?? false
        children = try values.decodeIfPresent([SharedNode].self, forKey: .children) ?? []
    }

    func axNode(windowTitle: String? = nil) -> AXNode {
        AXNode(
            role: role,
            subrole: subrole,
            title: title ?? windowTitle,
            label: label,
            value: value,
            description: description,
            identifier: identifier,
            frame: frame,
            actions: actions,
            editable: editable,
            children: children.map { $0.axNode() }
        )
    }
}

@Test func sharedLocatorConformanceFixtures() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../rust/axon-core/fixtures/locator-cases.json")
        .standardizedFileURL
    let fixture = try JSONDecoder().decode(SharedLocatorFixture.self, from: Data(contentsOf: fixtureURL))
    let resolver = LocatorResolver(platformNeutral: true)

    for testCase in fixture.cases {
        let locator = try AXLocator(jsonValue: testCase.locator)
        let result = resolver.resolve(locator, in: fixture.snapshot.axSnapshot)

        #expect(result.status == testCase.status, Comment(rawValue: "\(testCase.name): status"))
        #expect(result.confidence == testCase.confidence, Comment(rawValue: "\(testCase.name): confidence"))
        #expect(result.best?.index == testCase.bestIndex, Comment(rawValue: "\(testCase.name): best index"))
        #expect(
            result.candidates.allSatisfy { !$0.reasons.isEmpty },
            Comment(rawValue: "\(testCase.name): candidate explanations")
        )
    }
}


private struct SharedSemanticFixture: Decodable {
    let snapshot: SharedSnapshot
    let expected: [ExpectedSemanticName]
}
private struct ExpectedSemanticName: Decodable {
    let sourceIndex: Int
    let name: String
    let resolution: SemanticNameResolution
    let candidateLabel: String?
}

@Test func sharedSemanticNameConformanceFixtures() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../schema/fixtures/semantic-names.json")
        .standardizedFileURL
    let fixture = try JSONDecoder().decode(SharedSemanticFixture.self, from: Data(contentsOf: fixtureURL))
    let actual = SemanticNameDeriver.derive(from: fixture.snapshot.axSnapshot.jsonValue(includeTree: true))
    for expected in fixture.expected {
        let element = try #require(actual.elements.first { $0.sourceIndex == expected.sourceIndex })
        #expect(element.name == expected.name)
        #expect(element.resolution == expected.resolution)
        #expect(element.candidateLabel == expected.candidateLabel)
    }
}
