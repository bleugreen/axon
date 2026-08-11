import Foundation
import Testing
@testable import AxonCore

private struct SharedLocatorFixture: Decodable {
    let snapshot: SharedSnapshot
    let cases: [SharedLocatorCase]
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
