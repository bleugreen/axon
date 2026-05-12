import Foundation
import Testing
@testable import AxonCore

@Test func mcpLineProcessorReturnsOneJSONResponseLine() throws {
    let processor = MCPLineProcessor(router: MCPRouter(commandRouter: CommandRouter()))
    let request = JSONRPCRequest(id: .int(1), method: "ping")
    let line = try JSONEncoder().encode(request)

    let processed = try processor.process(line: line)
    let responseData = try #require(processed)
    let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData.dropLastNewline())

    #expect(response.id == .int(1))
    #expect(response.result != nil)
    #expect(responseData.last == 0x0A)
}

@Test func mcpLineProcessorDoesNotWriteNotificationResponses() throws {
    let processor = MCPLineProcessor(router: MCPRouter(commandRouter: CommandRouter()))
    let request = JSONRPCRequest(id: nil, method: "notifications/initialized")
    let line = try JSONEncoder().encode(request)

    let responseData = try processor.process(line: line)

    #expect(responseData == nil)
}

@Test func mcpLineProcessorReturnsParseErrorForInvalidJSON() throws {
    let processor = MCPLineProcessor(router: MCPRouter(commandRouter: CommandRouter()))

    let processed = try processor.process(line: Data("{".utf8))
    let responseData = try #require(processed)
    let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData.dropLastNewline())

    #expect(response.error?.code == -32700)
}

private extension Data {
    func dropLastNewline() -> Data {
        guard last == 0x0A else {
            return self
        }
        return dropLast()
    }
}
