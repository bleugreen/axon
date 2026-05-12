import Testing
@testable import AxonCore

@Test func clickRequestReturnsActionResult() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            click: { target in
                #expect(target == "snapshot:snap:1")
                return PrimitiveActionResult(action: "click", target: target, strategy: "AXPress", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("click-1"),
        method: "click",
        params: .object(["target": .string("snapshot:snap:1")])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["strategy"] == .string("AXPress"))
}

@Test func performActionRequestPassesActionName() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            performAction: { target, action in
                #expect(target == "snapshot:snap:2")
                #expect(action == "AXShowMenu")
                return PrimitiveActionResult(action: action, target: target, strategy: "AXAction", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("action-1"),
        method: "perform_action",
        params: .object([
            "target": .string("snapshot:snap:2"),
            "action": .string("AXShowMenu")
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["action"] == .string("AXShowMenu"))
}

@Test func setValueRequestPassesValue() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            setValue: { target, value in
                #expect(target == "snapshot:snap:3")
                #expect(value == "hello")
                return PrimitiveActionResult(action: "set_value", target: target, strategy: "AXValue", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("set-1"),
        method: "set_value",
        params: .object([
            "target": .string("snapshot:snap:3"),
            "value": .string("hello")
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["success"] == .bool(true))
}

@Test func typeTextRequestPassesAppAndText() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            typeText: { app, text in
                #expect(app == "com.example.App")
                #expect(text == "hello")
                return PrimitiveActionResult(action: "type_text", target: app, strategy: "CGEventKeyboard", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("type-1"),
        method: "type_text",
        params: .object([
            "app": .string("com.example.App"),
            "text": .string("hello")
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["strategy"] == .string("CGEventKeyboard"))
}

@Test func pressKeyRequestPassesAppAndKey() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            pressKey: { app, key in
                #expect(app == "com.example.App")
                #expect(key == "Return")
                return PrimitiveActionResult(action: "press_key", target: app, strategy: "CGEventKeyboard", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("key-1"),
        method: "press_key",
        params: .object([
            "app": .string("com.example.App"),
            "key": .string("Return")
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["target"] == .string("com.example.App"))
}

