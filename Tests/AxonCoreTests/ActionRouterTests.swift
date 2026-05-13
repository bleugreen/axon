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

@Test func clickRequestAcceptsPointTarget() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            clickPoint: { point in
                #expect(point.x == 25)
                #expect(point.y == 40)
                return PrimitiveActionResult(
                    action: "click",
                    target: "point:25,40",
                    strategy: "CGEvent",
                    success: true,
                    details: ["point": point.jsonValue]
                )
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("click-point"),
        method: "click",
        params: .object([
            "target": .object([
                "point": .object([
                    "x": .int(25),
                    "y": .int(40)
                ])
            ])
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["target"] == .string("point:25,40"))
    #expect(response.result?["action"]?["point"]?["x"] == .double(25))
}

@Test func resolveRequestReturnsLocatorResolution() {
    let router = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot == false)
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
        captureSnapshot: { _, screenshot in
            #expect(screenshot == false)
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

@Test func scrollRequestPassesPointTargetAndDeltas() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            scroll: { target, app, deltaX, deltaY in
                #expect(target == .point(ActionPoint(x: 10, y: 20)))
                #expect(app == "com.example.App")
                #expect(deltaX == 0)
                #expect(deltaY == -480)
                return PrimitiveActionResult(action: "scroll", target: "point:10,20", strategy: "AXScrollToVisible", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("scroll-point"),
        method: "scroll",
        params: .object([
            "app": .string("com.example.App"),
            "target": .object(["point": .object(["x": .int(10), "y": .int(20)])]),
            "deltaY": .int(-480)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["action"] == .string("scroll"))
}

@Test func scrollRequestResolvesLocatorTarget() {
    let router = CommandRouter(
        captureSnapshot: { _, _ in actionLocatorFixtureSnapshot(buttons: ["List"]) },
        actions: PrimitiveActionHandlers(
            scroll: { target, _, _, _ in
                #expect(target == .handle("snapshot:action-locator-fixture:2"))
                return PrimitiveActionResult(action: "scroll", target: "snapshot:action-locator-fixture:2", strategy: "AXScrollToVisible", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("scroll-locator"),
        method: "scroll",
        params: .object([
            "target": .object([
                "app": .string("com.example.App"),
                "locator": .object([
                    "role": .string("AXButton"),
                    "title": .string("List")
                ])
            ]),
            "deltaY": .int(-120)
        ])
    ))

    #expect(response.error == nil)
}

@Test func dragRequestPassesPointEndpoints() {
    let router = CommandRouter(
        actions: PrimitiveActionHandlers(
            drag: { from, to, app, durationMs in
                #expect(from == .point(ActionPoint(x: 10, y: 20)))
                #expect(to == .point(ActionPoint(x: 90, y: 120)))
                #expect(app == "com.example.App")
                #expect(durationMs == 250)
                return PrimitiveActionResult(action: "drag", target: "point:10,20->point:90,120", strategy: "CGEventDrag", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("drag-points"),
        method: "drag",
        params: .object([
            "app": .string("com.example.App"),
            "from": .object(["point": .object(["x": .int(10), "y": .int(20)])]),
            "to": .object(["point": .object(["x": .int(90), "y": .int(120)])]),
            "durationMs": .int(250)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["action"]?["action"] == .string("drag"))
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
