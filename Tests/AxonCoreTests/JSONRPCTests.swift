import Foundation
import Testing
@testable import AxonCore

@Test func healthRequestReturnsDaemonStatus() {
    let request = JSONRPCRequest(id: .string("health-1"), method: "health")

    let response = CommandRouter().handle(request)

    #expect(response.id == .string("health-1"))
    #expect(response.error == nil)
    #expect(response.result?["status"] == .string("ok"))
}

@Test func unknownMethodReturnsMethodNotFoundError() {
    let request = JSONRPCRequest(id: .int(42), method: "missing_method")

    let response = CommandRouter().handle(request)

    #expect(response.id == .int(42))
    #expect(response.result == nil)
    #expect(response.error?.code == -32601)
}

@Test func requestRoundTripsThroughJSON() throws {
    let request = JSONRPCRequest(id: .string("abc"), method: "health")

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(JSONRPCRequest.self, from: data)

    #expect(decoded.jsonrpc == "2.0")
    #expect(decoded.id == .string("abc"))
    #expect(decoded.method == "health")
}
