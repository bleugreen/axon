@testable import AxonClient
import Foundation
import Testing
@testable import AxonCore

@Test func requestRoundTripsThroughJSON() throws {
    let request = JSONRPCRequest(id: .string("abc"), method: "health")

    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(JSONRPCRequest.self, from: data)

    #expect(decoded.jsonrpc == "2.0")
    #expect(decoded.id == .string("abc"))
    #expect(decoded.method == "health")
}
