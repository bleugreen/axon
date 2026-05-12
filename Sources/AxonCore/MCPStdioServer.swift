import Foundation

public struct MCPLineProcessor {
    private let router: MCPRouter
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(router: MCPRouter = MCPRouter()) {
        self.router = router
    }

    public func process(line: Data) throws -> Data? {
        let response: JSONRPCResponse?
        do {
            let request = try decoder.decode(JSONRPCRequest.self, from: line)
            response = router.handle(request)
        } catch {
            response = JSONRPCResponse(id: nil, error: .parseError(error.localizedDescription))
        }

        guard let response else {
            return nil
        }
        return try encoder.encode(response) + Data([0x0A])
    }
}

public struct MCPStdioServer {
    private let processor: MCPLineProcessor

    public init(router: MCPRouter = MCPRouter()) {
        self.processor = MCPLineProcessor(router: router)
    }

    public func run() throws {
        while let line = readLine(strippingNewline: true) {
            guard let response = try processor.process(line: Data(line.utf8)) else {
                continue
            }
            FileHandle.standardOutput.write(response)
        }
    }
}
