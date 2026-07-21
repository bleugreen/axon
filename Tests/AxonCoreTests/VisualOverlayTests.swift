import Foundation
import Testing
@testable import AxonCore

@Test func visualOverlayConfigurationDefaultsEnabled() {
    let configuration = VisualOverlayConfiguration.fromEnvironment([:])

    #expect(configuration.enabled)
    #expect(configuration.actionDelay == 1.10)
    #expect(configuration.waitsForDisplay)
}

@Test func visualOverlayConfigurationCanBeDisabled() {
    let configuration = VisualOverlayConfiguration.fromEnvironment([
        "AXON_VISUAL_OVERLAY": "0"
    ])

    #expect(configuration.enabled == false)
}

@Test func visualOverlayConfigurationReadsEnvironment() {
    let configuration = VisualOverlayConfiguration.fromEnvironment([
        "AXON_VISUAL_OVERLAY": "1",
        "AXON_VISUAL_OVERLAY_DELAY_MS": "250",
        "AXON_VISUAL_OVERLAY_WAIT": "0"
    ])

    #expect(configuration.enabled)
    #expect(configuration.actionDelay == 0.25)
    #expect(configuration.waitsForDisplay == false)
}

@Test func visualTargetCarriesFrameLabelStateAndDuration() {
    let target = VisualTarget(
        frame: AXFrame(x: 1, y: 2, width: 3, height: 4),
        label: "AXPress",
        state: .planned,
        duration: 0.1
    )

    #expect(target.frame == AXFrame(x: 1, y: 2, width: 3, height: 4))
    #expect(target.label == "AXPress")
    #expect(target.state == .planned)
    #expect(target.duration == 0.1)
}

/// Display-wait behavior of the AppKit badge overlay. Serialized because each
/// test owns the state of the process-wide main dispatch queue.
@Suite(.serialized)
struct AppKitTargetBadgeOverlayDisplayWaitTests {
    private static let frame = AXFrame(x: 0, y: 0, width: 60, height: 24)

    @Test func showTargetReturnsWhileMainQueueIsBlocked() {
        let mainQueueOccupied = DispatchSemaphore(value: 0)
        let releaseMainQueue = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            mainQueueOccupied.signal()
            releaseMainQueue.wait()
        }
        #expect(mainQueueOccupied.wait(timeout: .now() + 5) == .success)

        let target = VisualTarget(frame: Self.frame, label: "AXPress", state: .planned, duration: 0.2)
        let elapsed = elapsedShowingTarget(target, waitsForDisplay: true)

        releaseMainQueue.signal()
        drainMainQueue()

        #expect(elapsed >= target.duration + AppKitTargetBadgeOverlay.displayWaitSlack)
        #expect(elapsed < target.duration + AppKitTargetBadgeOverlay.displayWaitSlack + 2)
    }

    @Test func showTargetWaitsForDisplayWhenMainQueueIsFree() {
        let target = VisualTarget(frame: Self.frame, label: "AXPress", state: .planned, duration: 0.35)
        let elapsed = elapsedShowingTarget(target, waitsForDisplay: true)

        #expect(elapsed >= target.duration)
        #expect(elapsed < target.duration + AppKitTargetBadgeOverlay.displayWaitSlack)
    }

    @Test func showTargetDoesNotWaitWhenDisplayWaitIsDisabled() {
        let target = VisualTarget(frame: Self.frame, label: "AXPress", state: .planned, duration: 0.35)
        let elapsed = elapsedShowingTarget(target, waitsForDisplay: false)

        drainMainQueue()

        #expect(elapsed < target.duration)
    }

    /// Times `showTarget` from a background thread, the way a socket worker calls it.
    private func elapsedShowingTarget(_ target: VisualTarget, waitsForDisplay: Bool) -> TimeInterval {
        let overlay = AppKitTargetBadgeOverlay(waitsForDisplay: waitsForDisplay)
        let elapsed = ElapsedBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            overlay.showTarget(target)
            elapsed.seconds = Date().timeIntervalSince(start)
            finished.signal()
        }
        finished.wait()
        return elapsed.seconds
    }

    /// Waits until previously enqueued main-queue work (a deferred badge) is done,
    /// so one test's leftovers cannot skew the next one's timing.
    private func drainMainQueue() {
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            drained.signal()
        }
        #expect(drained.wait(timeout: .now() + 5) == .success)
    }
}

private final class ElapsedBox: @unchecked Sendable {
    var seconds: TimeInterval = 0
}
