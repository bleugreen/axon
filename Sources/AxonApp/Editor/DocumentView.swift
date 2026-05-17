import AxonCore
import SwiftUI

private enum DebugFollowUp: Sendable {
    case runTo(String)
    case clearStopped
}

struct DocumentView: View {
    @Binding var document: AxonDocument
    let isReview: Bool
    let documentID: String?
    let saveDocument: (() -> Void)?
    let discardDocument: (() -> Void)?
    let recordFromHere: ((String?) -> Void)?
    @State private var selectedBlockID: String?
    @State private var selectedArgumentIndex: Int?
    @State private var runStatus: String
    @State private var isRunning = false
    @State private var isSidebarVisible: Bool
    @State private var sidebarLayer: EditorSidebarLayer
    @State private var treeRefreshToken = 0
    @State private var actedOnTarget: JSONValue?
    @State private var lastTrace: [JSONValue] = []
    @State private var lastError: String?
    @State private var debugSessionID: String?
    @State private var debugState: String?
    @State private var cursorBlockID: String?
    @State private var lastDebugActionID: String?
    @State private var pauseReason: String?
    @State private var repairActionID: String?

    init(
        document: Binding<AxonDocument>,
        isReview: Bool = false,
        documentID: String? = nil,
        saveDocument: (() -> Void)? = nil,
        discardDocument: (() -> Void)? = nil,
        recordFromHere: ((String?) -> Void)? = nil
    ) {
        self._document = document
        self.isReview = isReview
        self.documentID = documentID
        self.saveDocument = saveDocument
        self.discardDocument = discardDocument
        self.recordFromHere = recordFromHere
        self._runStatus = State(initialValue: isReview ? "Unsaved recording" : "Idle")
        self._isSidebarVisible = State(initialValue: !document.wrappedValue.recipe.args.isEmpty)
        self._sidebarLayer = State(initialValue: document.wrappedValue.recipe.args.isEmpty ? .tree : .inputs)
    }

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                EditorSidebar(
                    appName: document.recipe.primaryAppName,
                    actedOnTarget: actedOnTarget,
                    args: $document.recipe.args,
                    selectedIndex: $selectedArgumentIndex,
                    selectedLayer: $sidebarLayer,
                    treeRefreshToken: treeRefreshToken,
                    hideSidebar: toggleSidebar
                )
                .frame(width: 300)
                .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
            } else {
                SidebarRevealRail(showSidebar: showSidebar)
                Divider()
            }

            VStack(spacing: 0) {
                DebugControlBar(
                    title: debugTitle,
                    detail: debugDetail,
                    isRunning: isRunning,
                    canRun: !document.recipe.blocks.isEmpty && !isDebugActive,
                    canDebug: !document.recipe.blocks.isEmpty && !isDebugActive,
                    canRunToSelection: selectedBlockID != nil && !document.recipe.blocks.isEmpty,
                    canResume: isDebugPaused,
                    canStep: isDebugPaused,
                    canRetry: isDebugFailed,
                    canRecordFromHere: (isDebugPaused || isDebugFailed) && recordFromHere != nil,
                    canReset: hasDebugState,
                    run: runRecipe,
                    debug: { startDebugSession(runTo: nil) },
                    runToSelection: runToSelection,
                    resume: continueDebugSession,
                    step: stepDebugSession,
                    retry: retryDebugSession,
                    recordFromHere: {
                        recordFromHere?(repairActionID ?? cursorBlockID)
                    },
                    showInspector: showTreeInspector,
                    reset: resetDebugSession,
                    stop: stopDebugSession
                )
                Divider()
                RecipeCanvas(
                    blocks: $document.recipe.blocks,
                    editorMetadata: $document.recipe.editorMetadata,
                    selectedBlockID: $selectedBlockID,
                    inputNames: document.recipe.inputNames,
                    trace: lastTrace,
                    debugCursorBlockID: cursorBlockID,
                    failedRepairBlockID: repairActionID,
                    areBreakpointsDisabled: isRunning,
                    breakpointsChanged: syncBreakpoints
                )
                Divider()
                EditorStatusBar(status: runStatus, error: lastError, traceCount: lastTrace.count)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if let saveDocument {
                    Button {
                        saveDocument()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .disabled(isRunning)
                }

                if let discardDocument {
                    Button(role: .destructive) {
                        discardDocument()
                    } label: {
                        Label("Discard", systemImage: "trash")
                    }
                    .disabled(isRunning)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            if selectedBlockID == nil {
                selectedBlockID = document.recipe.blocks.first?.id
            }
        }
    }

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.16)) {
            isSidebarVisible.toggle()
        }
    }

    private func showSidebar(_ layer: EditorSidebarLayer) {
        withAnimation(.easeInOut(duration: 0.16)) {
            sidebarLayer = layer
            isSidebarVisible = true
        }
        if layer == .tree {
            treeRefreshToken += 1
        }
    }

    private func showTreeInspector() {
        showSidebar(.tree)
    }

    private var runButtonTitle: String {
        isReview ? "Replay" : "Run"
    }

    private var isDebugPaused: Bool {
        debugSessionID != nil && debugState == "paused"
    }

    private var isDebugFailed: Bool {
        debugSessionID != nil && debugState == "failed"
    }

    private var isDebugActive: Bool {
        isDebugPaused || isDebugFailed || debugSessionID != nil
    }

    private var hasDebugState: Bool {
        debugSessionID != nil || debugState != nil || !lastTrace.isEmpty
    }

    private var debugTitle: String {
        if isRunning {
            return runStatus
        }
        if let debugState {
            return debugStatusTitle(debugState)
        }
        return runButtonTitle
    }

    private var debugDetail: String? {
        if let lastError {
            return lastError
        }
        if let pauseReason, pauseReason != "start" {
            return "Paused by \(pauseReason)"
        }
        if !document.recipe.editorMetadata.breakpoints.isEmpty {
            let count = document.recipe.editorMetadata.breakpoints.count
            return "\(count) breakpoint\(count == 1 ? "" : "s")"
        }
        return nil
    }

    private func runRecipe() {
        let runTarget = document.recipe
        guard runTarget.blocks.isEmpty == false else {
            return
        }

        clearDebugState()
        isRunning = true
        runStatus = isReview ? "Replaying" : "Running"
        lastError = nil
        lastTrace = []

        let params: [String: JSONValue]
        if case let .object(object) = runTarget.jsonValue {
            params = object
        } else {
            params = [:]
        }

        Task.detached(priority: .userInitiated) {
            let response: Result<JSONRPCResponse, Error>
            do {
                response = .success(try SocketClient(
                    path: AxonEnvironment.socketPath(),
                    responseTimeoutSeconds: SocketClient.defaultBatchResponseTimeoutSeconds
                ).send(JSONRPCRequest(
                    id: .string("editor.run"),
                    method: "run",
                    params: .object(params)
                )))
            } catch {
                response = .failure(error)
            }

            await MainActor.run {
                isRunning = false
                switch response {
                case let .success(response):
                    handleRunResponse(response)
                case let .failure(error):
                    runStatus = "Failed"
                    lastError = String(describing: error)
                }
            }
        }
    }

    private func startDebugSession(runTo blockID: String?) {
        var params = recipeParams()
        if !document.recipe.editorMetadata.breakpoints.isEmpty {
            params["breakpoints"] = .array(document.recipe.editorMetadata.breakpoints.map(JSONValue.string))
        }
        if let documentID {
            params["documentId"] = .string(documentID)
        }
        showTreeInspector()
        sendDebugRequest(
            id: "editor.debug.create",
            method: "debug.create",
            params: params,
            runningStatus: blockID == nil ? "Starting debugger" : "Preparing debugger",
            followUp: blockID.map(DebugFollowUp.runTo)
        )
    }

    private func runToSelection() {
        guard let selectedBlockID else {
            return
        }
        if debugSessionID == nil {
            startDebugSession(runTo: selectedBlockID)
        } else {
            runToDebugBlock(selectedBlockID)
        }
    }

    private func runToDebugBlock(_ blockID: String) {
        guard let debugSessionID else {
            return
        }
        sendDebugRequest(
            id: "editor.debug.runTo",
            method: "debug.runTo",
            params: [
                "sessionId": .string(debugSessionID),
                "blockId": .string(blockID)
            ],
            runningStatus: "Running to selection"
        )
    }

    private func continueDebugSession() {
        guard let debugSessionID else {
            return
        }
        sendDebugRequest(
            id: "editor.debug.resume",
            method: "debug.resume",
            params: ["sessionId": .string(debugSessionID)],
            runningStatus: "Continuing"
        )
    }

    private func stepDebugSession() {
        guard let debugSessionID else {
            return
        }
        sendDebugRequest(
            id: "editor.debug.step",
            method: "debug.step",
            params: ["sessionId": .string(debugSessionID)],
            runningStatus: "Stepping"
        )
    }

    private func stopDebugSession() {
        guard let debugSessionID else {
            clearDebugState()
            return
        }
        sendDebugRequest(
            id: "editor.debug.stop",
            method: "debug.stop",
            params: ["sessionId": .string(debugSessionID)],
            runningStatus: "Stopping",
            followUp: .clearStopped
        )
    }

    private func retryDebugSession() {
        guard let debugSessionID else {
            return
        }
        sendDebugRequest(
            id: "editor.debug.retry",
            method: "debug.retry",
            params: ["sessionId": .string(debugSessionID)],
            runningStatus: "Retrying"
        )
    }

    private func sendDebugRequest(
        id: String,
        method: String,
        params: [String: JSONValue],
        runningStatus: String,
        followUp: DebugFollowUp? = nil
    ) {
        isRunning = true
        runStatus = runningStatus
        lastError = nil

        Task.detached(priority: .userInitiated) {
            let response: Result<JSONRPCResponse, Error>
            do {
                response = .success(try SocketClient(
                    path: AxonEnvironment.socketPath(),
                    responseTimeoutSeconds: SocketClient.defaultBatchResponseTimeoutSeconds
                ).send(JSONRPCRequest(
                    id: .string(id),
                    method: method,
                    params: .object(params)
                )))
            } catch {
                response = .failure(error)
            }

            await MainActor.run {
                isRunning = false
                switch response {
                case let .success(response):
                    handleDebugResponse(response)
                    handleDebugFollowUp(followUp)
                case let .failure(error):
                    runStatus = "Failed"
                    lastError = String(describing: error)
                }
            }
        }
    }

    private func handleDebugFollowUp(_ followUp: DebugFollowUp?) {
        switch followUp {
        case let .runTo(blockID):
            if debugSessionID != nil {
                runToDebugBlock(blockID)
            }
        case .clearStopped:
            clearDebugState(status: "Stopped")
        case nil:
            return
        }
    }

    private func handleDebugResponse(_ response: JSONRPCResponse) {
        if let error = response.error {
            runStatus = "Failed"
            lastError = error.message
            return
        }
        guard let status = response.result?["debug"] else {
            runStatus = "Failed"
            lastError = "Missing debug status"
            return
        }
        if case let .string(sessionID)? = status["sessionId"] {
            debugSessionID = sessionID
        }
        if case let .string(actionID)? = status["cursorBlockId"] {
            cursorBlockID = actionID
            selectedBlockID = actionID
        } else {
            cursorBlockID = nil
        }
        if case let .string(actionID)? = status["lastActionId"] {
            lastDebugActionID = actionID
        } else {
            lastDebugActionID = nil
        }
        if case let .string(reason)? = status["pauseReason"] {
            pauseReason = reason
        } else {
            pauseReason = nil
        }
        if case let .string(state)? = status["state"] {
            debugState = state
            runStatus = debugStatusTitle(state)
            if state == "failed" {
                repairActionID = cursorBlockID ?? lastDebugActionID
            } else {
                repairActionID = nil
            }
            if state == "completed" || state == "stopped" {
                debugSessionID = nil
            }
        }
        if debugState == "paused" || debugState == "failed" {
            treeRefreshToken += 1
        }
        lastTrace = status["trace"]?.arrayValue ?? lastTrace
        actedOnTarget = targetForActedOnBlock()
        lastError = firstTraceError(in: lastTrace)
    }

    private func debugStatusTitle(_ state: String) -> String {
        switch state {
        case "paused":
            return cursorBlockID.map { "Paused before \($0)" } ?? "Paused"
        case "completed":
            return "Completed"
        case "failed":
            return (repairActionID ?? cursorBlockID ?? lastDebugActionID).map { "Failed at \($0)" } ?? "Failed"
        case "stopped":
            return "Stopped"
        default:
            return state.capitalized
        }
    }

    private func syncBreakpoints(_ breakpoints: [String]) {
        guard let debugSessionID else {
            return
        }
        sendDebugRequest(
            id: "editor.debug.setBreakpoints",
            method: "debug.setBreakpoints",
            params: [
                "sessionId": .string(debugSessionID),
                "breakpoints": .array(breakpoints.map(JSONValue.string))
            ],
            runningStatus: "Updating breakpoints"
        )
    }

    private func resetDebugSession() {
        if debugSessionID != nil {
            stopDebugSession()
        } else {
            clearDebugState(status: "Idle")
        }
    }

    private func clearDebugState(status: String? = nil) {
        debugSessionID = nil
        debugState = nil
        cursorBlockID = nil
        lastDebugActionID = nil
        pauseReason = nil
        repairActionID = nil
        lastTrace = []
        actedOnTarget = nil
        lastError = nil
        if let status {
            runStatus = status
        }
    }

    private func recipeParams() -> [String: JSONValue] {
        if case let .object(object) = document.recipe.jsonValue {
            return object
        }
        return [:]
    }

    private func handleRunResponse(_ response: JSONRPCResponse) {
        if let error = response.error {
            runStatus = "Failed"
            lastError = error.message
            return
        }
        let batch = response.result?["batch"]
        lastTrace = batch?["trace"]?.arrayValue ?? []
        actedOnTarget = targetForActedOnBlock()
        if batch?["success"] == .bool(true) {
            runStatus = isReview ? "Replay completed" : "Completed"
            lastError = nil
        } else {
            runStatus = "Failed"
            lastError = firstTraceError(in: lastTrace) ?? "Recipe failed"
        }
    }

    private func firstTraceError(in trace: [JSONValue]) -> String? {
        for record in trace {
            if record["success"] == .bool(false), case let .string(error)? = record["error"] {
                return error
            }
        }
        return nil
    }

    private func targetForActedOnBlock() -> JSONValue? {
        let actionID = repairActionID ?? lastDebugActionID ?? lastTrace.last?["actionId"]?.editableString
        guard let actionID else {
            return nil
        }
        for block in document.recipe.blocks {
            guard block.id == actionID,
                  case let .action(action) = block
            else {
                continue
            }
            return action.fields["target"]
                ?? action.fields["locator"]
                ?? action.fields["from"]
                ?? action.fields["to"]
        }
        return nil
    }
}

private struct DebugControlBar: View {
    let title: String
    let detail: String?
    let isRunning: Bool
    let canRun: Bool
    let canDebug: Bool
    let canRunToSelection: Bool
    let canResume: Bool
    let canStep: Bool
    let canRetry: Bool
    let canRecordFromHere: Bool
    let canReset: Bool
    let run: () -> Void
    let debug: () -> Void
    let runToSelection: () -> Void
    let resume: () -> Void
    let step: () -> Void
    let retry: () -> Void
    let recordFromHere: () -> Void
    let showInspector: () -> Void
    let reset: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 128, alignment: .leading)

            Divider()
                .frame(height: 22)

            if canRun || canDebug {
                Button(action: run) {
                    Label(isRunning ? "Running" : "Run", systemImage: isRunning ? "hourglass" : "play.fill")
                }
                .disabled(isRunning || !canRun)
                .help("Run recipe")

                Button(action: debug) {
                    Label("Debug", systemImage: "ladybug")
                }
                .disabled(isRunning || !canDebug)
                .help("Start debugger paused before the first step")
            }

            Button(action: runToSelection) {
                Label("Run to Selected", systemImage: "arrow.right.to.line")
            }
            .disabled(isRunning || !canRunToSelection)
            .help("Run until the selected step and pause before it")

            if canResume || canStep || canRetry {
                Divider()
                    .frame(height: 22)
            }

            if canResume {
                Button(action: resume) {
                    Label("Continue", systemImage: "play.fill")
                }
                .disabled(isRunning)
                .help("Continue to the next breakpoint or the end")
            }

            if canStep {
                Button(action: step) {
                    Label("Step", systemImage: "forward.frame.fill")
                }
                .disabled(isRunning)
                .help("Run exactly one step")
            }

            if canRetry {
                Button(action: retry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .disabled(isRunning)
                .help("Retry the failed step")
            }

            if canRecordFromHere {
                Button(action: recordFromHere) {
                    Label("Record From Here", systemImage: "record.circle")
                }
                .disabled(isRunning)
                .help("Record new steps at the current debug position")
            }

            Spacer(minLength: 0)

            Button(action: showInspector) {
                Label("AX Tree", systemImage: EditorSidebarLayer.tree.symbolName)
            }
            .help("Show live accessibility tree inspector")

            if canReset {
                Button(action: reset) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .disabled(isRunning)
                .help("Reset debugger state")
            }

            if canResume || canStep || canRetry {
                Button(role: .destructive, action: stop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(isRunning)
                .help("Stop debugger session")
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RecipeEditorPalette.sidebarBackground)
    }
}
