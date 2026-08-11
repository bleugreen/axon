import Foundation
import Testing
@testable import AxonCore

@Test func semanticNamesDeriveFromSerializedSnapshotDeterministically() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/semantic-names.json")
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixture))
    let first = SemanticNameDeriver.derive(from: json)
    let second = SemanticNameDeriver.derive(from: json)

    #expect(first == second)
    #expect(first.elements.first(where: { $0.sourceIndex == 3 })?.name == "menu/file/new-note")
    #expect(first.elements.first(where: { $0.sourceIndex == 6 })?.name == "notes/folders/add")
    #expect(first.elements.first(where: { $0.sourceIndex == 8 })?.name == "notes/editor/done-button")
    #expect(first.elements.first(where: { $0.sourceIndex == 9 })?.name == "notes/editor/done-text")
    #expect(first.elements.first(where: { $0.sourceIndex == 10 })?.name == "notes/editor/share")
    #expect(first.elements.first(where: { $0.sourceIndex == 11 })?.name == "notes/editor/share")
    #expect(first.elements.first(where: { $0.sourceIndex == 10 })?.candidateLabel == "notes/editor/share-1")
    #expect(first.elements.first(where: { $0.sourceIndex == 11 })?.candidateLabel == "notes/editor/share-2")
    #expect(first.groups.first(where: { $0.name == "notes/editor/share" }) == SemanticNameGroup(
        name: "notes/editor/share", sourceIndices: [10, 11], resolution: .ambiguous
    ))
    #expect(first.summary.collisionFreeCount == first.summary.eligibleElementCount - 2)
}

@Test func deepAncestryIsBoundedAndUsesAtMostOneResolvingAncestor() throws {
    let raw = #"{"windows":[{"role":"window","title":"Main","children":[{"role":"group","title":"Left","children":[{"role":"group","title":"Deep","children":[{"role":"group","title":"Card","children":[{"index":10,"role":"button","title":"Open"}]}]}]},{"role":"group","title":"Right","children":[{"role":"group","title":"Deep","children":[{"role":"group","title":"Card","children":[{"index":20,"role":"button","title":"Open"}]}]}]}]}]}"#
    let result = SemanticNameDeriver.derive(from: try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)))

    #expect(result.elements.first(where: { $0.sourceIndex == 10 })?.name == "left/deep/card/open")
    #expect(result.elements.first(where: { $0.sourceIndex == 20 })?.name == "right/deep/card/open")
    #expect(result.elements.allSatisfy { $0.segmentCount <= 4 })
}

@Test func identicalSiblingsKeepOneAmbiguousActionName() throws {
    let raw = #"{"windows":[{"role":"window","title":"Main","children":[{"index":1,"role":"button","title":"Save"},{"index":2,"role":"button","title":"Save"}]}]}"#
    let result = SemanticNameDeriver.derive(from: try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)))
    let saves = result.elements.filter { $0.label == "Save" }

    #expect(Set(saves.map(\.name)) == ["main/save"])
    #expect(saves.allSatisfy { $0.resolution == .ambiguous })
    #expect(Set(saves.compactMap(\.candidateLabel)) == ["main/save-1", "main/save-2"])
}

@Test func qualifierDisambiguationReservesVisibleNameNamespace() throws {
    let raw = #"{"windows":[{"role":"window","title":"Main","children":[{"role":"button","title":"Done","identifier":"button"},{"role":"button","title":"Done"},{"role":"button","title":"Done button"}]}]}"#
    let result = SemanticNameDeriver.derive(from: try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)))

    #expect(Set(result.elements.map(\.name)) == ["main", "main/done", "main/done-button-id", "main/done-button"])
}

@Test func rolesFromUIAAndATSPIUseNormalizedObservationVocabulary() throws {
    let raw = #"{"windows":[{"role":"window","title":"Main","children":[{"index":1,"role":"ControlType.Button","title":"Run"},{"index":2,"role":"push button","title":"Run"}]}]}"#
    let result = SemanticNameDeriver.derive(from: try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)))
    let run = result.elements.filter { $0.label == "Run" }

    #expect(run.map(\.role) == ["button", "button"])
    #expect(run.allSatisfy { $0.name == "main/run" && $0.resolution == .ambiguous })
}

@Test func stableIdentifiersDisambiguateReorderedEqualLabelSiblings() throws {
    func snapshot(ids: [String]) throws -> JSONValue {
        let children = ids.map { #"{"role":"AXButton","title":"Share","identifier":"\#($0)"}"# }.joined(separator: ",")
        let raw = #"{"windows":[{"role":"AXWindow","title":"Main","children":[\#(children)]}]}"#
        return try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    let first = SemanticNameDeriver.derive(from: try snapshot(ids: ["share-primary", "share-secondary"]))
    let reordered = SemanticNameDeriver.derive(from: try snapshot(ids: ["share-secondary", "share-primary"]))
    let result = SemanticNameDeriver.stability(from: first, to: reordered)

    #expect(Set(first.elements.map(\.name)) == ["main", "main/share-share-primary", "main/share-share-secondary"])
    #expect(first.summary.collisionFreeCount == 3)
    #expect(result.comparableElements == 3)
    #expect(result.stableNames == 3)
}

@Test func semanticNamesRejectFrameworkIdentifiersAndBoundSlugs() {
    #expect(SemanticNameDeriver.isAutogeneratedIdentifier("_NS:341"))
    #expect(!SemanticNameDeriver.isAutogeneratedIdentifier("compose-button"))
    #expect(SemanticNameDeriver.slug("Résumé / Open…") == "resume-open")
    #expect(SemanticNameDeriver.slug("A very long human readable title", maximumLength: 12) == "a-very-long")
}

@Test func semanticNameStabilityIgnoresGeometryAndSnapshotHandles() throws {
    func snapshot(id: String, x: Int) throws -> JSONValue {
        let raw = #"{"id":"\#(id)","windows":[{"index":\#(x),"handle":"\#(id):0","role":"AXWindow","title":"Main","frame":{"x":\#(x)},"children":[{"index":\#(x + 1),"handle":"\#(id):1","role":"AXButton","title":"Save"}]}]}"#
        return try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }
    let first = SemanticNameDeriver.derive(from: try snapshot(id: "s1", x: 0))
    let moved = SemanticNameDeriver.derive(from: try snapshot(id: "s2", x: 400))
    let result = SemanticNameDeriver.stability(from: first, to: moved)

    #expect(result.comparableElements == 2)
    #expect(result.stableNames == 2)
    #expect(result.fraction == 1)
}

@Test func oneStableIdentifierDisambiguatesMixedCoverageAcrossReorder() throws {
    func snapshot(identifiedFirst: Bool) throws -> JSONValue {
        let identified = #"{"role":"AXButton","title":"Share","identifier":"share-primary"}"#
        let anonymous = #"{"role":"AXButton","title":"Share"}"#
        let visibleCollision = #"{"role":"AXButton","title":"Share share primary"}"#
        let children = identifiedFirst
            ? "\(identified),\(anonymous),\(visibleCollision)"
            : "\(visibleCollision),\(anonymous),\(identified)"
        let raw = #"{"windows":[{"role":"AXWindow","title":"Main","children":[\#(children)]}]}"#
        return try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }
    let first = SemanticNameDeriver.derive(from: try snapshot(identifiedFirst: true))
    let reordered = SemanticNameDeriver.derive(from: try snapshot(identifiedFirst: false))
    let result = SemanticNameDeriver.stability(from: first, to: reordered)

    #expect(Set(first.elements.map(\.name)) == [
        "main", "main/share", "main/share-share-primary-id", "main/share-share-primary"
    ])
    #expect(first.summary.collisionFreeCount == 4)
    #expect(result.comparableElements == 4)
    #expect(result.stableNames == 4)
}

@Test func roleDisambiguationPreservesExistingVisibleNameAcrossReorder() throws {
    func snapshot(semanticPairFirst: Bool) throws -> JSONValue {
        let button = #"{"role":"AXButton","title":"Done"}"#
        let text = #"{"role":"AXStaticText","title":"Done"}"#
        let visibleCollision = #"{"role":"AXButton","title":"Done button"}"#
        let children = semanticPairFirst
            ? "\(button),\(text),\(visibleCollision)"
            : "\(visibleCollision),\(text),\(button)"
        let raw = #"{"windows":[{"role":"AXWindow","title":"Main","children":[\#(children)]}]}"#
        return try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }
    let first = SemanticNameDeriver.derive(from: try snapshot(semanticPairFirst: true))
    let reordered = SemanticNameDeriver.derive(from: try snapshot(semanticPairFirst: false))
    let result = SemanticNameDeriver.stability(from: first, to: reordered)

    #expect(Set(first.elements.map(\.name)) == [
        "main", "main/done-button-role", "main/done-text", "main/done-button"
    ])
    #expect(first.summary.collisionFreeCount == 4)
    #expect(result.comparableElements == 4)
    #expect(result.stableNames == 4)
}