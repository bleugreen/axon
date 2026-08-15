import ApplicationServices
import Foundation

public struct CommandRouterServices {
    public typealias LocatorResolutionProvider = (_ app: String, _ locator: AXLocator, _ scrollToVisible: Bool) throws -> LocatorResolution
    public typealias SnapshotWithChildDepthProvider = (_ app: String, _ screenshot: Bool, _ childDepth: Int?) throws -> AppSnapshot
    public typealias ReadableAXStateProvider = (_ handle: SnapshotHandle) throws -> ReadableAXState

    public let listApps: () -> [AppIdentity]
    public let listAllApps: () -> [AppIdentity]
    public let captureSnapshot: (String, Bool) throws -> AppSnapshot
    public let captureSnapshotWithChildDepth: SnapshotWithChildDepthProvider
    public let resolveLocator: LocatorResolutionProvider
    public let axnSnapshotProvider: AxnRunner.SnapshotProvider
    public let requestAccessibility: () -> Bool
    public let actions: PrimitiveActionHandlers
    public let elementStore: AXElementStore
    public let semanticNameRegistry: SemanticNameRegistry
    public let changeObserver: AppChangeObserving
    public let history: ActionHistoryStore
    public let recognizeText: TextRecognitionHandler
    public let activeCredentialFilterProvider: @Sendable () -> any ActiveCredentialFilter
    public let debugSessions: AxnDebugSessionStore
    public let readableAXState: ReadableAXStateProvider
    public let browserAutomation: any BrowserAutomationServing
    /// Reads the before/after element and app state that `save` derives postconditions from.
    /// Nil disables observation entirely, which is what a router with no live Accessibility wants.
    public let actionStateObserver: (any ActionStateObserving)?
    public let now: () -> Date
    public let sleepMilliseconds: (Int) -> Void
    /// The local socket this daemon serves, reported as the endpoint in health documents.
    public let endpoint: String
    /// What the daemon knows about itself. Injectable so the derivation can be tested without a
    /// logged-in Mac.
    public let daemonReport: (String) -> DaemonReport
    /// Ends the daemon process. Called after the shutdown response has been handed to the socket.
    public let requestShutdown: () -> Void

    public init(
        listApps: @escaping () -> [AppIdentity] = { AppResolver().recordableApps() },
        listAllApps: @escaping () -> [AppIdentity] = { AppResolver().runningApps() },
        captureSnapshot: ((String, Bool) throws -> AppSnapshot)? = nil,
        captureSnapshotWithChildDepth: SnapshotWithChildDepthProvider? = nil,
        resolveLocator: LocatorResolutionProvider? = nil,
        axnSnapshotProvider: AxnRunner.SnapshotProvider? = nil,
        requestAccessibility: @escaping () -> Bool = AccessibilityPermission.requestTrustPrompt,
        actions: PrimitiveActionHandlers? = nil,
        elementStore: AXElementStore = AXElementStore(),
        semanticNameRegistry: SemanticNameRegistry = SemanticNameRegistry(),
        changeObserver: AppChangeObserving = AXAppChangeObserverRegistry(),
        history: ActionHistoryStore = .shared,
        recognizeText: @escaping TextRecognitionHandler = VisionTextRecognizer.recognizeText(in:),
        activeCredentialFilter: any ActiveCredentialFilter = EmptyActiveCredentialFilter(),
        activeCredentialFilterProvider: (@Sendable () -> any ActiveCredentialFilter)? = nil,
        debugSessions: AxnDebugSessionStore = AxnDebugSessionStore(),
        readableAXState: ReadableAXStateProvider? = nil,
        browserAutomation: any BrowserAutomationServing = AppleScriptBrowserAutomation(),
        actionStateObserver: (any ActionStateObserving)? = nil,
        now: @escaping () -> Date = Date.init,
        sleepMilliseconds: @escaping (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000) },
        endpoint: String = AxonEnvironment.socketPath(),
        daemonReport: ((String) -> DaemonReport)? = nil,
        requestShutdown: @escaping () -> Void = CommandRouterServices.exitAfterResponding
    ) {
        let defaultCaptureSnapshot: (String, Bool) throws -> AppSnapshot = captureSnapshot ?? { app, screenshot in
            try AXFullTreeCapturer(elementStore: elementStore).capture(app: app, screenshot: screenshot)
        }
        let liveLocatorResolver = AXLiveLocatorResolver(elementStore: elementStore)

        self.listApps = listApps
        self.semanticNameRegistry = semanticNameRegistry
        self.listAllApps = listAllApps
        self.captureSnapshot = defaultCaptureSnapshot
        self.captureSnapshotWithChildDepth = captureSnapshotWithChildDepth ?? { app, screenshot, childDepth in
            if let captureSnapshot, childDepth == nil {
                return try captureSnapshot(app, screenshot)
            }
            if childDepth != 0 {
                return try AXFullTreeCapturer(elementStore: elementStore).capture(app: app, screenshot: screenshot)
            }
            // childDepth == 0 is the explicit paged-root mode: retain the top-level
            // window handles without pre-walking descendants so callers can request
            // child pages from live AX elements through later handle-targeted look calls.
            return try AXSnapshotCapturer(elementStore: elementStore).capture(
                app: app,
                screenshot: screenshot,
                childDepth: childDepth
            )
        }
        self.resolveLocator = resolveLocator ?? { app, locator, scrollToVisible in
            try liveLocatorResolver.resolve(app: app, locator: locator, scrollToVisible: scrollToVisible)
        }
        self.axnSnapshotProvider = axnSnapshotProvider ?? { app in
            try liveLocatorResolver.captureSnapshot(app: app)
        }
        self.requestAccessibility = requestAccessibility
        self.actions = actions ?? AXPrimitiveActionExecutor(elementStore: elementStore).handlers()
        self.elementStore = elementStore
        self.changeObserver = changeObserver
        self.history = history
        self.recognizeText = recognizeText
        self.activeCredentialFilterProvider = activeCredentialFilterProvider ?? { activeCredentialFilter }
        self.debugSessions = debugSessions
        self.readableAXState = readableAXState ?? { handle in
            let element = try elementStore.element(for: handle)
            return ReadableAXState(element: element)
        }
        self.browserAutomation = browserAutomation
        self.actionStateObserver = actionStateObserver ?? AXElementObserver(elementStore: elementStore)
        self.now = now
        self.sleepMilliseconds = sleepMilliseconds
        self.endpoint = endpoint
        // Answering a request at all proves the daemon is serving, so readiness is true here by
        // construction. Readiness is only ever false in a document the CLI synthesized.
        self.daemonReport = daemonReport ?? { endpoint in
            Doctor.daemonReport(endpoint: endpoint, ready: true)
        }
        self.requestShutdown = requestShutdown
    }

    /// Exits once the in-flight response has had time to reach the socket.
    ///
    /// A `shutdown` request is answered before the process ends so the caller learns which process
    /// it stopped; exiting inside the handler would close the connection first and leave every
    /// lifecycle command unable to tell a clean stop from a crash.
    public static func exitAfterResponding() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            exit(0)
        }
    }
}

private func locatorResolutionApp(for record: SemanticNameRecord, callerApp: String) -> String {
    let processIdentifier = record.appIdentity.processIdentifier
    return processIdentifier > 0 ? String(processIdentifier) : callerApp
}

private struct SemanticResolutionFailure: Error {
    let status: String
    let query: SemanticTargetQuery
    let candidates: [SemanticNameRecord]

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        .object([
            "status": .string(status),
            "confidence": .string("none"),
            "query": .object(["app": .string(query.app), "name": .string(query.name)]),
            "path": .string("semanticRegistry"),
            "context": .string("recordedObservation"),
            "candidates": .array(candidates.map { record in
                let locator = redactSemanticLocator(record.locator.jsonValue, using: activeSecretRedactor)
                return .object([
                    "role": .string(record.role),
                    "label": .string(activeSecretRedactor.redaction(for: record.label)?.value ?? record.label),
                    "name": .string(record.query.name),
                    "score": .int(0),
                    "reasons": .array([.string("semantic name is shared by indistinguishable observed elements")]),
                    "evidence": .array([]),
                    "recordedLocator": locator
                ])
            })
        ])
    }
}

private func redactSemanticLocator(_ value: JSONValue, using redactor: ActiveSecretRedactor) -> JSONValue {
    switch value {
    case let .string(string): return .string(redactor.redaction(for: string)?.value ?? string)
    case let .array(values): return .array(values.map { redactSemanticLocator($0, using: redactor) })
    case let .object(object): return .object(object.mapValues { redactSemanticLocator($0, using: redactor) })
    default: return value
    }
}

private struct AppObservationSignature: Equatable {
    let app: AppIdentity
    let windows: [ObservationNodeSignature]
    let focus: FocusSignature

    init(snapshot: AppSnapshot) {
        app = snapshot.app
        windows = snapshot.windows.map(ObservationNodeSignature.init)
        focus = FocusSignature(snapshot.focus)
    }
}

private struct ObservationNodeSignature: Equatable {
    let role: String
    let subrole: String?
    let title: String?
    let value: String?
    let description: String?
    let help: String?
    let identifier: String?
    let enabled: Bool?
    let focused: Bool?
    let frame: FrameSignature?
    let actions: [String]
    let childCount: Int?
    let truncationReason: String?
    let children: [ObservationNodeSignature]

    init(_ node: AXNode) {
        role = node.role
        subrole = node.subrole
        title = node.title
        value = node.value
        description = node.description
        help = node.help
        identifier = node.identifier
        enabled = node.enabled
        focused = node.focused
        frame = node.frame.map(FrameSignature.init(frame:))
        actions = node.actions
        childCount = node.childCount
        truncationReason = node.truncationReason
        children = node.children.map(ObservationNodeSignature.init)
    }
}

private enum FocusSignature: Equatable {
    case available(ObservationNodeSignature)
    case none
    case inaccessible(String)

    init(_ focus: FocusObservation) {
        switch focus {
        case let .available(element, _): self = .available(ObservationNodeSignature(element))
        case .none: self = .none
        case let .inaccessible(error): self = .inaccessible(error)
        }
    }
}

private struct WaitForStabilityRequest {
    enum Condition: String { case stable, changed }
    let app: String
    let condition: Condition
    let timeoutMs: Int
    let intervalMs: Int
    let stableMs: Int

    init(params: [String: JSONValue]) throws {
        app = try CommandRouterRequestSupport.requiredString("app", in: params)
        let rawCondition = try CommandRouterRequestSupport.optionalString("condition", in: params) ?? Condition.stable.rawValue
        guard let condition = Condition(rawValue: rawCondition) else {
            throw JSONRPCError.invalidParams("condition must be stable or changed")
        }
        self.condition = condition
        timeoutMs = try WaitForValueRequest.boundedMilliseconds("timeoutMs", in: params, defaultValue: 5_000, minimum: 0, maximum: 60_000)
        intervalMs = try WaitForValueRequest.boundedMilliseconds("intervalMs", in: params, defaultValue: 100, minimum: 10, maximum: max(10, timeoutMs == 0 ? 100 : timeoutMs))
        stableMs = try WaitForValueRequest.boundedMilliseconds("stableMs", in: params, defaultValue: 300, minimum: 0, maximum: 10_000)
    }
}

private struct WaitForStabilityResult {
    let success: Bool
    let status: String
    let condition: WaitForStabilityRequest.Condition
    let elapsedMs: Int
    let stableMs: Int
    let snapshot: AppSnapshot

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        .object([
            "success": .bool(success),
            "status": .string(status),
            "condition": .string(condition.rawValue),
            "elapsedMs": .int(elapsedMs),
            "stableMs": .int(stableMs),
            "finalObservation": snapshot.jsonValue(includeTree: true, activeSecretRedactor: activeSecretRedactor)
        ])
    }
}

public struct CommandRouter {
    public typealias LocatorResolutionProvider = CommandRouterServices.LocatorResolutionProvider

    private let services: CommandRouterServices

    public init(services: CommandRouterServices = CommandRouterServices()) {
        self.services = services
    }

    public init(
        listApps: @escaping () -> [AppIdentity] = { AppResolver().recordableApps() },
        listAllApps: @escaping () -> [AppIdentity] = { AppResolver().runningApps() },
        captureSnapshot: ((String, Bool) throws -> AppSnapshot)? = nil,
        resolveLocator: LocatorResolutionProvider? = nil,
        axnSnapshotProvider: AxnRunner.SnapshotProvider? = nil,
        requestAccessibility: @escaping () -> Bool = AccessibilityPermission.requestTrustPrompt,
        actions: PrimitiveActionHandlers? = nil,
        elementStore: AXElementStore = AXElementStore(),
        semanticNameRegistry: SemanticNameRegistry = SemanticNameRegistry(),
        changeObserver: AppChangeObserving = AXAppChangeObserverRegistry(),
        history: ActionHistoryStore = .shared,
        recognizeText: @escaping TextRecognitionHandler = VisionTextRecognizer.recognizeText(in:),
        activeCredentialFilter: any ActiveCredentialFilter = EmptyActiveCredentialFilter(),
        activeCredentialFilterProvider: (@Sendable () -> any ActiveCredentialFilter)? = nil,
        debugSessions: AxnDebugSessionStore = AxnDebugSessionStore(),
        readableAXState: CommandRouterServices.ReadableAXStateProvider? = nil,
        browserAutomation: any BrowserAutomationServing = AppleScriptBrowserAutomation(),
        actionStateObserver: (any ActionStateObserving)? = nil,
        now: @escaping () -> Date = Date.init,
        sleepMilliseconds: @escaping (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000) }
    ) {
        self.init(services: CommandRouterServices(
            listApps: listApps,
            listAllApps: listAllApps,
            captureSnapshot: captureSnapshot,
            resolveLocator: resolveLocator,
            axnSnapshotProvider: axnSnapshotProvider,
            requestAccessibility: requestAccessibility,
            actions: actions,
            elementStore: elementStore,
            semanticNameRegistry: semanticNameRegistry,
            changeObserver: changeObserver,
            history: history,
            recognizeText: recognizeText,
            activeCredentialFilter: activeCredentialFilter,
            activeCredentialFilterProvider: activeCredentialFilterProvider,
            debugSessions: debugSessions,
            readableAXState: readableAXState,
            browserAutomation: browserAutomation,
            actionStateObserver: actionStateObserver,
            now: now,
            sleepMilliseconds: sleepMilliseconds
        ))
    }

    public func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let context = services.history.context(for: request)
        let observations = observationCollector()
        let response = handleCommand(
            context.request,
            historySessionID: context.sessionID,
            observations: observations
        )
        services.history.record(
            request: context.request,
            response: response,
            sessionID: context.sessionID,
            observation: observations.observation,
            semanticTargetLocator: { app, name in
                guard case let .unique(record) = services.semanticNameRegistry.lookup(app: app, name: name) else {
                    return nil
                }
                return record.locator
            },
            activeSecretRedactor: ActiveSecretRedactor(filter: services.activeCredentialFilterProvider())
        )
        return response
    }

    private func observationCollector() -> ActionObservationCollector {
        ActionObservationCollector(
            observer: services.actionStateObserver,
            sleepMilliseconds: services.sleepMilliseconds,
            now: services.now
        )
    }

    private func handleCommand(
        _ request: JSONRPCRequest,
        historySessionID: String? = nil,
        observations: ActionObservationCollector? = nil
    ) -> JSONRPCResponse {
        switch request.method {
        case "health", "permit", "shutdown":
            return SystemCommandHandler(services: services).handle(request)
        case "look", "find", "wait_for_value", "wait_for_stability", "navigate", "windows", "tabs":
            return PerceptionCommandHandler(services: services).handle(request)
        case "click", "invoke", "type", "keyboard", "scroll", "drag":
            return PrimitiveActionCommandHandler(services: services, observations: observations).handle(request)
        case "run", "debug.create", "debug.start", "debug.step", "debug.retry", "debug.continue", "debug.resume", "debug.runTo", "debug.setBreakpoints", "debug.stop":
            return AxnRunCommandHandler(
                services: services,
                commandHandler: { handleCommand($0, observations: $1) },
                observationCollector: observationCollector,
                historySessionID: historySessionID
            ).handle(request)
        case "save":
            return HistoryCommandHandler(services: services).handle(request)
        default:
            return JSONRPCResponse(
                id: request.id,
                error: JSONRPCError.methodNotFound(request.method)
            )
        }
    }
}

private struct SystemCommandHandler {
    let services: CommandRouterServices

    func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        switch request.method {
        case "health":
            do {
                return JSONRPCResponse(
                    id: request.id,
                    result: try services.daemonReport(services.endpoint).jsonObject()
                )
            } catch {
                return JSONRPCResponse(
                    id: request.id,
                    error: .internalError("could not describe daemon health: \(error)")
                )
            }
        case "shutdown":
            services.requestShutdown()
            return JSONRPCResponse(
                id: request.id,
                result: [
                    "shutdown": .bool(true),
                    "processId": .int(Int(ProcessInfo.processInfo.processIdentifier))
                ]
            )
        case "permit":
            let trusted = services.requestAccessibility()
            return JSONRPCResponse(
                id: request.id,
                result: [
                    "accessibility": .string(trusted ? PermissionStatus.trusted.rawValue : PermissionStatus.denied.rawValue),
                    "prompted": .bool(true)
                ]
            )
        default:
            return JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }
    }
}

private struct PerceptionCommandHandler {
    let services: CommandRouterServices

    func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        switch request.method {
        case "look":
            return lookResponse(request)
        case "find":
            return findResponse(request)
        case "wait_for_value":
            return waitForValueResponse(request)
        case "wait_for_stability":
            return waitForStabilityResponse(request)
        case "navigate", "windows", "tabs":
            return browserResponse(request)
        default:
            return JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }
    }

    private func browserResponse(_ request: JSONRPCRequest) -> JSONRPCResponse {
        do {
            let params = try CommandRouterRequestSupport.paramsObject(in: request)
            let decoder = ToolParamDecoder(toolName: request.method, params: params)
            let app = try decoder.requiredString("app")
            switch request.method {
            case "navigate":
                let result = try services.browserAutomation.navigate(app: app, url: try decoder.requiredString("url"))
                return JSONRPCResponse(id: request.id, result: ["navigation": .object([
                    "app": .string(result.app), "requestedURL": .string(result.requestedURL), "url": .string(result.url), "title": .string(result.title), "success": .bool(result.url == result.requestedURL),
                    "verification": .string(result.url == result.requestedURL ? "dictionary_readback" : "dictionary_mismatch")
                ])])
            case "windows":
                let windows = try services.browserAutomation.windows(app: app)
                return JSONRPCResponse(id: request.id, result: ["windows": .array(windows.map { .object([
                    "id": .string($0.id), "index": .int($0.index), "title": .string($0.title), "active": .bool($0.active)
                ]) }), "authority": .string("application_scripting"), "crossCheck": crossCheck(app: app, scriptedTitles: windows.map(\.title))])
            default:
                let tabs = try services.browserAutomation.tabs(app: app, window: try decoder.int("window"))
                return JSONRPCResponse(id: request.id, result: ["tabs": .array(tabs.map { .object([
                    "id": .string($0.id), "windowID": .string($0.windowID), "windowIndex": .int($0.windowIndex), "index": .int($0.index), "title": .string($0.title), "url": .string($0.url), "active": .bool($0.active)
                ]) }), "authority": .string("application_scripting"), "crossCheck": .object(["status": .string("unavailable"), "reason": .string("AX does not expose a portable authoritative tab model")])])
            }
        } catch let error as BrowserAutomationError {
            let invalid: Bool
            switch error { case .unsupportedApp, .invalidURL, .invalidWindow: invalid = true; default: invalid = false }
            if case let .automationNotGranted(denial) = error {
                var data: [String: JSONValue] = [
                    "capability": .string("browserAutomation"),
                    "reason": .string(HealthReason.automationNotGranted),
                    "app": .string(denial.app),
                    "authorization": .string(denial.authorization.rawValue),
                    "leg": .string(denial.leg.rawValue)
                ]
                if let status = denial.status { data["nativeStatus"] = .int(Int(status)) }
                return JSONRPCResponse(id: request.id, error: .internalError(error.description, data: .object(data)))
            }
            return JSONRPCResponse(id: request.id, error: invalid ? .invalidParams(error.description) : .internalError(error.description))
        } catch let error as JSONRPCError {
            return JSONRPCResponse(id: request.id, error: error)
        } catch {
            return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
        }
    }

    private func crossCheck(app: String, scriptedTitles: [String]) -> JSONValue {
        do {
            let snapshot = try services.captureSnapshot(app, false)
            var unmatchedAXTitles = snapshot.windows.compactMap(\.title)
            let matches = scriptedTitles.reduce(into: 0) { count, title in
                if let index = unmatchedAXTitles.firstIndex(of: title) {
                    count += 1
                    unmatchedAXTitles.remove(at: index)
                }
            }
            let axTitles = snapshot.windows.compactMap(\.title)
            return .object(["status": .string(matches == scriptedTitles.count && axTitles.count == scriptedTitles.count ? "matched" : "partial"), "scriptedWindowCount": .int(scriptedTitles.count), "axWindowCount": .int(axTitles.count), "matchingTitles": .int(matches)])
        } catch {
            return .object(["status": .string("unavailable"), "reason": .string("Accessibility cross-check unavailable: \(error)")])
        }
    }

    private func lookResponse(_ request: JSONRPCRequest) -> JSONRPCResponse {
        do {
            let params = try CommandRouterRequestSupport.paramsObject(in: request)
            let decoder = ToolParamDecoder(toolName: "look", params: params)
            let activeSecretRedactor = activeSecretRedactor()
            if params["since"] != nil {
                return try changedSinceResponse(id: request.id, params: params)
            }
            let semanticTarget = try CommandRouterRequestSupport.optionalToolTarget("target", in: params, acceptedKinds: .element)
            let app = try CommandRouterRequestSupport.optionalString("app", in: params)
            guard semanticTarget != nil || app != nil else {
                let format = try decoder.string("format")
                let includeAllApps = (try decoder.bool("all") ?? false) || format == "debug"
                return JSONRPCResponse(
                    id: request.id,
                    result: [
                        "apps": .array((includeAllApps ? services.listAllApps() : services.listApps()).map(\.jsonValue))
                    ]
                )
            }
            if case let .semanticName(app, name)? = semanticTarget {
                let parentHandle: String
                switch services.semanticNameRegistry.lookup(app: app, name: name) {
                case let .unique(record):
                    let resolution = try services.resolveLocator(
                        locatorResolutionApp(for: record, callerApp: app),
                        record.locator,
                        false
                    )
                    guard resolution.status == .unique, let handle = resolution.best?.handle else {
                        throw JSONRPCError.invalidParams("Semantic paging target did not resolve uniquely")
                    }
                    parentHandle = handle.rawValue
                case .missing:
                    throw JSONRPCError.invalidParams("Unknown semantic paging target; run look for the app first")
                case .ambiguous:
                    throw JSONRPCError.invalidParams("Semantic paging target is ambiguous")
                }
                let offset = try decoder.int("offset") ?? 0
                let limit = try decoder.int("limit") ?? AXSnapshotCapturer.defaultMaxChildrenPerNode
                let direct = try decoder.bool("direct") ?? false
                let allDirectChildren = try decoder.bool("all") ?? false
                let children = try AXSnapshotCapturer(elementStore: services.elementStore).captureChildren(
                    parentHandle: parentHandle,
                    offset: offset,
                    limit: limit,
                    direct: direct,
                    allDirectChildren: allDirectChildren
                )
                let appIdentity = try services.elementStore.summary(for: children.snapshotID).app
                let records = services.semanticNameRegistry.register(page: children, app: appIdentity)
                let rendered = children.jsonValue(activeSecretRedactor: activeSecretRedactor)
                    .renderingPagedSemanticNames(records, parent: SemanticTargetQuery(app: app, name: name))
                return JSONRPCResponse(id: request.id, result: ["children": rendered])
            }
            let format = try decoder.string("format")
            let screenshot = try decoder.bool("screenshot") ?? true
            let screenText = try decoder.bool("screenText") ?? false
            let includeTree = try decoder.bool("tree") ?? true
            let childDepth = try decoder.int("childDepth")
            guard let app else {
                throw JSONRPCError.invalidParams("look requires app when target is omitted")
            }
            let snapshot = try services.captureSnapshotWithChildDepth(app, screenshot || screenText, childDepth)
            services.elementStore.store(summary: observedSummary(for: snapshot))
            services.semanticNameRegistry.register(snapshot: snapshot)
            let semanticNames = SemanticNameDeriver.derive(from: snapshot.jsonValue(includeTree: true))
            var snapshotJSON = snapshot.jsonValue(
                includeTree: includeTree,
                activeSecretRedactor: activeSecretRedactor
            ).renderingSemanticNames(semanticNames, includeDebugHandles: format == "debug")
            let screenTextItems = (screenText || screenshot)
                ? ScreenTextExtractor(recognizeText: services.recognizeText).extract(in: snapshot)
                : []
            let screenshotOCRDetectedActiveCredential = screenshot && !screenText && screenTextItems
                .containsActiveCredentialRedaction(activeSecretRedactor: activeSecretRedactor)
            if screenText {
                snapshotJSON = snapshotJSON.addingScreenText(
                    screenTextItems,
                    includeScreenshot: screenshot,
                    activeSecretRedactor: activeSecretRedactor
                )
            }
            snapshotJSON = snapshotJSON.addingScreenshotUnavailable(
                requestedScreenshot: screenshot,
                capturedScreenshot: snapshot.screenshot
            )
            snapshotJSON = snapshotJSON.omittingScreenshotForActiveCredentialRedaction(
                requestedScreenshot: screenshot,
                forceOmit: screenshotOCRDetectedActiveCredential
            )
            return JSONRPCResponse(
                id: request.id,
                result: [
                    "snapshot": snapshotJSON
                ]
            )
        } catch let error as JSONRPCError {
            return JSONRPCResponse(id: request.id, error: error)
        } catch let error as AXElementStoreError {
            return JSONRPCResponse(id: request.id, error: .invalidParams(error.description))
        } catch {
            return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
        }
    }

    private func findResponse(_ request: JSONRPCRequest) -> JSONRPCResponse {
        do {
            let params = try CommandRouterRequestSupport.paramsObject(in: request)
            let decoder = ToolParamDecoder(toolName: "find", params: params)
            let app = try decoder.requiredString("app")
            let locator = try decoder.requiredLocator("locator")
            let resolution = try services.resolveLocator(app, locator, false)
            let activeSecretRedactor = activeSecretRedactor()
            return JSONRPCResponse(
                id: request.id,
                result: [
                    "resolution": resolution.jsonValue(activeSecretRedactor: activeSecretRedactor)
                ]
            )
        } catch let error as JSONRPCError {
            return JSONRPCResponse(id: request.id, error: error)
        } catch {
            return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
        }
    }

    private func waitForValueResponse(_ request: JSONRPCRequest) -> JSONRPCResponse {
        do {
            let params = try CommandRouterRequestSupport.paramsObject(in: request)
            let waiter = try WaitForValueRequest(params: params)
            let result = try waitForValue(waiter)
            return JSONRPCResponse(id: request.id, result: ["wait": result.jsonValue(activeSecretRedactor: activeSecretRedactor())])
        } catch let error as JSONRPCError {
            return JSONRPCResponse(id: request.id, error: error)
        } catch let error as AXElementStoreError {
            return JSONRPCResponse(id: request.id, error: .invalidParams(error.description))
        } catch {
            return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
        }
    }

    private func waitForValue(_ request: WaitForValueRequest) throws -> WaitForValueResult {
        let startedAt = services.now()
        let deadline = startedAt.addingTimeInterval(Double(request.timeoutMs) / 1_000)
        var lastResolvedState: ReadableAXState?
        var lastResolution: LocatorResolution?

        while true {
            let elapsedMs = max(0, Int((services.now().timeIntervalSince(startedAt) * 1_000).rounded()))
            let record: SemanticNameRecord
            switch services.semanticNameRegistry.lookup(app: request.app, name: request.name) {
            case let .unique(found): record = found
            case .missing:
                throw SemanticResolutionFailure(status: "missing", query: SemanticTargetQuery(app: request.app, name: request.name), candidates: [])
            case let .ambiguous(query, candidates):
                throw SemanticResolutionFailure(status: "ambiguous", query: query, candidates: candidates)
            }
            let resolution = try services.resolveLocator(
                locatorResolutionApp(for: record, callerApp: request.app),
                record.locator,
                false
            )
            lastResolution = resolution
            if resolution.status == .unique, let handle = resolution.best?.handle {
                let state = try services.readableAXState(handle)
                lastResolvedState = state
                if let match = state.firstMatch(using: request.predicate) {
                    return WaitForValueResult(
                        success: true,
                        status: "satisfied",
                        predicate: request.predicate,
                        elapsedMs: elapsedMs,
                        match: match,
                        lastObserved: state,
                        resolution: resolution,
                        message: "wait_for_value predicate satisfied"
                    )
                }
            }

            let now = services.now()
            guard now < deadline else {
                if let lastResolvedState {
                    return WaitForValueResult(
                        success: false,
                        status: "predicate_timeout",
                        predicate: request.predicate,
                        elapsedMs: max(0, Int((now.timeIntervalSince(startedAt) * 1_000).rounded())),
                        match: nil,
                        lastObserved: lastResolvedState,
                        resolution: lastResolution,
                        message: "wait_for_value timed out before the predicate matched"
                    )
                }
                return WaitForValueResult(
                    success: false,
                    status: "target_unresolved_timeout",
                    predicate: request.predicate,
                    elapsedMs: max(0, Int((now.timeIntervalSince(startedAt) * 1_000).rounded())),
                    match: nil,
                    lastObserved: nil,
                    resolution: lastResolution,
                    message: "wait_for_value timed out before the target resolved uniquely"
                )
            }

            let remainingMs = max(0, Int((deadline.timeIntervalSince(now) * 1_000).rounded(.up)))
            services.sleepMilliseconds(min(request.intervalMs, remainingMs))
        }
    }

    private func waitForStabilityResponse(_ request: JSONRPCRequest) -> JSONRPCResponse {
        do {
            let params = try CommandRouterRequestSupport.paramsObject(in: request)
            let waiter = try WaitForStabilityRequest(params: params)
            let result = try waitForStability(waiter)
            return JSONRPCResponse(id: request.id, result: ["wait": result.jsonValue(activeSecretRedactor: activeSecretRedactor())])
        } catch let error as JSONRPCError {
            return JSONRPCResponse(id: request.id, error: error)
        } catch {
            return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
        }
    }

    private func waitForStability(_ request: WaitForStabilityRequest) throws -> WaitForStabilityResult {
        let startedAt = services.now()
        let deadline = startedAt.addingTimeInterval(Double(request.timeoutMs) / 1_000)
        var initialSignature: AppObservationSignature?
        var lastSignature: AppObservationSignature?
        var stableSince = startedAt

        while true {
            let snapshot = try services.captureSnapshot(request.app, false)
            let signature = AppObservationSignature(snapshot: snapshot)
            if initialSignature == nil { initialSignature = signature }
            let now = services.now()
            if signature != lastSignature {
                lastSignature = signature
                stableSince = now
            }
            let elapsedMs = max(0, Int((now.timeIntervalSince(startedAt) * 1_000).rounded()))
            let stableMs = max(0, Int((now.timeIntervalSince(stableSince) * 1_000).rounded()))
            let satisfied = request.condition == .changed ? signature != initialSignature : stableMs >= request.stableMs
            if satisfied {
                return WaitForStabilityResult(success: true, status: "satisfied", condition: request.condition, elapsedMs: elapsedMs, stableMs: stableMs, snapshot: snapshot)
            }
            guard now < deadline else {
                return WaitForStabilityResult(success: false, status: "timeout", condition: request.condition, elapsedMs: elapsedMs, stableMs: stableMs, snapshot: snapshot)
            }
            let remainingMs = max(0, Int((deadline.timeIntervalSince(now) * 1_000).rounded(.up)))
            services.sleepMilliseconds(min(request.intervalMs, remainingMs))
        }
    }

    private func changedSinceResponse(id: JSONRPCID?, params: [String: JSONValue]) throws -> JSONRPCResponse {
        let snapshotID = SnapshotID(try CommandRouterRequestSupport.requiredString("since", in: params))
        let activeSecretRedactor = activeSecretRedactor()
        do {
            let previous = try services.elementStore.summary(for: snapshotID)
            let observedChanges = observedChanges(since: previous)
            let currentSnapshot = try services.captureSnapshot(previous.appQuery, false)
            let current = observedSummary(for: currentSnapshot)
            services.elementStore.store(summary: current)
            let change = previous.change(comparedTo: current)
            var result: [String: JSONValue] = [
                "changed": .bool(change.changed),
                "reason": .string(change.reason),
                "snapshotId": .string(previous.id.rawValue),
                "currentSnapshotId": .string(current.id.rawValue),
                "previous": previous.jsonValue(activeSecretRedactor: activeSecretRedactor),
                "current": current.jsonValue(activeSecretRedactor: activeSecretRedactor)
            ]
            if !observedChanges.isEmpty {
                result["observedChanges"] = .array(observedChanges.map(\.jsonValue))
            }
            return JSONRPCResponse(id: id, result: result)
        } catch AppResolverError.notFound {
            let previous = try services.elementStore.summary(for: snapshotID)
            return JSONRPCResponse(
                id: id,
                result: [
                    "changed": .bool(true),
                    "reason": .string("app_missing"),
                    "snapshotId": .string(previous.id.rawValue),
                    "currentSnapshotId": .null,
                    "previous": previous.jsonValue(activeSecretRedactor: activeSecretRedactor),
                    "current": .null
                ]
            )
        }
    }

    private func observedSummary(for snapshot: AppSnapshot) -> SnapshotSummary {
        services.changeObserver.startObserving(app: snapshot.app)
        return SnapshotSummary(snapshot: snapshot, observationToken: services.changeObserver.token(for: snapshot.app))
    }

    private func observedChanges(since previous: SnapshotSummary) -> [ObservedAppChange] {
        guard let token = previous.observationToken else {
            return []
        }
        return services.changeObserver.changes(since: token, app: previous.app)
    }

    private func activeSecretRedactor() -> ActiveSecretRedactor {
        ActiveSecretRedactor(filter: services.activeCredentialFilterProvider())
    }
}

private struct PrimitiveActionCommandHandler {
    let services: CommandRouterServices
    /// Collects the before/after reads around whichever primitive this request dispatches. This is
    /// the one place every dispatched action passes through with its resolved element in hand, so
    /// it is the only place an observation can be taken without resolving the target a second time.
    let observations: ActionObservationCollector?

    func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        switch request.method {
        case "click":
            return actionResponse(id: request.id) {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let decoder = ToolParamDecoder(toolName: "click", params: params)
                let policy = try decoder.deliveryPolicy()
                let app = try decoder.string("app")
                let target = try CommandRouterRequestSupport.requiredToolTarget("target", in: params, acceptedKinds: .pointer)
                switch target {
                case let .point(point):
                    return try services.actions.clickPoint(
                        screenPoint(for: point, defaultApp: app, fieldName: "target"),
                        policy
                    )
                case let .textLocation(location):
                    let resolution = try resolveTextLocationTarget(location)
                    return try withLocationResolution(
                        services.actions.clickPoint(resolution.point, policy),
                        resolution: resolution
                    )
                case .semanticName:
                    let resolved = try resolveElementTarget(target)
                    observations?.begin(tool: "click", handle: resolved.handle)
                    return observed(withTargetResolution(
                        try services.actions.click(resolved.handle, policy),
                        resolution: resolved.resolution
                    ))
                }
            }
        case "invoke":
            return actionResponse(id: request.id) {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let decoder = ToolParamDecoder(toolName: "invoke", params: params)
                let policy = try decoder.deliveryPolicy()
                let resolved = try resolveElementTarget(
                    try CommandRouterRequestSupport.requiredToolTarget("target", in: params, acceptedKinds: .element)
                )
                observations?.begin(tool: "invoke", handle: resolved.handle)
                return observed(withTargetResolution(try services.actions.invoke(
                    resolved.handle,
                    try decoder.requiredString("name"),
                    policy
                ), resolution: resolved.resolution))
            }
        case "type":
            return actionResponse(id: request.id) {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let decoder = ToolParamDecoder(toolName: "type", params: params)
                let policy = try decoder.deliveryPolicy()
                let resolved = try resolveElementTarget(
                    try CommandRouterRequestSupport.requiredToolTarget("target", in: params, acceptedKinds: .element)
                )
                let value = try decoder.requiredString("value")
                observations?.begin(tool: "type", handle: resolved.handle, inputs: [value])
                return observed(withTargetResolution(try services.actions.type(
                    resolved.handle,
                    value,
                    policy
                ), resolution: resolved.resolution))
            }
        case "keyboard":
            return actionResponse(id: request.id) {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let decoder = ToolParamDecoder(toolName: "keyboard", params: params)
                let policy = try decoder.deliveryPolicy()
                let app = try decoder.string("app")
                let intent = try KeyboardIntent.validated(
                    text: decoder.string("text"),
                    key: decoder.string("key")
                )
                observations?.begin(
                    tool: "keyboard",
                    app: app,
                    inputs: [try decoder.string("text"), try decoder.string("key")].compactMap { $0 }
                )
                return observed(try services.actions.keyboard(app, intent, policy))
            }
        case "scroll":
            return actionResponse(id: request.id) {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let decoder = ToolParamDecoder(toolName: "scroll", params: params)
                let policy = try decoder.deliveryPolicy()
                let target = try optionalResolvedPointerTarget("target", in: params)
                if let handle = target?.target.handle {
                    observations?.begin(tool: "scroll", handle: handle)
                }
                let result = try services.actions.scroll(
                    target?.target,
                    try decoder.string("app"),
                    try decoder.number("deltaX") ?? 0,
                    try decoder.number("deltaY") ?? -120,
                    policy
                )
                return observed(withTargetResolution(
                    withLocationResolution(result, resolution: target?.locationResolution),
                    resolution: target?.targetResolution
                ))
            }
        case "drag":
            return actionResponse(id: request.id) {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let decoder = ToolParamDecoder(toolName: "drag", params: params)
                let policy = try decoder.deliveryPolicy()
                let app = try decoder.string("app")
                let from = try requiredResolvedPointerTarget("from", in: params, defaultApp: app)
                let to = try requiredResolvedPointerTarget("to", in: params, defaultApp: app)
                observations?.beginDrag(fromHandle: from.target.handle, toHandle: to.target.handle)
                let result = try services.actions.drag(
                    from.target,
                    to.target,
                    app,
                    try decoder.int("durationMs"),
                    policy
                )
                return observed(withTargetResolutions(
                    withLocationResolutions(result, resolutions: [from.locationResolution, to.locationResolution]),
                    resolutions: [from.targetResolution, to.targetResolution]
                ))
            }
        default:
            return JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }
    }

    /// Closes the observation as soon as the primitive returns. Only a dispatch that actually
    /// succeeded describes a transition; a refusal changed nothing and gets no post-action read.
    private func observed(_ result: PrimitiveActionResult) -> PrimitiveActionResult {
        observations?.finish(success: result.success)
        return result
    }

    private func resolveElementTarget(_ target: ToolTarget) throws -> ResolvedElementTarget {
        switch target {
        case let .semanticName(app, name):
            let query = SemanticTargetQuery(app: app, name: name)
            let record: SemanticNameRecord
            switch services.semanticNameRegistry.lookup(app: app, name: name) {
            case let .unique(found): record = found
            case .missing: throw SemanticResolutionFailure(status: "missing", query: query, candidates: [])
            case let .ambiguous(_, candidates):
                throw SemanticResolutionFailure(status: "ambiguous", query: query, candidates: candidates)
            }
            let resolution = try services.resolveLocator(
                locatorResolutionApp(for: record, callerApp: app),
                record.locator,
                true
            )
            guard resolution.status == .unique, let handle = resolution.best?.handle else {
                throw LocatorResolutionFailure(resolution: resolution)
            }
            return ResolvedElementTarget(handle: handle.rawValue, resolution: resolution)
        case .point:
            throw JSONRPCError.invalidParams("target does not accept point targets; accepted target kind: semanticName")
        case .textLocation:
            throw JSONRPCError.invalidParams("target does not accept textLocation targets; accepted target kind: semanticName")
        }
    }

    private func requiredResolvedPointerTarget(
        _ key: String,
        in params: [String: JSONValue],
        defaultApp: String? = nil
    ) throws -> ResolvedPointerTarget {
        try resolvedPointerTarget(
            from: CommandRouterRequestSupport.requiredToolTarget(key, in: params, acceptedKinds: .pointer),
            defaultApp: defaultApp,
            fieldName: key
        )
    }

    private func optionalResolvedPointerTarget(_ key: String, in params: [String: JSONValue]) throws -> ResolvedPointerTarget? {
        guard let target = try CommandRouterRequestSupport.optionalToolTarget(key, in: params, acceptedKinds: .pointer) else {
            return nil
        }
        return try resolvedPointerTarget(from: target, fieldName: key)
    }

    private func resolvedPointerTarget(
        from target: ToolTarget,
        defaultApp: String? = nil,
        fieldName: String = "target"
    ) throws -> ResolvedPointerTarget {
        switch target {
        case let .semanticName(app, name):
            let resolved = try resolveElementTarget(.semanticName(app: app, name: name))
            return ResolvedPointerTarget(
                target: .handle(resolved.handle),
                locationResolution: nil,
                targetResolution: resolved.resolution
            )
        case let .point(point):
            return ResolvedPointerTarget(
                target: .point(try screenPoint(for: point, defaultApp: defaultApp, fieldName: fieldName)),
                locationResolution: nil,
                targetResolution: nil
            )
        case let .textLocation(location):
            let resolution = try resolveTextLocationTarget(location)
            return ResolvedPointerTarget(
                target: .point(resolution.point),
                locationResolution: resolution,
                targetResolution: nil
            )
        }
    }

    private func screenPoint(for point: ActionPoint, defaultApp: String?, fieldName: String) throws -> ActionPoint {
        switch point.coordinateSpace {
        case .screen, .legacyScreen:
            return point
        case .window, .screenshot:
            let app = point.app ?? defaultApp
            guard let app, !app.isEmpty else {
                throw JSONRPCError.invalidParams("\(fieldName) point coordinateSpace \(point.coordinateSpace.rawValue) requires app")
            }
            let snapshot = try services.captureSnapshot(app, point.coordinateSpace == .screenshot)
            guard let windowFrame = snapshot.windows.compactMap(\.frame).first else {
                throw JSONRPCError.invalidParams("\(fieldName) point coordinateSpace \(point.coordinateSpace.rawValue) requires a captured window frame")
            }
            let screenX: Double
            let screenY: Double
            switch point.coordinateSpace {
            case .window:
                screenX = windowFrame.x + point.x
                screenY = windowFrame.y + point.y
            case .screenshot:
                guard let screenshot = snapshot.screenshot else {
                    throw JSONRPCError.invalidParams("\(fieldName) point coordinateSpace screenshot requires a screenshot capture")
                }
                screenX = windowFrame.x + point.x / Double(screenshot.width) * windowFrame.width
                screenY = windowFrame.y + point.y / Double(screenshot.height) * windowFrame.height
            case .screen, .legacyScreen:
                fatalError("handled before conversion")
            }
            return ActionPoint(x: screenX, y: screenY, coordinateSpace: .screen, app: app)
        }
    }

    private func resolveTextLocationTarget(_ target: TextLocationTarget) throws -> TextLocationResolvedPoint {
        let resolution: TextLocationResolution
        switch target.source {
        case .ax, .screenshot:
            let snapshot = try services.captureSnapshot(target.app, target.source == .screenshot)
            resolution = TextLocationResolver(recognizeText: services.recognizeText).resolve(target, in: snapshot)
        case .auto:
            let axSnapshot = try services.captureSnapshot(target.app, false)
            let axResolution = TextLocationResolver(recognizeText: services.recognizeText).resolve(target, in: axSnapshot)
            if axResolution.status != .missing {
                resolution = axResolution
            } else {
                let screenshotSnapshot = try services.captureSnapshot(target.app, true)
                resolution = TextLocationResolver(recognizeText: services.recognizeText).resolve(target, in: screenshotSnapshot)
            }
        }
        guard resolution.status == .unique, let point = resolution.point else {
            throw JSONRPCError.invalidParams(textLocationFailureMessage(resolution, source: target.source))
        }
        return TextLocationResolvedPoint(point: point, resolution: resolution)
    }

    private func textLocationFailureMessage(_ resolution: TextLocationResolution, source: TextLocationSource) -> String {
        var message = "Text location did not resolve uniquely: \(resolution.status.rawValue)"
        guard !resolution.candidates.isEmpty else {
            if resolution.status == .missing {
                message += ". \(missingTextLocationGuidance(resolution, source: source))"
            }
            return message
        }

        let summaries = resolution.candidates.prefix(5).map { candidate in
            let matchedText = redactedTextLocationSummaryText(candidate)
            return "[\(candidate.index)] \(candidate.role) \"\(matchedText)\" frame=\(frameDescription(candidate.frame))"
        }
        message += " (\(resolution.candidates.count) candidates: \(summaries.joined(separator: "; "))"
        if resolution.candidates.count > summaries.count {
            message += "; ..."
        }
        message += ")"
        return message
    }

    /// Explains a missing text location in terms of the source the caller actually asked
    /// for. The costly mistake this exists to prevent is a caller reading a bare `missing`
    /// from `source: "ax"` and concluding the text is not on screen, when what happened is
    /// that the text renders inside nodes accessibility describes with nothing at all and
    /// `ax` — unlike `auto` — does not fall back to OCR.
    private func missingTextLocationGuidance(_ resolution: TextLocationResolution, source: TextLocationSource) -> String {
        switch source {
        case .ax where resolution.opaqueNodeCount > 0:
            return """
            No AX text matched, and \(resolution.opaqueNodeCount) visible \
            \(resolution.opaqueNodeCount == 1 ? "node carries" : "nodes carry") no text in any attribute \
            AX matching reads, so the target may be rendered inside them. \
            source:'ax' does not fall back; retry with source:'screenshot' or the default source:'auto' \
            to match by screenshot OCR.
            """
        case .ax:
            return """
            Every visible node carries text in an attribute AX matching reads and none of it matched, \
            so this text is absent from accessibility rather than hidden inside nodes AX cannot read. \
            source:'ax' does not fall back; retry with source:'screenshot' or the default source:'auto' \
            to match by screenshot OCR.
            """
        case .screenshot:
            return "Screenshot OCR recognized no matching text. source:'screenshot' does not fall back to accessibility text."
        case .auto:
            return "source:'auto' tried accessibility text and then screenshot OCR; neither matched, so no other source remains to retry."
        }
    }

    private func redactedTextLocationSummaryText(_ candidate: TextLocationCandidate) -> String {
        if let active = activeSecretRedactor().redaction(for: candidate.matchedText) {
            return active.value
        }
        if let deterministic = DeterministicRedactor.standard.redaction(
            for: "value",
            value: candidate.matchedText,
            context: DeterministicRedactionContext(
                role: candidate.role,
                title: candidate.matchedText,
                value: candidate.matchedText
            )
        ) {
            return deterministic.value
        }
        return candidate.matchedText
    }

    private func frameDescription(_ frame: AXFrame) -> String {
        "{x:\(formatNumber(frame.x)),y:\(formatNumber(frame.y)),width:\(formatNumber(frame.width)),height:\(formatNumber(frame.height))}"
    }

    private func formatNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private func withLocationResolution(
        _ result: PrimitiveActionResult,
        resolution resolved: TextLocationResolvedPoint?
    ) -> PrimitiveActionResult {
        guard let resolved else {
            return result
        }
        return withLocationResolutions(result, resolutions: [resolved])
    }

    private func withLocationResolutions(
        _ result: PrimitiveActionResult,
        resolutions: [TextLocationResolvedPoint?]
    ) -> PrimitiveActionResult {
        let activeSecretRedactor = activeSecretRedactor()
        let values = resolutions.compactMap { $0?.resolution.jsonValue(activeSecretRedactor: activeSecretRedactor) }
        guard !values.isEmpty else {
            return result
        }
        return result.withSuccess(result.success, details: ["locationResolutions": .array(values)])
    }

    private func withTargetResolution(
        _ result: PrimitiveActionResult,
        resolution: LocatorResolution?
    ) -> PrimitiveActionResult {
        guard let resolution else { return result }
        return result.withSuccess(
            result.success,
            details: ["targetResolution": compactTargetResolution(resolution)]
        )
    }

    private func withTargetResolutions(
        _ result: PrimitiveActionResult,
        resolutions: [LocatorResolution?]
    ) -> PrimitiveActionResult {
        let values = resolutions.compactMap { resolution in
            resolution.map { compactTargetResolution($0) }
        }
        guard !values.isEmpty else { return result }
        return result.withSuccess(result.success, details: ["targetResolutions": .array(values)])
    }

    private func compactTargetResolution(_ resolution: LocatorResolution) -> JSONValue {
        let redacted = resolution.jsonValue(activeSecretRedactor: activeSecretRedactor())
        guard case let .object(full) = redacted else { return .null }

        var compact = [String: JSONValue]()
        for key in ["status", "confidence", "path", "context"] {
            if let value = full[key] { compact[key] = value }
        }
        if let bestValue = full["best"], case let .object(best) = bestValue {
            compact["observedLocator"] = best["observedLocator"]
            if let evidenceValue = best["evidence"], case let .array(evidence) = evidenceValue {
                compact["evidence"] = .array(evidence.filter { item in
                    guard case let .object(fields) = item else { return true }
                    return fields["outcome"] != JSONValue.string("matched")
                })
            }
        }
        if resolution.status == .ambiguous {
            compact["candidates"] = full["candidates"]
        }
        return .object(compact)
    }

    private func actionResponse(id: JSONRPCID?, _ body: () throws -> PrimitiveActionResult) -> JSONRPCResponse {
        do {
            return JSONRPCResponse(id: id, result: ["action": try body().jsonValue])
        } catch let failure as LocatorResolutionFailure {
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(
                    code: -32602,
                    message: "Locator did not resolve uniquely: \(failure.resolution.status.rawValue)",
                    data: .object(["targetResolution": compactTargetResolution(failure.resolution)])
                )
            )
        } catch let failure as SemanticResolutionFailure {
            return JSONRPCResponse(id: id, error: JSONRPCError(
                code: -32602,
                message: "Semantic target did not resolve uniquely: \(failure.status)",
                data: .object(["targetResolution": failure.jsonValue(activeSecretRedactor: activeSecretRedactor())])
            ))
        } catch let error as JSONRPCError {
            return JSONRPCResponse(id: id, error: error)
        } catch let error as AXElementStoreError {
            return JSONRPCResponse(id: id, error: .invalidParams(error.description))
        } catch {
            return JSONRPCResponse(id: id, error: .internalError(String(describing: error)))
        }
    }

    private func activeSecretRedactor() -> ActiveSecretRedactor {
        ActiveSecretRedactor(filter: services.activeCredentialFilterProvider())
    }
}

private struct AxnRunCommandHandler {
    let services: CommandRouterServices
    let commandHandler: (JSONRPCRequest, ActionObservationCollector?) -> JSONRPCResponse
    let observationCollector: () -> ActionObservationCollector
    let historySessionID: String?

    func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        switch request.method {
        case "run":
            return runResponse(request)
        case "debug.create", "debug.start":
            return createDebugResponse(request)
        case "debug.step":
            return debugSessionResponse(id: request.id, request: request) { session in
                session.step()
            }
        case "debug.retry":
            return debugSessionResponse(id: request.id, request: request) { session in
                session.retryFailedAction()
            }
        case "debug.continue", "debug.resume":
            return debugSessionResponse(id: request.id, request: request) { session in
                session.continueUntilBreakpoint()
            }
        case "debug.runTo":
            do {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let blockID = try CommandRouterRequestSupport.requiredString("blockId", in: params)
                return debugSessionResponse(id: request.id, request: request) { session in
                    session.runToBlock(blockID)
                }
            } catch let error as JSONRPCError {
                return JSONRPCResponse(id: request.id, error: error)
            } catch {
                return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
            }
        case "debug.setBreakpoints":
            do {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let breakpoints = try ToolParamDecoder(toolName: request.method, params: params).stringArray("breakpoints")
                return debugSessionResponse(id: request.id, request: request) { session in
                    session.setBreakpoints(Set(breakpoints))
                }
            } catch let error as JSONRPCError {
                return JSONRPCResponse(id: request.id, error: error)
            } catch {
                return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
            }
        case "debug.stop":
            return debugSessionResponse(id: request.id, request: request, removeAfter: true) { session in
                session.stop()
            }
        default:
            return JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }
    }

    private func runResponse(_ request: JSONRPCRequest) -> JSONRPCResponse {
        do {
            let params = try CommandRouterRequestSupport.paramsObject(in: request)
            let runResult = try runner().run(params: params)
            // The socket result envelope key is externally visible through MCPRouter's
            // structuredContent path, so it remains "batch" for wire compatibility.
            return JSONRPCResponse(id: request.id, result: ["batch": runResult])
        } catch let error as AxnRunError {
            return JSONRPCResponse(id: request.id, error: .invalidParams(error.description))
        } catch {
            return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
        }
    }

    private func createDebugResponse(_ request: JSONRPCRequest) -> JSONRPCResponse {
        do {
            let params = try CommandRouterRequestSupport.paramsObject(in: request)
            let breakpoints = try ToolParamDecoder(toolName: request.method, params: params).stringArray("breakpoints")
            let session = try runner().debugSession(params: params, breakpoints: Set(breakpoints))
            services.debugSessions.insert(session)
            if request.method == "debug.start" {
                session.runUntilPause(before: try CommandRouterRequestSupport.optionalString("pauseBefore", in: params))
            }
            let status = session.status
            if isTerminalDebugStatus(status) {
                services.debugSessions.remove(id: session.id)
            }
            return JSONRPCResponse(id: request.id, result: ["debug": status])
        } catch let error as AxnRunError {
            return JSONRPCResponse(id: request.id, error: .invalidParams(error.description))
        } catch let error as JSONRPCError {
            return JSONRPCResponse(id: request.id, error: error)
        } catch {
            return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
        }
    }

    private func debugSessionResponse(
        id: JSONRPCID?,
        request: JSONRPCRequest,
        removeAfter: Bool = false,
        operation: (AxnDebugSession) -> JSONValue
    ) -> JSONRPCResponse {
        do {
            let params = try CommandRouterRequestSupport.paramsObject(in: request)
            let sessionID = try CommandRouterRequestSupport.requiredString("sessionId", in: params)
            guard let session = services.debugSessions.session(id: sessionID) else {
                return JSONRPCResponse(id: id, error: .invalidParams("unknown debug session: \(sessionID)"))
            }
            let status = operation(session)
            if removeAfter || isTerminalDebugStatus(status) {
                services.debugSessions.remove(id: sessionID)
            }
            return JSONRPCResponse(id: id, result: ["debug": status])
        } catch let error as JSONRPCError {
            return JSONRPCResponse(id: id, error: error)
        } catch {
            return JSONRPCResponse(id: id, error: .internalError(String(describing: error)))
        }
    }

    private func runner() -> AxnRunner {
        let credentialFilterProvider = services.activeCredentialFilterProvider
        // Actions replayed inside `run` are dispatched and recorded one at a time, so a single
        // collector reset per action carries that action's observation from dispatch to history.
        let collector = observationCollector()
        return AxnRunner(
            commandHandler: { childRequest in
                collector.reset()
                return commandHandler(childRequest, collector)
            },
            snapshotProvider: services.axnSnapshotProvider,
            replayTargetRegistrar: { app, name, locator in
                services.semanticNameRegistry.registerReplayEvidence(app: app, name: name, locator: locator)
            },
            actionRecorder: { childRequest, childResponse in
                guard let historySessionID else {
                    return
                }
                services.history.record(
                    request: childRequest,
                    response: childResponse,
                    sessionID: historySessionID,
                    observation: collector.observation,
                    semanticTargetLocator: { app, name in
                guard case let .unique(record) = services.semanticNameRegistry.lookup(app: app, name: name) else {
                    return nil
                }
                return record.locator
            },
                    activeSecretRedactor: activeSecretRedactor()
                )
            },
            activeSecretRedactorProvider: { ActiveSecretRedactor(filter: credentialFilterProvider()) }
        )
    }

    private func activeSecretRedactor() -> ActiveSecretRedactor {
        ActiveSecretRedactor(filter: services.activeCredentialFilterProvider())
    }

    private func isTerminalDebugStatus(_ status: JSONValue) -> Bool {
        switch status["state"] {
        case .string("completed"), .string("stopped"):
            return true
        default:
            return false
        }
    }
}

private struct HistoryCommandHandler {
    let services: CommandRouterServices

    func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        do {
            let params = try CommandRouterRequestSupport.paramsObject(in: request)
            let decoder = ToolParamDecoder(toolName: "save", params: params)
            let sessionID = try decoder.string("sessionId") ?? "default"
            let includeReads = try decoder.bool("includeReads") ?? false
            let from = try decoder.string("from")
            let to = try decoder.string("to")
            let exported = try services.history.exportScript(sessionID: sessionID, includeReads: includeReads, from: from, to: to)
            var result: [String: JSONValue] = [
                "script": .string(exported.script),
                "actionCount": .int(exported.actionCount),
                "recordCount": .int(exported.recordCount)
            ]
            if let path = try decoder.string("path") {
                try exported.script.write(toFile: path, atomically: true, encoding: .utf8)
                result["path"] = .string(path)
            }
            return JSONRPCResponse(id: request.id, result: result)
        } catch let error as ActionHistoryError {
            return JSONRPCResponse(id: request.id, error: .invalidParams(error.description))
        } catch let error as JSONRPCError {
            return JSONRPCResponse(id: request.id, error: error)
        } catch {
            return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
        }
    }
}

private enum CommandRouterRequestSupport {
    static func paramsObject(in request: JSONRPCRequest) throws -> [String: JSONValue] {
        guard let params = request.params, params != .null else {
            return [:]
        }
        guard case let .object(object) = params else {
            throw JSONRPCError.invalidParams("params must be an object")
        }
        return object
    }

    static func optionalString(_ key: String, in params: [String: JSONValue]) throws -> String? {
        guard let value = params[key], value != .null else {
            return nil
        }
        guard case let .string(string) = value else {
            throw JSONRPCError.invalidParams("\(key) must be a string")
        }
        return string
    }

    static func requiredString(_ key: String, in params: [String: JSONValue]) throws -> String {
        guard case let .string(value) = params[key] else {
            throw JSONRPCError.invalidParams("Missing string parameter: \(key)")
        }
        return value
    }

    static func requiredToolTarget(
        _ key: String,
        in params: [String: JSONValue],
        acceptedKinds: ToolTargetKindSet
    ) throws -> ToolTarget {
        guard let value = params[key], value != .null else {
            throw JSONRPCError.invalidParams("Missing target parameter: \(key)")
        }
        return try ToolTarget(jsonValue: value, acceptedKinds: acceptedKinds, fieldName: key)
    }

    static func optionalToolTarget(
        _ key: String,
        in params: [String: JSONValue],
        acceptedKinds: ToolTargetKindSet
    ) throws -> ToolTarget? {
        guard let value = params[key], value != .null else {
            return nil
        }
        return try ToolTarget(jsonValue: value, acceptedKinds: acceptedKinds, fieldName: key)
    }
}

public final class AxnDebugSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: AxnDebugSession] = [:]

    public init() {}

    public func insert(_ session: AxnDebugSession) {
        lock.withLock {
            sessions[session.id] = session
        }
    }

    public func session(id: String) -> AxnDebugSession? {
        lock.withLock {
            sessions[id]
        }
    }

    public func remove(id: String) {
        _ = lock.withLock {
            sessions.removeValue(forKey: id)
        }
    }
}

private struct WaitForValueRequest {
    static let defaultTimeoutMs = 5_000
    static let maxTimeoutMs = 60_000
    static let defaultIntervalMs = 100
    static let minIntervalMs = 10

    let app: String
    let name: String
    let predicate: WaitValuePredicate
    let timeoutMs: Int
    let intervalMs: Int

    init(params: [String: JSONValue]) throws {
        let target = try CommandRouterRequestSupport.requiredToolTarget("target", in: params, acceptedKinds: .element)
        guard case let .semanticName(app, name) = target else {
            throw JSONRPCError.invalidParams("target must be an app-scoped semantic name")
        }
        self.app = app
        self.name = name
        self.predicate = try Self.predicate(in: params)
        self.timeoutMs = try Self.boundedMilliseconds(
            "timeoutMs",
            in: params,
            defaultValue: Self.defaultTimeoutMs,
            minimum: 0,
            maximum: Self.maxTimeoutMs
        )
        self.intervalMs = try Self.boundedMilliseconds(
            "intervalMs",
            in: params,
            defaultValue: Self.defaultIntervalMs,
            minimum: Self.minIntervalMs,
            maximum: max(Self.minIntervalMs, self.timeoutMs == 0 ? Self.defaultIntervalMs : self.timeoutMs)
        )
    }

    private static func predicate(in params: [String: JSONValue]) throws -> WaitValuePredicate {
        var predicates: [WaitValuePredicate] = []
        if let contains = try optionalString("contains", in: params) {
            predicates.append(.contains(contains))
        }
        if let equals = try optionalString("equals", in: params) {
            predicates.append(.equals(equals))
        }
        if let matches = try optionalString("matches", in: params) {
            _ = try NSRegularExpression(pattern: matches)
            predicates.append(.matches(matches))
        }
        guard predicates.count == 1, let predicate = predicates.first else {
            throw JSONRPCError.invalidParams("wait_for_value requires exactly one of contains, equals, or matches")
        }
        return predicate
    }

    private static func optionalString(_ key: String, in params: [String: JSONValue]) throws -> String? {
        guard let value = params[key], value != .null else {
            return nil
        }
        guard case let .string(string) = value, !string.isEmpty else {
            throw JSONRPCError.invalidParams("\(key) must be a non-empty string")
        }
        return string
    }

    fileprivate static func boundedMilliseconds(
        _ key: String,
        in params: [String: JSONValue],
        defaultValue: Int,
        minimum: Int,
        maximum: Int
    ) throws -> Int {
        guard let value = params[key], value != .null else {
            return defaultValue
        }
        guard case let .int(milliseconds) = value else {
            throw JSONRPCError.invalidParams("\(key) must be an integer")
        }
        guard milliseconds >= minimum else {
            throw JSONRPCError.invalidParams("\(key) must be at least \(minimum)")
        }
        return min(milliseconds, maximum)
    }
}

private struct WaitForValueResult {
    let success: Bool
    let status: String
    let predicate: WaitValuePredicate
    let elapsedMs: Int
    let match: WaitValueMatch?
    let lastObserved: ReadableAXState?
    let resolution: LocatorResolution?
    let message: String

    func jsonValue(activeSecretRedactor: ActiveSecretRedactor) -> JSONValue {
        var object: [String: JSONValue] = [
            "success": .bool(success),
            "status": .string(status),
            "predicate": predicate.jsonValue,
            "elapsedMs": .int(elapsedMs),
            "message": .string(message),
            "matched": match?.jsonValue ?? .null,
            "lastObserved": lastObserved?.jsonValue ?? .null
        ]
        if let resolution {
            object["resolution"] = resolution.jsonValue(activeSecretRedactor: activeSecretRedactor)
        }
        return .object(object)
    }
}

private struct ResolvedPointerTarget {
    let target: PointerTarget
    let locationResolution: TextLocationResolvedPoint?
    let targetResolution: LocatorResolution?
}

private struct ResolvedElementTarget {
    let handle: String
    let resolution: LocatorResolution?
}

private struct LocatorResolutionFailure: Error {
    let resolution: LocatorResolution
}

private struct TextLocationResolvedPoint {
    let point: ActionPoint
    let resolution: TextLocationResolution
}

private extension JSONValue {
    func addingScreenText(
        _ items: [ScreenTextItem],
        includeScreenshot: Bool,
        activeSecretRedactor: ActiveSecretRedactor
    ) -> JSONValue {
        guard case var .object(object) = self else {
            return self
        }
        object["screenText"] = .array(items.map { item in
            item.jsonValue(activeSecretRedactor: activeSecretRedactor)
        })
        if !includeScreenshot {
            object["screenshot"] = .null
        }
        return .object(object)
    }

    func addingScreenshotUnavailable(
        requestedScreenshot: Bool,
        capturedScreenshot: EncodedScreenshot?
    ) -> JSONValue {
        guard requestedScreenshot, capturedScreenshot == nil, case var .object(object) = self else {
            return self
        }
        object["screenshotUnavailable"] = .object([
            "code": .string("capture-failed"),
            "reason": .string("ScreenCaptureKit did not return an encodable application window image")
        ])
        return .object(object)
    }

    func omittingScreenshotForActiveCredentialRedaction(
        requestedScreenshot: Bool,
        forceOmit: Bool = false
    ) -> JSONValue {
        guard requestedScreenshot,
              (forceOmit || containsActiveCredentialRedaction()),
              case var .object(object) = self,
              object["screenshot"] != nil,
              object["screenshot"] != .null
        else {
            return self
        }

        object["screenshot"] = .null
        var warnings: [JSONValue] = []
        if case let .array(existing)? = object["warnings"] {
            warnings = existing
        }
        let warning = JSONValue.string("screenshot omitted because active credential text was redacted")
        if !warnings.contains(warning) {
            warnings.append(warning)
        }
        object["warnings"] = .array(warnings)
        return .object(object)
    }
}

private extension Array where Element == ScreenTextItem {
    func containsActiveCredentialRedaction(activeSecretRedactor: ActiveSecretRedactor) -> Bool {
        JSONValue.array(map { $0.jsonValue(activeSecretRedactor: activeSecretRedactor) })
            .containsActiveCredentialRedaction()
    }
}
