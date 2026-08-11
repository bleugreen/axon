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

@Test func semanticRegistryInvalidatesPreviousProcessOnRelaunch() throws {
    let registry = SemanticNameRegistry(maxSnapshots: 4)
    let old = registry.register(snapshot: registrySnapshot(id: "old", pid: 10, buttonTitle: "Submit"))
    let oldName = try #require(old.first { $0.label == "Submit" }).query.name
    registry.register(snapshot: registrySnapshot(id: "new", pid: 11, buttonTitle: "Cancel"))
    guard case .missing = registry.lookup(app: "Registry", name: oldName) else {
        Issue.record("old process semantic records survived relaunch")
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