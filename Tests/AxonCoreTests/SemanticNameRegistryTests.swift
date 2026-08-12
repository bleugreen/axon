import Foundation
import Testing
@testable import AxonCore

@Test func semanticRegistryRetainsLocatorEvidenceAndPrivateHandle() throws {
    let registry = SemanticNameRegistry(maxSnapshots: 2)
    let snapshot = registrySnapshot(id: "s1", pid: 10, buttonTitle: "Submit")
    let record = try #require(registry.register(snapshot: snapshot).first { $0.label == "Submit" })
    #expect(record.snapshotID == SnapshotID("s1"))
    #expect(record.retainedHandle?.rawValue == "s1:1")
    #expect(record.locator.role == "AXButton")
    #expect(record.locator.title?.matches("Submit") == true)
    guard case let .unique(found) = registry.lookup(app: "com.example.Registry", name: record.query.name) else {
        Issue.record("expected unique semantic record")
        return
    }
    #expect(found.sourceIndex == 1)
}

@Test func semanticRegistryPreservesAmbiguityAndBoundsSnapshots() throws {
    let registry = SemanticNameRegistry(maxSnapshots: 1)
    let ambiguous = registrySnapshot(id: "s1", pid: 10, buttonTitle: "Share", duplicate: true)
    let name = try #require(registry.register(snapshot: ambiguous).first { $0.label == "Share" }).query.name
    guard case let .ambiguous(_, candidates) = registry.lookup(app: "Registry", name: name) else {
        Issue.record("expected ambiguous semantic name")
        return
    }
    #expect(candidates.count == 2)

    registry.register(snapshot: registrySnapshot(id: "s2", pid: 10, buttonTitle: "Save"))
    guard case .missing = registry.lookup(app: "Registry", name: name) else {
        Issue.record("evicted snapshot remained addressable")
        return
    }
}

@Test func semanticRegistryAcceptsBareAndPrefixedPIDQueries() throws {
    let registry = SemanticNameRegistry(isProcessRunning: { $0 == 10 })
    let name = try #require(registry.register(snapshot: registrySnapshot(id: "pid", pid: 10, buttonTitle: "Submit")).first { $0.label == "Submit" }).query.name

    guard case let .unique(bare) = registry.lookup(app: "10", name: name),
          case let .unique(prefixed) = registry.lookup(app: "pid:10", name: name) else {
        Issue.record("expected both PID query forms to resolve")
        return
    }
    #expect(bare.appIdentity.processIdentifier == 10)
    #expect(prefixed.appIdentity.processIdentifier == 10)
}

@Test func semanticRegistryPreservesCoexistingProcessesAndInvalidatesOnlyDeadRelaunchEvidence() throws {
    final class Liveness: @unchecked Sendable { var running: Set<Int32> = [10, 20] }
    let liveness = Liveness()
    let registry = SemanticNameRegistry(maxSnapshots: 4, isProcessRunning: { liveness.running.contains($0) })
    let firstName = try #require(registry.register(snapshot: registrySnapshot(id: "first", pid: 10, buttonTitle: "Submit")).first { $0.label == "Submit" }).query.name
    let peerName = try #require(registry.register(snapshot: registrySnapshot(id: "peer", pid: 20, buttonTitle: "Share")).first { $0.label == "Share" }).query.name
    guard case .unique = registry.lookup(app: "10", name: firstName),
          case .unique = registry.lookup(app: "20", name: peerName) else {
        Issue.record("live same-identity processes did not coexist")
        return
    }

    liveness.running = [20, 11]
    let replacementName = try #require(registry.register(snapshot: registrySnapshot(id: "replacement", pid: 11, buttonTitle: "Cancel")).first { $0.label == "Cancel" }).query.name
    guard case .missing = registry.lookup(app: "10", name: firstName),
          case .unique = registry.lookup(app: "11", name: replacementName),
          case .unique = registry.lookup(app: "20", name: peerName) else {
        Issue.record("relaunch cleanup did not remove only the dead process")
        return
    }
}

@Test func semanticRegistryPageRegistrationUsesLiveLifecycleOrderingAndPruning() throws {
    final class Liveness: @unchecked Sendable { var running: Set<Int32> = [10, 20] }
    let liveness = Liveness()
    let registry = SemanticNameRegistry(maxSnapshots: 2, isProcessRunning: { liveness.running.contains($0) })
    let oldName = try #require(registry.register(snapshot: registrySnapshot(id: "old", pid: 10, buttonTitle: "Old")).first { $0.label == "Old" }).query.name
    let peerName = try #require(registry.register(snapshot: registrySnapshot(id: "peer", pid: 20, buttonTitle: "Peer")).first { $0.label == "Peer" }).query.name

    liveness.running = [11, 20]
    let page = AXChildrenPage(
        snapshotID: SnapshotID("replacement"), parentHandle: "replacement:0",
        offset: 0, limit: 1, total: 1, baseIndex: 1,
        children: [AXNode(role: "AXButton", title: "Paged", actions: ["AXPress"])]
    )
    let pageName = try #require(registry.register(page: page, app: AppIdentity(
        bundleIdentifier: "com.example.Registry", name: "Registry", processIdentifier: 11
    )).first { $0.label == "Paged" }).query.name
    guard case .missing = registry.lookup(app: "10", name: oldName),
          case .unique = registry.lookup(app: "20", name: peerName),
          case .unique = registry.lookup(app: "11", name: pageName) else {
        Issue.record("page registration bypassed live lifecycle")
        return
    }

    registry.register(snapshot: AppSnapshot(
        id: SnapshotID("other"),
        app: AppIdentity(bundleIdentifier: "com.example.Other", name: "Other", processIdentifier: 30),
        windows: [AXNode(role: "AXWindow", title: "Other", children: [AXNode(role: "AXButton", title: "Other")])],
        screenshot: nil
    ))
    guard case .missing = registry.lookup(app: "20", name: peerName),
          case .unique = registry.lookup(app: "11", name: pageName) else {
        Issue.record("page registration did not refresh ordering or participate in pruning")
        return
    }
}

private func registrySnapshot(id: String, pid: Int32, buttonTitle: String, duplicate: Bool = false) -> AppSnapshot {
    let buttons = (duplicate ? [buttonTitle, buttonTitle] : [buttonTitle]).map {
        AXNode(role: "AXButton", title: $0, actions: ["AXPress"])
    }
    return AppSnapshot(
        id: SnapshotID(id),
        app: AppIdentity(bundleIdentifier: "com.example.Registry", name: "Registry", processIdentifier: pid),
        windows: [AXNode(role: "AXWindow", title: "Main", children: buttons)],
        screenshot: nil
    )
}

@Test func normalSemanticObservationOmitsHandlesWhileDebugRetainsThem() throws {
    let snapshot = registrySnapshot(id: "s1", pid: 10, buttonTitle: "Submit")
    let study = SemanticNameDeriver.derive(from: snapshot.jsonValue)
    let normal = snapshot.jsonValue.renderingSemanticNames(study, includeDebugHandles: false)
    let debug = snapshot.jsonValue.renderingSemanticNames(study, includeDebugHandles: true)
    let normalText = String(data: try JSONEncoder().encode(normal), encoding: .utf8)!
    let debugText = String(data: try JSONEncoder().encode(debug), encoding: .utf8)!
    #expect(normalText.contains("\"name\""))
    #expect(!normalText.contains("\"handle\""))
    #expect(debugText.contains("\"handle\""))
}
