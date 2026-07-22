import Foundation

/// Runs work on a serial queue from a background thread, waiting only up to a deadline.
///
/// AppKit work has to happen on the main queue, but a blocked main queue must not be able to
/// strand the action that requested it. A plain `DispatchQueue.main.sync` from a worker thread
/// deadlocks outright when the main thread is parked, turning a decorative concern into a hang.
/// Waiting with a deadline degrades that into a bounded delay.
public enum MainQueueHandoff {
    /// The longest an action will wait for its visual annotation to appear.
    public static let defaultTimeout: TimeInterval = 1.0

    /// Returns true when `work` finished before `timeout`.
    ///
    /// A false return does not cancel the work — it stays queued and runs whenever the queue
    /// drains. The caller simply stops waiting for it.
    @discardableResult
    public static func run(
        on queue: DispatchQueue = .main,
        timeout: TimeInterval = defaultTimeout,
        work: @escaping () -> Void
    ) -> Bool {
        let finished = DispatchSemaphore(value: 0)
        queue.async {
            work()
            finished.signal()
        }
        return finished.wait(timeout: .now() + timeout) == .success
    }
}
