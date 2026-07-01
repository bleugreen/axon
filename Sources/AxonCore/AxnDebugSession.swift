import Foundation

public final class AxnDebugSession {
    public let id: String

    private let lock = NSRecursiveLock()
    private let executor: AxnRunner
    private let actions: [PreparedAxnAction]
    private let dryRun: Bool
    private var breakpoints: Set<String>
    private let documentID: String?
    private let label: String?
    private var facts: [String: RecordedFact] = [:]
    private var trace: [JSONValue] = []
    private var currentIndex: Int?
    private var lastActionID: String?
    private var pauseReason: String?
    private var pauseSnapshot: JSONValue?
    private var state: State

    init(
        id: String = UUID().uuidString,
        executor: AxnRunner,
        actions: [PreparedAxnAction],
        dryRun: Bool,
        breakpoints: Set<String>,
        documentID: String? = nil,
        label: String? = nil
    ) {
        self.id = id
        self.executor = executor
        self.actions = actions
        self.dryRun = dryRun
        self.breakpoints = breakpoints
        self.documentID = documentID
        self.label = label
        self.currentIndex = actions.isEmpty ? nil : 0
        self.state = self.currentIndex == nil ? .completed : .paused
        self.pauseReason = self.currentIndex == nil ? nil : "start"
    }

    public func runUntilPause(before blockID: String?) {
        _ = runToBlock(blockID, reason: "pauseBefore")
    }

    @discardableResult
    public func runToBlock(_ blockID: String?) -> JSONValue {
        runToBlock(blockID, reason: "runTo")
    }

    @discardableResult
    private func runToBlock(_ blockID: String?, reason: String) -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        guard let blockID else {
            return status
        }
        while state == .paused, currentActionID != blockID {
            _ = step()
        }
        if state == .paused, currentActionID == blockID {
            capturePauseSnapshot(reason: reason)
        }
        return status
    }

    @discardableResult
    public func setBreakpoints(_ breakpoints: Set<String>) -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        self.breakpoints = breakpoints
        return status
    }

    @discardableResult
    public func step() -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        guard state == .paused, let index = currentIndex else {
            return status
        }
        pauseSnapshot = nil
        pauseReason = nil
        let record = executor.debugRunAction(
            actions[index],
            dryRun: dryRun,
            facts: &facts
        )
        trace.append(record)
        lastActionID = actions[index].action.id
        if record["success"] == .bool(false) {
            state = .failed
            capturePauseSnapshot(reason: "failure")
            return status
        }

        currentIndex = index + 1 < actions.count ? index + 1 : nil
        state = currentIndex == nil ? .completed : .paused
        pauseReason = state == .paused ? "step" : nil
        return status
    }

    @discardableResult
    public func continueUntilBreakpoint() -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        pauseSnapshot = nil
        pauseReason = nil
        while state == .paused {
            _ = step()
            guard state == .paused else {
                break
            }
            if let currentActionID, breakpoints.contains(currentActionID) {
                capturePauseSnapshot(reason: "breakpoint")
                break
            }
        }
        return status
    }

    @discardableResult
    public func retryFailedAction() -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        guard state == .failed, currentIndex != nil else {
            return status
        }
        state = .paused
        pauseReason = nil
        return step()
    }

    @discardableResult
    public func stop() -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        pauseSnapshot = nil
        state = .stopped
        return status
    }

    public var status: JSONValue {
        lock.lock()
        defer { lock.unlock() }
        var object: [String: JSONValue] = [
            "sessionId": .string(id),
            "state": .string(state.rawValue),
            "dryRun": .bool(dryRun),
            "trace": .array(trace),
            "breakpoints": .array(breakpoints.sorted().map(JSONValue.string)),
            "availableActions": .array(availableActions.map(JSONValue.string))
        ]
        if let currentIndex {
            object["currentIndex"] = .int(actions[currentIndex].index)
        } else {
            object["currentIndex"] = .null
        }
        if let currentActionID {
            object["currentActionId"] = .string(currentActionID)
            object["cursorBlockId"] = .string(currentActionID)
        } else {
            object["currentActionId"] = .null
            object["cursorBlockId"] = .null
        }
        if let lastActionID {
            object["lastActionId"] = .string(lastActionID)
        } else {
            object["lastActionId"] = .null
        }
        if let pauseReason {
            object["pauseReason"] = .string(pauseReason)
        } else {
            object["pauseReason"] = .null
        }
        if let documentID {
            object["documentId"] = .string(documentID)
        }
        if let label {
            object["label"] = .string(label)
        }
        if let pauseSnapshot {
            object["pauseSnapshot"] = pauseSnapshot
        }
        return .object(object)
    }

    private var availableActions: [String] {
        switch state {
        case .paused:
            return ["resume", "runTo", "step", "setBreakpoints", "stop"]
        case .failed:
            return ["retry", "setBreakpoints", "stop"]
        case .completed, .stopped:
            return []
        }
    }

    private var currentActionID: String? {
        guard let currentIndex else {
            return nil
        }
        return actions[currentIndex].action.id
    }

    private func capturePauseSnapshot(reason: String) {
        pauseReason = reason
        guard let currentIndex else {
            pauseSnapshot = nil
            return
        }
        pauseSnapshot = executor.debugPauseSnapshot(for: actions[currentIndex].action, reason: reason)
    }

    private enum State: String {
        case paused
        case completed
        case failed
        case stopped
    }
}
