import Foundation
import Testing
@testable import AxonCore

@Test func runBatchExecutesToolShapedActionsInOrder() {
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: [
            "action": .object([
                "success": .bool(true),
                "target": request.params?["target"] ?? .null
            ])
        ])
    }

    let batch = try! executor.run(params: [
        "actions": .array([
            .object([
                "tool": .string("set_value"),
                "target": .string("s1:2"),
                "value": .string("Mitch")
            ]),
            .object([
                "tool": .string("click"),
                "target": .string("s1:3")
            ])
        ])
    ])

    #expect(batch["success"] == .bool(true))
    #expect(batch["trace"]?[0]?["tool"] == .string("set_value"))
    #expect(batch["trace"]?[1]?["tool"] == .string("click"))
    #expect(requests.map(\.method) == ["set_value", "click"])
    #expect(requests[0].params?["value"] == .string("Mitch"))
}

@Test func runBatchStopsOnFirstFailureByDefault() {
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, error: .invalidParams("bad target"))
    }

    let batch = try! executor.run(params: [
        "actions": .array([
            .object(["tool": .string("click"), "target": .string("missing")]),
            .object(["tool": .string("click"), "target": .string("never")])
        ])
    ])

    #expect(batch["success"] == .bool(false))
    #expect(batch["trace"]?.arrayValue?.count == 1)
    #expect(requests.count == 1)
}

@Test func runBatchCanContinueOnError() {
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor { request in
        requests.append(request)
        if requests.count == 1 {
            return JSONRPCResponse(id: request.id, error: .invalidParams("bad target"))
        }
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let batch = try! executor.run(params: [
        "continueOnError": .bool(true),
        "actions": .array([
            .object(["tool": .string("click"), "target": .string("missing")]),
            .object(["tool": .string("click"), "target": .string("s1:3")])
        ])
    ])

    #expect(batch["success"] == .bool(false))
    #expect(batch["trace"]?.arrayValue?.count == 2)
    #expect(requests.count == 2)
}

@Test func runBatchParsesAxnSource() {
    var requests: [JSONRPCRequest] = []
    let executor = ActionBatchExecutor { request in
        requests.append(request)
        return JSONRPCResponse(id: request.id, result: ["action": .object(["success": .bool(true)])])
    }

    let source = """
    version: 1
    actions:
      - tool: press_key
        app: Firefox
        key: Return
    """
    let batch = try! executor.run(params: ["source": .string(source)])

    #expect(batch["success"] == .bool(true))
    #expect(requests == [
        JSONRPCRequest(
            id: .string("batch.0.press_key"),
            method: "press_key",
            params: .object([
                "app": .string("Firefox"),
                "key": .string("Return")
            ])
        )
    ])
}

@Test func commandRouterRunsBatch() {
    var clicked: [String] = []
    let router = CommandRouter(actions: PrimitiveActionHandlers(
        click: { target in
            clicked.append(target)
            return PrimitiveActionResult(action: "click", target: "clicked", strategy: "test", success: true)
        }
    ))

    let response = router.handle(JSONRPCRequest(
        id: .string("batch"),
        method: "run_batch",
        params: .object([
            "actions": .array([
                .object(["tool": .string("click"), "target": .string("s1:2")])
            ])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["batch"]?["success"] == JSONValue.bool(true))
    #expect(clicked == ["s1:2"])
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case let .array(values) = self else {
            return nil
        }
        return values
    }
}
