public struct CommandRouter {
    private let listApps: () -> [AppIdentity]
    private let captureSnapshot: (String, Bool) throws -> AppSnapshot
    private let captureScreenshot: (String) throws -> EncodedScreenshot?
    private let requestAccessibility: () -> Bool
    private let actions: PrimitiveActionHandlers
    private let elementStore: AXElementStore

    public init(
        listApps: @escaping () -> [AppIdentity] = { AppResolver().runningApps() },
        captureSnapshot: ((String, Bool) throws -> AppSnapshot)? = nil,
        captureScreenshot: ((String) throws -> EncodedScreenshot?)? = nil,
        requestAccessibility: @escaping () -> Bool = AccessibilityPermission.requestTrustPrompt,
        actions: PrimitiveActionHandlers? = nil,
        elementStore: AXElementStore = AXElementStore()
    ) {
        self.elementStore = elementStore
        self.listApps = listApps
        self.captureSnapshot = captureSnapshot ?? { app, includeScreenshot in
            try AXSnapshotCapturer(elementStore: elementStore).capture(app: app, includeScreenshot: includeScreenshot)
        }
        self.captureScreenshot = captureScreenshot ?? { app in
            let identity = try AppResolver().resolveIdentity(app)
            return ScreenshotCapturer().capture(app: identity)
        }
        self.requestAccessibility = requestAccessibility
        self.actions = actions ?? AXPrimitiveActionExecutor(elementStore: elementStore).handlers()
    }

    public func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
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
                let includeScreenshot = boolParam("includeScreenshot", in: request) ?? true
                let includeTree = boolParam("includeTree", in: request) ?? true
                let snapshot = try captureSnapshot(app, includeScreenshot)
                elementStore.store(summary: SnapshotSummary(snapshot: snapshot))
                return JSONRPCResponse(
                    id: request.id,
                    result: [
                        "snapshot": snapshot.jsonValue(includeTree: includeTree)
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
        case "changed_since":
            do {
                let snapshotID = SnapshotID(try requiredStringParam("snapshotId", in: request))
                let previous = try elementStore.summary(for: snapshotID)
                let currentSnapshot = try captureSnapshot(previous.appQuery, false)
                let current = SnapshotSummary(snapshot: currentSnapshot)
                elementStore.store(summary: current)
                let change = previous.change(comparedTo: current)
                return JSONRPCResponse(
                    id: request.id,
                    result: [
                        "changed": .bool(change.changed),
                        "reason": .string(change.reason),
                        "snapshotId": .string(previous.id.rawValue),
                        "currentSnapshotId": .string(current.id.rawValue),
                        "previous": previous.jsonValue,
                        "current": current.jsonValue
                    ]
                )
            } catch let error as JSONRPCError {
                return JSONRPCResponse(id: request.id, error: error)
            } catch let error as AXElementStoreError {
                return JSONRPCResponse(id: request.id, error: .invalidParams(error.description))
            } catch AppResolverError.notFound {
                do {
                    let snapshotID = SnapshotID(try requiredStringParam("snapshotId", in: request))
                    let previous = try elementStore.summary(for: snapshotID)
                    return JSONRPCResponse(
                        id: request.id,
                        result: [
                            "changed": .bool(true),
                            "reason": .string("app_missing"),
                            "snapshotId": .string(previous.id.rawValue),
                            "currentSnapshotId": .null,
                            "previous": previous.jsonValue,
                            "current": .null
                        ]
                    )
                } catch {
                    return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
                }
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
                try actions.click(resolveTargetParam(in: request))
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

        guard case let .object(object) = target else {
            throw JSONRPCError.invalidParams("target must be a handle string or locator object")
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
}
