import AxonCore
import SwiftUI

struct DocumentView: View {
    @Binding var document: AxonDocument
    @State private var selectedBlockID: String?
    @State private var selectedArgumentIndex: Int?
    @State private var runStatus = "Idle"
    @State private var isRunning = false
    @State private var isSidebarVisible = true
    @State private var lastTrace: [JSONValue] = []
    @State private var lastError: String?

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                RecipeSidebar(
                    appName: document.recipe.primaryAppName,
                    args: $document.recipe.args,
                    selectedIndex: $selectedArgumentIndex,
                    hideSidebar: toggleSidebar
                )
                .frame(width: 260)
                .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
            } else {
                SidebarRevealRail(showSidebar: toggleSidebar)
                Divider()
            }

            VStack(spacing: 0) {
                RecipeCanvas(
                    blocks: $document.recipe.blocks,
                    editorMetadata: $document.recipe.editorMetadata,
                    selectedBlockID: $selectedBlockID,
                    inputNames: document.recipe.inputNames,
                    trace: lastTrace
                )
                Divider()
                EditorStatusBar(status: runStatus, error: lastError, traceCount: lastTrace.count)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    runRecipe(.full)
                } label: {
                    Label(isRunning ? "Running" : "Run", systemImage: isRunning ? "hourglass" : "play.fill")
                }
                .disabled(isRunning)

                Button {
                    runRecipe(.toCursor(selectedBlockID))
                } label: {
                    Label("Run to Selection", systemImage: "playpause.fill")
                }
                .disabled(isRunning || selectedBlockID == nil)

                Button {
                    runRecipe(.toFirstBreakpoint)
                } label: {
                    Label("Run to Breakpoint", systemImage: "smallcircle.filled.circle")
                }
                .disabled(isRunning || document.recipe.editorMetadata.breakpoints.isEmpty)

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

    private func runRecipe(_ mode: RunMode) {
        let runTarget = recipe(for: mode)
        guard runTarget.blocks.isEmpty == false || mode == .full else {
            return
        }

        isRunning = true
        runStatus = mode.runningStatus
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
                    handleRunResponse(response, mode: mode)
                case let .failure(error):
                    runStatus = "Failed"
                    lastError = String(describing: error)
                }
            }
        }
    }

    private func handleRunResponse(_ response: JSONRPCResponse, mode: RunMode) {
        if let error = response.error {
            runStatus = "Failed"
            lastError = error.message
            return
        }
        let batch = response.result?["batch"]
        lastTrace = batch?["trace"]?.arrayValue ?? []
        if batch?["success"] == .bool(true) {
            runStatus = mode.successStatus
            lastError = nil
        } else {
            runStatus = "Failed"
            lastError = firstTraceError(in: lastTrace) ?? "Recipe failed"
        }
    }

    private func recipe(for mode: RunMode) -> AxonRecipe {
        switch mode {
        case .full:
            return document.recipe
        case let .toCursor(blockID):
            return recipePrefix(before: blockID)
        case .toFirstBreakpoint:
            let blockIDs = document.recipe.blocks.compactMap(\.id)
            let breakpoint = document.recipe.editorMetadata.breakpoints.first { blockIDs.contains($0) }
            return recipePrefix(before: breakpoint)
        }
    }

    private func recipePrefix(before blockID: String?) -> AxonRecipe {
        guard let blockID,
              let index = document.recipe.blocks.firstIndex(where: { $0.id == blockID })
        else {
            return document.recipe
        }
        return AxonRecipe(
            version: document.recipe.version,
            args: document.recipe.args,
            blocks: Array(document.recipe.blocks[..<index]),
            unknownTopLevelFields: document.recipe.unknownTopLevelFields
        )
    }

    private func firstTraceError(in trace: [JSONValue]) -> String? {
        for record in trace {
            if record["success"] == .bool(false), case let .string(error)? = record["error"] {
                return error
            }
        }
        return nil
    }
}

private enum RunMode: Equatable {
    case full
    case toCursor(String?)
    case toFirstBreakpoint

    var runningStatus: String {
        switch self {
        case .full:
            return "Running"
        case .toCursor:
            return "Running to selection"
        case .toFirstBreakpoint:
            return "Running to breakpoint"
        }
    }

    var successStatus: String {
        switch self {
        case .full:
            return "Completed"
        case let .toCursor(id):
            return id.map { "Paused before \($0)" } ?? "Paused"
        case .toFirstBreakpoint:
            return "Paused at breakpoint"
        }
    }
}
