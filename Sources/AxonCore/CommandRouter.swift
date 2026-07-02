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
    public let changeObserver: AppChangeObserving
    public let history: ActionHistoryStore
    public let recognizeText: TextRecognitionHandler
    public let activeCredentialFilterProvider: @Sendable () -> any ActiveCredentialFilter
    public let debugSessions: AxnDebugSessionStore
    public let readableAXState: ReadableAXStateProvider
    public let now: () -> Date
    public let sleepMilliseconds: (Int) -> Void

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
        changeObserver: AppChangeObserving = AXAppChangeObserverRegistry(),
        history: ActionHistoryStore = .shared,
        recognizeText: @escaping TextRecognitionHandler = VisionTextRecognizer.recognizeText(in:),
        activeCredentialFilter: any ActiveCredentialFilter = EmptyActiveCredentialFilter(),
        activeCredentialFilterProvider: (@Sendable () -> any ActiveCredentialFilter)? = nil,
        debugSessions: AxnDebugSessionStore = AxnDebugSessionStore(),
        readableAXState: ReadableAXStateProvider? = nil,
        now: @escaping () -> Date = Date.init,
        sleepMilliseconds: @escaping (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000) }
    ) {
        let defaultCaptureSnapshot: (String, Bool) throws -> AppSnapshot = captureSnapshot ?? { app, screenshot in
            try AXFullTreeCapturer(elementStore: elementStore).capture(app: app, screenshot: screenshot)
        }
        let liveLocatorResolver = AXLiveLocatorResolver(elementStore: elementStore)

        self.listApps = listApps
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
        self.now = now
        self.sleepMilliseconds = sleepMilliseconds
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
        changeObserver: AppChangeObserving = AXAppChangeObserverRegistry(),
        history: ActionHistoryStore = .shared,
        recognizeText: @escaping TextRecognitionHandler = VisionTextRecognizer.recognizeText(in:),
        activeCredentialFilter: any ActiveCredentialFilter = EmptyActiveCredentialFilter(),
        activeCredentialFilterProvider: (@Sendable () -> any ActiveCredentialFilter)? = nil,
        debugSessions: AxnDebugSessionStore = AxnDebugSessionStore(),
        readableAXState: CommandRouterServices.ReadableAXStateProvider? = nil,
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
            changeObserver: changeObserver,
            history: history,
            recognizeText: recognizeText,
            activeCredentialFilter: activeCredentialFilter,
            activeCredentialFilterProvider: activeCredentialFilterProvider,
            debugSessions: debugSessions,
            readableAXState: readableAXState,
            now: now,
            sleepMilliseconds: sleepMilliseconds
        ))
    }

    public func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let context = services.history.context(for: request)
        let response = handleCommand(context.request, historySessionID: context.sessionID)
        services.history.record(
            request: context.request,
            response: response,
            sessionID: context.sessionID,
            activeSecretRedactor: ActiveSecretRedactor(filter: services.activeCredentialFilterProvider())
        )
        return response
    }

    private func handleCommand(_ request: JSONRPCRequest, historySessionID: String? = nil) -> JSONRPCResponse {
        switch request.method {
        case "health", "permit":
            return SystemCommandHandler(services: services).handle(request)
        case "look", "find", "wait_for_value":
            return PerceptionCommandHandler(services: services).handle(request)
        case "click", "invoke", "type", "keyboard", "scroll", "drag":
            return PrimitiveActionCommandHandler(services: services).handle(request)
        case "run", "debug.create", "debug.start", "debug.step", "debug.retry", "debug.continue", "debug.resume", "debug.runTo", "debug.setBreakpoints", "debug.stop":
            return AxnRunCommandHandler(
                services: services,
                commandHandler: { handleCommand($0) },
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
            let doctor = Doctor.run()
            return JSONRPCResponse(
                id: request.id,
                result: [
                    "status": .string("ok"),
                    "service": .string("axon"),
                    "accessibility": .string(doctor.accessibility.status.rawValue)
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
        default:
            return JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
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
            guard let target = try decoder.string("target") ?? CommandRouterRequestSupport.optionalString("app", in: params) else {
                let format = try decoder.string("format")
                let includeAllApps = (try decoder.bool("all") ?? false) || format == "debug"
                return JSONRPCResponse(
                    id: request.id,
                    result: [
                        "apps": .array((includeAllApps ? services.listAllApps() : services.listApps()).map(\.jsonValue))
                    ]
                )
            }
            if (try? SnapshotHandle(target)) != nil {
                let offset = try decoder.int("offset") ?? 0
                let limit = try decoder.int("limit") ?? AXSnapshotCapturer.defaultMaxChildrenPerNode
                let direct = try decoder.bool("direct") ?? false
                let allDirectChildren = try decoder.bool("all") ?? false
                let children = try AXSnapshotCapturer(elementStore: services.elementStore).captureChildren(
                    parentHandle: target,
                    offset: offset,
                    limit: limit,
                    direct: direct,
                    allDirectChildren: allDirectChildren
                )
                return JSONRPCResponse(
                    id: request.id,
                    result: ["children": children.jsonValue(activeSecretRedactor: activeSecretRedactor)]
                )
            }
            let screenshot = try decoder.bool("screenshot") ?? false
            let screenText = try decoder.bool("screenText") ?? false
            let includeTree = try decoder.bool("tree") ?? true
            let childDepth = try decoder.int("childDepth")
            let snapshot = try services.captureSnapshotWithChildDepth(target, screenshot || screenText, childDepth)
            services.elementStore.store(summary: observedSummary(for: snapshot))
            var snapshotJSON = snapshot.jsonValue(
                includeTree: includeTree,
                activeSecretRedactor: activeSecretRedactor
            )
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
            let resolution = try services.resolveLocator(request.app, request.locator, false)
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

    func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        switch request.method {
        case "click":
            return actionResponse(id: request.id) {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let target = try CommandRouterRequestSupport.requiredToolTarget("target", in: params, acceptedKinds: .pointer)
                switch target {
                case let .point(point):
                    return try services.actions.clickPoint(point)
                case let .textLocation(location):
                    let resolution = try resolveTextLocationTarget(location)
                    return try withLocationResolution(services.actions.clickPoint(resolution.point), resolution: resolution)
                case .handle, .locator:
                    return try services.actions.click(resolveElementTarget(target))
                }
            }
        case "invoke":
            return actionResponse(id: request.id) {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let decoder = ToolParamDecoder(toolName: "invoke", params: params)
                return try services.actions.invoke(
                    resolveElementTarget(try CommandRouterRequestSupport.requiredToolTarget("target", in: params, acceptedKinds: .element)),
                    try decoder.requiredString("name")
                )
            }
        case "type":
            return actionResponse(id: request.id) {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let decoder = ToolParamDecoder(toolName: "type", params: params)
                return try services.actions.type(
                    resolveElementTarget(try CommandRouterRequestSupport.requiredToolTarget("target", in: params, acceptedKinds: .element)),
                    try decoder.requiredString("value")
                )
            }
        case "keyboard":
            return actionResponse(id: request.id) {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let decoder = ToolParamDecoder(toolName: "keyboard", params: params)
                return try services.actions.keyboard(
                    try decoder.string("app"),
                    try decoder.requiredString("keys")
                )
            }
        case "scroll":
            return actionResponse(id: request.id) {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let decoder = ToolParamDecoder(toolName: "scroll", params: params)
                let target = try optionalResolvedPointerTarget("target", in: params)
                let result = try services.actions.scroll(
                    target?.target,
                    try decoder.string("app"),
                    try decoder.number("deltaX") ?? 0,
                    try decoder.number("deltaY") ?? -120
                )
                return withLocationResolution(result, resolution: target?.locationResolution)
            }
        case "drag":
            return actionResponse(id: request.id) {
                let params = try CommandRouterRequestSupport.paramsObject(in: request)
                let decoder = ToolParamDecoder(toolName: "drag", params: params)
                let from = try requiredResolvedPointerTarget("from", in: params)
                let to = try requiredResolvedPointerTarget("to", in: params)
                let result = try services.actions.drag(
                    from.target,
                    to.target,
                    try decoder.string("app"),
                    try decoder.int("durationMs")
                )
                return withLocationResolutions(result, resolutions: [from.locationResolution, to.locationResolution])
            }
        default:
            return JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }
    }

    private func resolveElementTarget(_ target: ToolTarget) throws -> String {
        switch target {
        case let .handle(handle):
            return handle
        case let .locator(app, locator):
            let resolution = try services.resolveLocator(app, locator, true)
            guard resolution.status == .unique, let handle = resolution.best?.handle else {
                throw JSONRPCError.invalidParams("Locator did not resolve uniquely: \(resolution.status.rawValue)")
            }
            return handle.rawValue
        case .point:
            throw JSONRPCError.invalidParams("target does not accept point targets; accepted target kinds: handle, locator")
        case .textLocation:
            throw JSONRPCError.invalidParams("target does not accept textLocation targets; accepted target kinds: handle, locator")
        }
    }

    private func requiredResolvedPointerTarget(_ key: String, in params: [String: JSONValue]) throws -> ResolvedPointerTarget {
        try resolvedPointerTarget(from: CommandRouterRequestSupport.requiredToolTarget(key, in: params, acceptedKinds: .pointer))
    }

    private func optionalResolvedPointerTarget(_ key: String, in params: [String: JSONValue]) throws -> ResolvedPointerTarget? {
        guard let target = try CommandRouterRequestSupport.optionalToolTarget(key, in: params, acceptedKinds: .pointer) else {
            return nil
        }
        return try resolvedPointerTarget(from: target)
    }

    private func resolvedPointerTarget(from target: ToolTarget) throws -> ResolvedPointerTarget {
        switch target {
        case let .handle(handle):
            return ResolvedPointerTarget(target: .handle(handle), locationResolution: nil)
        case let .locator(app, locator):
            let resolved = try resolveElementTarget(.locator(app: app, locator: locator))
            return ResolvedPointerTarget(target: .handle(resolved), locationResolution: nil)
        case let .point(point):
            return ResolvedPointerTarget(target: .point(point), locationResolution: nil)
        case let .textLocation(location):
            let resolution = try resolveTextLocationTarget(location)
            return ResolvedPointerTarget(target: .point(resolution.point), locationResolution: resolution)
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
            throw JSONRPCError.invalidParams(textLocationFailureMessage(resolution))
        }
        return TextLocationResolvedPoint(point: point, resolution: resolution)
    }

    private func textLocationFailureMessage(_ resolution: TextLocationResolution) -> String {
        var message = "Text location did not resolve uniquely: \(resolution.status.rawValue)"
        guard !resolution.candidates.isEmpty else {
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
        var details = result.details
        details["locationResolutions"] = .array(values)
        return PrimitiveActionResult(
            action: result.action,
            target: result.target,
            strategy: result.strategy,
            success: result.success,
            message: result.message,
            details: details
        )
    }

    private func actionResponse(id: JSONRPCID?, _ body: () throws -> PrimitiveActionResult) -> JSONRPCResponse {
        do {
            return JSONRPCResponse(id: id, result: ["action": try body().jsonValue])
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
    let commandHandler: (JSONRPCRequest) -> JSONRPCResponse
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
        return AxnRunner(
            commandHandler: commandHandler,
            snapshotProvider: services.axnSnapshotProvider,
            actionRecorder: { childRequest, childResponse in
                guard let historySessionID else {
                    return
                }
                services.history.record(
                    request: childRequest,
                    response: childResponse,
                    sessionID: historySessionID,
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
    let locator: AXLocator
    let predicate: WaitValuePredicate
    let timeoutMs: Int
    let intervalMs: Int

    init(params: [String: JSONValue]) throws {
        let target = try CommandRouterRequestSupport.requiredToolTarget("target", in: params, acceptedKinds: .locator)
        guard case let .locator(app, locator) = target else {
            throw JSONRPCError.invalidParams("target must be a locator target")
        }
        self.app = app
        self.locator = locator
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

    private static func boundedMilliseconds(
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
