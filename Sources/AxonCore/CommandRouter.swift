public struct CommandRouter {
    public init() {}

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
        default:
            return JSONRPCResponse(
                id: request.id,
                error: JSONRPCError.methodNotFound(request.method)
            )
        }
    }
}

