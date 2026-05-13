public struct CommandRouter {
    private let listApps: () -> [AppIdentity]
    private let captureSnapshot: (String, Bool) throws -> AppSnapshot
    private let captureScreenshot: (String) throws -> EncodedScreenshot?
    private let requestAccessibility: () -> Bool
    private let actions: PrimitiveActionHandlers
    private let elementStore: AXElementStore
    private let changeObserver: AppChangeObserving
    private let history: ActionHistoryStore
    private let recognizeText: TextRecognitionHandler

    public init(
        listApps: @escaping () -> [AppIdentity] = { AppResolver().runningApps() },
        captureSnapshot: ((String, Bool) throws -> AppSnapshot)? = nil,
        captureScreenshot: ((String) throws -> EncodedScreenshot?)? = nil,
        requestAccessibility: @escaping () -> Bool = AccessibilityPermission.requestTrustPrompt,
        actions: PrimitiveActionHandlers? = nil,
        elementStore: AXElementStore = AXElementStore(),
        changeObserver: AppChangeObserving = AXAppChangeObserverRegistry(),
        history: ActionHistoryStore = .shared,
        recognizeText: @escaping TextRecognitionHandler = VisionTextRecognizer.recognizeText(in:)
    ) {
        self.elementStore = elementStore
        self.changeObserver = changeObserver
        self.history = history
        self.recognizeText = recognizeText
        self.listApps = listApps
        self.captureSnapshot = captureSnapshot ?? { app, screenshot in
            try AXSnapshotCapturer(elementStore: elementStore).capture(app: app, screenshot: screenshot)
        }
        self.captureScreenshot = captureScreenshot ?? { app in
            let identity = try AppResolver().resolveIdentity(app)
            return ScreenshotCapturer().capture(app: identity)
        }
        self.requestAccessibility = requestAccessibility
        self.actions = actions ?? AXPrimitiveActionExecutor(elementStore: elementStore).handlers()
    }

    public func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let context = history.context(for: request)
        let response = handleCommand(context.request)
        history.record(request: context.request, response: response, sessionID: context.sessionID)
        return response
    }

    private func handleCommand(_ request: JSONRPCRequest) -> JSONRPCResponse {
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
        case "request_accessibility":
            let trusted = requestAccessibility()
            return JSONRPCResponse(
                id: request.id,
                result: [
                    "accessibility": .string(trusted ? PermissionStatus.trusted.rawValue : PermissionStatus.denied.rawValue),
                    "prompted": .bool(true)
                ]
            )
        case "list_apps":
            return JSONRPCResponse(
                id: request.id,
                result: [
                    "apps": .array(listApps().map(\.jsonValue))
                ]
            )
        case "snapshot":
            do {
                let app = try requiredStringParam("app", in: request)
                let screenshot = boolParam("screenshot", in: request) ?? false
                let screenText = boolParam("screenText", in: request) ?? false
                let includeTree = boolParam("includeTree", in: request) ?? true
                let sensitive = boolParam("sensitive", in: request) ?? false
                if sensitive && screenshot {
                    throw JSONRPCError.invalidParams("sensitive snapshots cannot include screenshots")
                }
                if sensitive && screenText {
                    throw JSONRPCError.invalidParams("sensitive snapshots cannot include screenText")
                }
                let snapshot = try captureSnapshot(app, screenshot || screenText)
                elementStore.store(summary: observedSummary(for: snapshot))
                var snapshotJSON = snapshot.jsonValue(includeTree: includeTree, sensitive: sensitive)
                if screenText {
                    snapshotJSON = snapshotJSON.addingScreenText(
                        ScreenTextExtractor(recognizeText: recognizeText).extract(in: snapshot),
                        includeScreenshot: screenshot
                    )
                }
                return JSONRPCResponse(
                    id: request.id,
                    result: [
                        "snapshot": snapshotJSON
                    ]
                )
            } catch let error as JSONRPCError {
                return JSONRPCResponse(id: request.id, error: error)
            } catch {
                return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
            }
        case "screenshot":
            do {
                let app = try requiredStringParam("app", in: request)
                return JSONRPCResponse(
                    id: request.id,
                    result: [
                        "screenshot": try captureScreenshot(app).map(\.jsonValue) ?? .null
                    ]
                )
            } catch let error as JSONRPCError {
                return JSONRPCResponse(id: request.id, error: error)
            } catch {
                return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
            }
        case "get_children":
            do {
                let params = try paramsObject(in: request)
                let target = try requiredString("target", in: params)
                let offset = intParam("offset", in: params) ?? 0
                let limit = intParam("limit", in: params) ?? AXSnapshotCapturer.defaultMaxChildrenPerNode
                let children = try AXSnapshotCapturer(elementStore: elementStore).captureChildren(
                    parentHandle: target,
                    offset: offset,
                    limit: limit
                )
                return JSONRPCResponse(id: request.id, result: ["children": children.jsonValue])
            } catch let error as JSONRPCError {
                return JSONRPCResponse(id: request.id, error: error)
            } catch let error as AXElementStoreError {
                return JSONRPCResponse(id: request.id, error: .invalidParams(error.description))
            } catch {
                return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
            }
        case "changed_since":
            do {
                let snapshotID = SnapshotID(try requiredStringParam("snapshotId", in: request))
                let sensitive = boolParam("sensitive", in: request) ?? false
                let previous = try elementStore.summary(for: snapshotID)
                let observedChanges = observedChanges(since: previous)
                let currentSnapshot = try captureSnapshot(previous.appQuery, false)
                let current = observedSummary(for: currentSnapshot)
                elementStore.store(summary: current)
                let change = previous.change(comparedTo: current)
                var result: [String: JSONValue] = [
                    "changed": .bool(change.changed),
                    "reason": .string(change.reason),
                    "snapshotId": .string(previous.id.rawValue),
                    "currentSnapshotId": .string(current.id.rawValue),
                    "previous": previous.jsonValue(sensitive: sensitive),
                    "current": current.jsonValue(sensitive: sensitive)
                ]
                if !observedChanges.isEmpty {
                    result["observedChanges"] = .array(observedChanges.map(\.jsonValue))
                }
                return JSONRPCResponse(
                    id: request.id,
                    result: result
                )
            } catch let error as JSONRPCError {
                return JSONRPCResponse(id: request.id, error: error)
            } catch let error as AXElementStoreError {
                return JSONRPCResponse(id: request.id, error: .invalidParams(error.description))
            } catch AppResolverError.notFound {
                do {
                    let snapshotID = SnapshotID(try requiredStringParam("snapshotId", in: request))
                    let sensitive = boolParam("sensitive", in: request) ?? false
                    let previous = try elementStore.summary(for: snapshotID)
                    return JSONRPCResponse(
                        id: request.id,
                        result: [
                            "changed": .bool(true),
                            "reason": .string("app_missing"),
                            "snapshotId": .string(previous.id.rawValue),
                            "currentSnapshotId": .null,
                            "previous": previous.jsonValue(sensitive: sensitive),
                            "current": .null
                        ]
                    )
                } catch {
                    return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
                }
            } catch {
                return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
            }
        case "run_batch":
            do {
                let params = try paramsObject(in: request)
                let batch = try ActionBatchExecutor(commandHandler: handle).run(params: params)
                return JSONRPCResponse(id: request.id, result: ["batch": batch])
            } catch let error as ActionBatchError {
                return JSONRPCResponse(id: request.id, error: .invalidParams(error.description))
            } catch {
                return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
            }
        case "export_script":
            do {
                let params = try paramsObject(in: request)
                let sessionID = try optionalStringParam("sessionId", in: params) ?? "default"
                let includeReads = boolParam("includeReads", in: request) ?? false
                let from = try optionalStringParam("from", in: params)
                let to = try optionalStringParam("to", in: params)
                let exported = try history.exportScript(sessionID: sessionID, includeReads: includeReads, from: from, to: to)
                var result: [String: JSONValue] = [
                    "script": .string(exported.script),
                    "actionCount": .int(exported.actionCount),
                    "recordCount": .int(exported.recordCount)
                ]
                if let path = try optionalStringParam("path", in: params) {
                    try exported.script.write(toFile: path, atomically: true, encoding: .utf8)
                    result["path"] = .string(path)
                }
                return JSONRPCResponse(id: request.id, result: result)
            } catch let error as JSONRPCError {
                return JSONRPCResponse(id: request.id, error: error)
            } catch {
                return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
            }
        case "resolve":
            do {
                let app = try requiredStringParam("app", in: request)
                let locator = try requiredLocatorParam(in: request)
                let snapshot = try captureSnapshot(app, false)
                let resolution = LocatorResolver().resolve(locator, in: snapshot)
                return JSONRPCResponse(
                    id: request.id,
                    result: [
                        "resolution": resolution.jsonValue
                    ]
                )
            } catch let error as JSONRPCError {
                return JSONRPCResponse(id: request.id, error: error)
            } catch {
                return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
            }
        case "click":
            return actionResponse(id: request.id) {
                let params = try paramsObject(in: request)
                if let target = params["target"], let point = try pointTarget(from: target) {
                    return try actions.clickPoint(point)
                }
                if let target = params["target"], let location = try textLocationTarget(from: target) {
                    let resolution = try resolveTextLocationTarget(location)
                    return try withLocationResolution(actions.clickPoint(resolution.point), resolution: resolution)
                }
                return try actions.click(resolveTargetParam(in: request))
            }
        case "perform_action":
            return actionResponse(id: request.id) {
                try actions.performAction(
                    resolveTargetParam(in: request),
                    requiredStringParam("action", in: request)
                )
            }
        case "set_value":
            return actionResponse(id: request.id) {
                try actions.setValue(
                    resolveTargetParam(in: request),
                    requiredStringParam("value", in: request)
                )
            }
        case "type_text":
            return actionResponse(id: request.id) {
                try actions.typeText(
                    requiredStringParam("app", in: request),
                    requiredStringParam("text", in: request)
                )
            }
        case "press_key":
            return actionResponse(id: request.id) {
                try actions.pressKey(
                    requiredStringParam("app", in: request),
                    requiredStringParam("key", in: request)
                )
            }
        case "scroll":
            return actionResponse(id: request.id) {
                let params = try paramsObject(in: request)
                let target = try optionalResolvedPointerTarget("target", in: params)
                let result = try actions.scroll(
                    target?.target,
                    optionalStringParam("app", in: params),
                    doubleParam("deltaX", in: params) ?? 0,
                    doubleParam("deltaY", in: params) ?? -120
                )
                return withLocationResolution(result, resolution: target?.locationResolution)
            }
        case "drag":
            return actionResponse(id: request.id) {
                let params = try paramsObject(in: request)
                let from = try requiredResolvedPointerTarget("from", in: params)
                let to = try requiredResolvedPointerTarget("to", in: params)
                let result = try actions.drag(
                    from.target,
                    to.target,
                    optionalStringParam("app", in: params),
                    intParam("durationMs", in: params)
                )
                return withLocationResolutions(result, resolutions: [from.locationResolution, to.locationResolution])
            }
        default:
            return JSONRPCResponse(
                id: request.id,
                error: JSONRPCError.methodNotFound(request.method)
            )
        }
    }

    private func paramsObject(in request: JSONRPCRequest) throws -> [String: JSONValue] {
        guard case let .object(params) = request.params else {
            throw JSONRPCError.invalidParams("params must be an object")
        }
        return params
    }

    private func requiredStringParam(_ key: String, in request: JSONRPCRequest) throws -> String {
        let params = try paramsObject(in: request)
        guard case let .string(value) = params[key] else {
            throw JSONRPCError.invalidParams("Missing string parameter: \(key)")
        }
        return value
    }

    private func optionalStringParam(_ key: String, in params: [String: JSONValue]) throws -> String? {
        guard let value = params[key], value != .null else {
            return nil
        }
        guard case let .string(string) = value else {
            throw JSONRPCError.invalidParams("\(key) must be a string")
        }
        return string
    }

    private func requiredString(_ key: String, in params: [String: JSONValue]) throws -> String {
        guard case let .string(value) = params[key] else {
            throw JSONRPCError.invalidParams("Missing string parameter: \(key)")
        }
        return value
    }

    private func requiredLocatorParam(in request: JSONRPCRequest) throws -> AXLocator {
        let params = try paramsObject(in: request)
        guard let locator = params["locator"] else {
            throw JSONRPCError.invalidParams("Missing locator parameter")
        }
        return try AXLocator(jsonValue: locator)
    }

    private func resolveTargetParam(in request: JSONRPCRequest) throws -> String {
        let params = try paramsObject(in: request)
        guard let target = params["target"] else {
            throw JSONRPCError.invalidParams("Missing target parameter")
        }

        if case let .string(handle) = target {
            return handle
        }
        return try resolveLocatorTarget(target)
    }

    private func requiredResolvedPointerTarget(_ key: String, in params: [String: JSONValue]) throws -> ResolvedPointerTarget {
        guard let value = params[key] else {
            throw JSONRPCError.invalidParams("Missing target parameter: \(key)")
        }
        return try resolvedPointerTarget(from: value)
    }

    private func optionalResolvedPointerTarget(_ key: String, in params: [String: JSONValue]) throws -> ResolvedPointerTarget? {
        guard let value = params[key], value != .null else {
            return nil
        }
        return try resolvedPointerTarget(from: value)
    }

    private func resolvedPointerTarget(from value: JSONValue) throws -> ResolvedPointerTarget {
        if case let .string(handle) = value {
            return ResolvedPointerTarget(target: .handle(handle), locationResolution: nil)
        }
        if let point = try pointTarget(from: value) {
            return ResolvedPointerTarget(target: .point(point), locationResolution: nil)
        }
        if let location = try textLocationTarget(from: value) {
            let resolution = try resolveTextLocationTarget(location)
            return ResolvedPointerTarget(target: .point(resolution.point), locationResolution: resolution)
        }
        return ResolvedPointerTarget(target: .handle(try resolveLocatorTarget(value)), locationResolution: nil)
    }

    private func pointTarget(from value: JSONValue) throws -> ActionPoint? {
        guard case let .object(object) = value else {
            return nil
        }
        if let point = object["point"] {
            return try pointValue(point)
        }
        if object["x"] != nil || object["y"] != nil {
            return try pointValue(value)
        }
        return nil
    }

    private func pointValue(_ value: JSONValue) throws -> ActionPoint {
        guard case let .object(object) = value else {
            throw JSONRPCError.invalidParams("point must be an object")
        }
        guard let x = numericValue("x", in: object), let y = numericValue("y", in: object) else {
            throw JSONRPCError.invalidParams("point requires numeric x and y")
        }
        return ActionPoint(x: x, y: y)
    }

    private func textLocationTarget(from value: JSONValue) throws -> TextLocationTarget? {
        guard case let .object(object) = value, let location = object["location"] else {
            return nil
        }
        return try TextLocationTarget(jsonValue: location)
    }

    private func resolveTextLocationTarget(_ target: TextLocationTarget) throws -> TextLocationResolvedPoint {
        let resolution: TextLocationResolution
        switch target.source {
        case .ax, .screenshot:
            let snapshot = try captureSnapshot(target.app, target.source == .screenshot)
            resolution = TextLocationResolver(recognizeText: recognizeText).resolve(target, in: snapshot)
        case .auto:
            let axSnapshot = try captureSnapshot(target.app, false)
            let axResolution = TextLocationResolver(recognizeText: recognizeText).resolve(target, in: axSnapshot)
            if axResolution.status != .missing {
                resolution = axResolution
            } else {
                let screenshotSnapshot = try captureSnapshot(target.app, true)
                resolution = TextLocationResolver(recognizeText: recognizeText).resolve(target, in: screenshotSnapshot)
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
            "[\(candidate.index)] \(candidate.role) \"\(candidate.matchedText)\" frame=\(frameDescription(candidate.frame))"
        }
        message += " (\(resolution.candidates.count) candidates: \(summaries.joined(separator: "; "))"
        if resolution.candidates.count > summaries.count {
            message += "; ..."
        }
        message += ")"
        return message
    }

    private func frameDescription(_ frame: AXFrame) -> String {
        "{x:\(formatNumber(frame.x)),y:\(formatNumber(frame.y)),width:\(formatNumber(frame.width)),height:\(formatNumber(frame.height))}"
    }

    private func formatNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private func resolveLocatorTarget(_ target: JSONValue) throws -> String {
        guard case let .object(object) = target else {
            throw JSONRPCError.invalidParams("target must be a handle string, point object, or locator object")
        }
        guard case let .string(app) = object["app"] else {
            throw JSONRPCError.invalidParams("Locator target must include string app")
        }
        guard let locatorValue = object["locator"] else {
            throw JSONRPCError.invalidParams("Locator target must include locator")
        }

        let locator = try AXLocator(jsonValue: locatorValue)
        let snapshot = try captureSnapshot(app, false)
        let resolution = LocatorResolver().resolve(locator, in: snapshot)
        guard resolution.status == .unique, let handle = resolution.best?.handle else {
            throw JSONRPCError.invalidParams("Locator did not resolve uniquely: \(resolution.status.rawValue)")
        }
        return handle.rawValue
    }

    private func boolParam(_ key: String, in request: JSONRPCRequest) -> Bool? {
        guard case let .object(params) = request.params, case let .bool(value) = params[key] else {
            return nil
        }
        return value
    }

    private func doubleParam(_ key: String, in params: [String: JSONValue]) -> Double? {
        numericValue(key, in: params)
    }

    private func intParam(_ key: String, in params: [String: JSONValue]) -> Int? {
        guard case let .int(value) = params[key] else {
            return nil
        }
        return value
    }

    private func numericValue(_ key: String, in params: [String: JSONValue]) -> Double? {
        switch params[key] {
        case let .double(value):
            return value
        case let .int(value):
            return Double(value)
        default:
            return nil
        }
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
        let values = resolutions.compactMap { $0?.resolution.jsonValue }
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

    private func observedSummary(for snapshot: AppSnapshot) -> SnapshotSummary {
        changeObserver.startObserving(app: snapshot.app)
        return SnapshotSummary(snapshot: snapshot, observationToken: changeObserver.token(for: snapshot.app))
    }

    private func observedChanges(since previous: SnapshotSummary) -> [ObservedAppChange] {
        guard let token = previous.observationToken else {
            return []
        }
        return changeObserver.changes(since: token, app: previous.app)
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
    func addingScreenText(_ items: [ScreenTextItem], includeScreenshot: Bool) -> JSONValue {
        guard case var .object(object) = self else {
            return self
        }
        object["screenText"] = .array(items.map(\.jsonValue))
        if !includeScreenshot {
            object["screenshot"] = .null
        }
        return .object(object)
    }
}
