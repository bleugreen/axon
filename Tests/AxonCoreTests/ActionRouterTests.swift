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

@Test func resolveRequestReturnsLocatorResolution() {
    let router = CommandRouter(
        captureSnapshot: { app, includeScreenshot in
            #expect(app == "com.example.App")
            #expect(includeScreenshot == false)
            return actionLocatorFixtureSnapshot(buttons: ["NEW"])
        }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("resolve-1"),
        method: "resolve",
        params: .object([
            "app": .string("com.example.App"),
            "locator": .object([
                "role": .string("AXButton"),
                "title": .object(["exact": .string("NEW")]),
                "actions": .array([.string("AXPress")])
            ])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["resolution"]?["status"] == .string("unique"))
    #expect(response.result?["resolution"]?["best"]?["handle"] == .string("snapshot:action-locator-fixture:2"))
}

@Test func clickRequestAcceptsLocatorTarget() {
    let router = CommandRouter(
        captureSnapshot: { _, includeScreenshot in
            #expect(includeScreenshot == false)
            return actionLocatorFixtureSnapshot(buttons: ["NEW"])
        },
        actions: PrimitiveActionHandlers(
            click: { target in
                #expect(target == "snapshot:action-locator-fixture:2")
                return PrimitiveActionResult(action: "click", target: target, strategy: "AXPress", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("click-locator-1"),
        method: "click",
        params: .object([
            "target": .object([
                "app": .string("com.example.App"),
                "locator": .object([
                    "role": .string("AXButton"),
                    "title": .object(["exact": .string("NEW")])
                ])
            ])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["target"] == .string("snapshot:action-locator-fixture:2"))
}

@Test func clickRequestRejectsAmbiguousLocatorTarget() {
    let router = CommandRouter(
        captureSnapshot: { _, _ in actionLocatorFixtureSnapshot(buttons: ["NEW", "NEW"]) },
        actions: PrimitiveActionHandlers(
            click: { _ in
                Issue.record("ambiguous locator should not dispatch a click")
                return PrimitiveActionResult(action: "click", target: "bad", strategy: "bad", success: false)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("click-locator-ambiguous"),
        method: "click",
        params: .object([
            "target": .object([
                "app": .string("com.example.App"),
                "locator": .object([
                    "role": .string("AXButton"),
                    "title": .object(["exact": .string("NEW")])
                ])
            ])
        ])
    ))

    #expect(response.error?.code == -32602)
    #expect(response.error?.message == "Locator did not resolve uniquely: ambiguous")
}

@Test func clickRequestReportsStaleSnapshotHandleAsInvalidParams() {
    let router = CommandRouter(elementStore: AXElementStore())

    let response = router.handle(JSONRPCRequest(
        id: .string("click-stale"),
        method: "click",
        params: .object(["target": .string("snapshot:missing:0")])
    ))

    #expect(response.error?.code == -32602)
    #expect(response.error?.message == "Snapshot is not retained: missing")
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

private func actionLocatorFixtureSnapshot(buttons: [String]) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID("action-locator-fixture"),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(
                role: "AXWindow",
                title: "Main",
                children: [
                    AXNode(
                        role: "AXGroup",
                        title: "Toolbar",
                        children: buttons.map { title in
                            AXNode(role: "AXButton", title: title, actions: ["AXPress"])
                        }
                    )
                ]
            )
        ],
        screenshot: nil
    )
}
