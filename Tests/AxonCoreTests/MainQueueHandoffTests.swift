import Foundation
import Testing
@testable import AxonCore

@Test func mainQueueHandoffRunsWorkAndReportsCompletion() {
    let queue = DispatchQueue(label: "handoff-free")
    var ran = false

    let completed = MainQueueHandoff.run(on: queue, timeout: 2) { ran = true }

    #expect(completed)
    #expect(ran)
}

@Test func mainQueueHandoffReturnsWhenTheTargetQueueIsBlocked() {
    // Stands in for the daemon's main thread parked in accept(): the queue never drains during
    // the call, which is what used to deadlock an action outright.
    let queue = DispatchQueue(label: "handoff-blocked")
    let release = DispatchSemaphore(value: 0)
    queue.async { release.wait() }
    defer { release.signal() }

    let started = Date()
    let completed = MainQueueHandoff.run(on: queue, timeout: 0.2) {}
    let waited = Date().timeIntervalSince(started)

    #expect(completed == false)
    // The point of the fix: bounded, not forever.
    #expect(waited < 1.0)
}

@Test func mainQueueHandoffStillRunsWorkAfterTheDeadlinePasses() {
    let queue = DispatchQueue(label: "handoff-late")
    let release = DispatchSemaphore(value: 0)
    let ran = DispatchSemaphore(value: 0)
    queue.async { release.wait() }

    let completed = MainQueueHandoff.run(on: queue, timeout: 0.1) { ran.signal() }
    #expect(completed == false)

    // Giving up on the wait must not cancel the work — the badge appears late, not never.
    release.signal()
    #expect(ran.wait(timeout: .now() + 2) == .success)
}
