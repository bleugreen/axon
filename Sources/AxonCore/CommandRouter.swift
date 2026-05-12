public struct CommandRouter {
    private let listApps: () -> [AppIdentity]
    private let captureSnapshot: (String, Bool) throws -> AppSnapshot

    public init(
        listApps: @escaping () -> [AppIdentity] = { AppResolver().runningApps() },
        captureSnapshot: @escaping (String, Bool) throws -> AppSnapshot = { app, includeScreenshot in
            try AXSnapshotCapturer().capture(app: app, includeScreenshot: includeScreenshot)
        }
    ) {
        self.listApps = listApps
        self.captureSnapshot = captureSnapshot
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
                let snapshot = try captureSnapshot(app, true)
                return JSONRPCResponse(
                    id: request.id,
                    result: [
                        "screenshot": snapshot.screenshot.map(\.jsonValue) ?? .null
                    ]
                )
            } catch let error as JSONRPCError {
                return JSONRPCResponse(id: request.id, error: error)
            } catch {
                return JSONRPCResponse(id: request.id, error: .internalError(String(describing: error)))
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
}
