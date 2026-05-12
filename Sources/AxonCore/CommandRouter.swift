public struct CommandRouter {
    private let listApps: () -> [AppIdentity]
    private let captureSnapshot: (String, Bool) throws -> AppSnapshot
    private let captureScreenshot: (String) throws -> EncodedScreenshot?
    private let actions: PrimitiveActionHandlers

    public init(
        listApps: @escaping () -> [AppIdentity] = { AppResolver().runningApps() },
        captureSnapshot: ((String, Bool) throws -> AppSnapshot)? = nil,
        captureScreenshot: ((String) throws -> EncodedScreenshot?)? = nil,
        actions: PrimitiveActionHandlers? = nil,
        elementStore: AXElementStore = AXElementStore()
    ) {
        self.listApps = listApps
        self.captureSnapshot = captureSnapshot ?? { app, includeScreenshot in
            try AXSnapshotCapturer(elementStore: elementStore).capture(app: app, includeScreenshot: includeScreenshot)
        }
        self.captureScreenshot = captureScreenshot ?? { app in
            let identity = try AppResolver().resolveIdentity(app)
            return ScreenshotCapturer().capture(app: identity)
        }
        self.actions = actions ?? AXPrimitiveActionExecutor(elementStore: elementStore).handlers()
    }

    public func handle(_ request: JSONRPCRequest) -> JSONRPCResponse {
        switch request.method {
        case "health":
            return JSONRPCResponse(
                id: request.id,
                result: [
                    "status": .string("ok"),
                    "service": .string("axon")
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
                let snapshot = try captureSnapshot(app, includeScreenshot)
                return JSONRPCResponse(
                    id: request.id,
                    result: [
                        "snapshot": snapshot.jsonValue
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
        case "click":
            return actionResponse(id: request.id) {
                try actions.click(requiredStringParam("target", in: request))
            }
        case "perform_action":
            return actionResponse(id: request.id) {
                try actions.performAction(
                    requiredStringParam("target", in: request),
                    requiredStringParam("action", in: request)
                )
            }
        case "set_value":
            return actionResponse(id: request.id) {
                try actions.setValue(
                    requiredStringParam("target", in: request),
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

    private func requiredStringParam(_ key: String, in request: JSONRPCRequest) throws -> String {
        guard case let .object(params) = request.params, case let .string(value) = params[key] else {
            throw JSONRPCError.invalidParams("Missing string parameter: \(key)")
        }
        return value
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
        } catch {
            return JSONRPCResponse(id: id, error: .internalError(String(describing: error)))
        }
    }
}
