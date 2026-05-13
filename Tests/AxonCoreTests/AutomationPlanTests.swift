import Foundation
import Testing
@testable import AxonCore

@Test func runPlanExecutesYamlReadAndClickLocatorWithTrace() {
    let router = CommandRouter(
        captureSnapshot: { app, screenshot in
            #expect(app == "com.example.App")
            #expect(screenshot == false)
            return planFixtureSnapshot(id: "plan-read-click", controls: [
                AXNode(role: "AXButton", title: "NEW", actions: ["AXPress"])
            ])
        },
        actions: PrimitiveActionHandlers(
            click: { target in
                #expect(target == "snapshot:plan-read-click:1")
                return PrimitiveActionResult(action: "click", target: target, strategy: "AXPress", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("plan"),
        method: "run_plan",
        params: .object([
            "source": .string("""
            version: 1
            app: com.example.App
            steps:
              - read:
                  as: state
              - click:
                  target:
                    locator:
                      role: AXButton
                      title: NEW
            """)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["plan"]?["success"] == .bool(true))
    #expect(response.result?["plan"]?["trace"]?[0]?["op"] == .string("read"))
    #expect(response.result?["plan"]?["trace"]?[0]?["success"] == .bool(true))
    #expect(response.result?["plan"]?["trace"]?[1]?["op"] == .string("click"))
    #expect(response.result?["plan"]?["trace"]?[1]?["success"] == .bool(true))
    #expect(response.result?["plan"]?["outputs"]?["state"]?["snapshotId"] == .string("plan-read-click"))
}

@Test func runPlanIfExecutesOnlyMatchingBranch() {
    var clickedTargets: [String] = []
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            planFixtureSnapshot(id: "plan-if", controls: [
                AXNode(role: "AXButton", title: "Run tests", actions: ["AXPress"])
            ])
        },
        actions: PrimitiveActionHandlers(
            click: { target in
                clickedTargets.append(target)
                return PrimitiveActionResult(action: "click", target: target, strategy: "AXPress", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("plan-if"),
        method: "run_plan",
        params: .object([
            "source": .string("""
            version: 1
            app: com.example.App
            steps:
              - if:
                  condition:
                    exists:
                      locator:
                        role: AXButton
                        title: Run tests
                  then:
                    - click:
                        target:
                          locator:
                            role: AXButton
                            title: Run tests
                  else:
                    - click:
                        target:
                          locator:
                            role: AXButton
                            title: Missing
            """)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["plan"]?["success"] == .bool(true))
    #expect(response.result?["plan"]?["trace"]?[0]?["op"] == .string("if"))
    #expect(response.result?["plan"]?["trace"]?[0]?["branch"] == .string("then"))
    #expect(clickedTargets == ["snapshot:plan-if:1"])
}

@Test func runPlanWaitUntilPollsUntilConditionExists() {
    var captures = 0
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            captures += 1
            if captures < 3 {
                return planFixtureSnapshot(id: "wait-\(captures)", controls: [])
            }
            return planFixtureSnapshot(id: "wait-\(captures)", controls: [
                AXNode(role: "AXStaticText", value: "Tests passed")
            ])
        }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("plan-wait"),
        method: "run_plan",
        params: .object([
            "source": .string("""
            version: 1
            app: com.example.App
            steps:
              - wait_until:
                  condition:
                    exists:
                      locator:
                        role: AXStaticText
                        value: Tests passed
                  timeoutMs: 1000
                  intervalMs: 0
            """)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["plan"]?["success"] == .bool(true))
    #expect(response.result?["plan"]?["trace"]?[0]?["op"] == .string("wait_until"))
    #expect(response.result?["plan"]?["trace"]?[0]?["attempts"] == .int(3))
}

@Test func runPlanRepeatUntilRunsBodyUntilConditionMatches() {
    var captures = 0
    var pressedKeys: [String] = []
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            captures += 1
            if captures < 3 {
                return planFixtureSnapshot(id: "repeat-\(captures)", controls: [])
            }
            return planFixtureSnapshot(id: "repeat-\(captures)", controls: [
                AXNode(role: "AXStaticText", value: "Ready")
            ])
        },
        actions: PrimitiveActionHandlers(
            pressKey: { _, key in
                pressedKeys.append(key)
                return PrimitiveActionResult(action: "press_key", target: "com.example.App", strategy: "CGEventKeyboard", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("plan-repeat"),
        method: "run_plan",
        params: .object([
            "source": .string("""
            version: 1
            app: com.example.App
            steps:
              - repeat_until:
                  condition:
                    exists:
                      locator:
                        role: AXStaticText
                        value: Ready
                  maxIterations: 3
                  do:
                    - press_key:
                        key: cmd+r
            """)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["plan"]?["success"] == .bool(true))
    #expect(response.result?["plan"]?["trace"]?[0]?["op"] == .string("repeat_until"))
    #expect(response.result?["plan"]?["trace"]?[0]?["attempts"] == .int(3))
    #expect(pressedKeys == ["cmd+r", "cmd+r"])
}

@Test func runPlanDryRunTracesActionsWithoutDispatchingThem() {
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            planFixtureSnapshot(id: "plan-dry-run", controls: [
                AXNode(role: "AXButton", title: "Delete", actions: ["AXPress"])
            ])
        },
        actions: PrimitiveActionHandlers(
            click: { _ in
                Issue.record("dry run must not dispatch click")
                return PrimitiveActionResult(action: "click", target: "bad", strategy: "bad", success: false)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("plan-dry-run"),
        method: "run_plan",
        params: .object([
            "dryRun": .bool(true),
            "source": .string("""
            version: 1
            app: com.example.App
            steps:
              - click:
                  target:
                    locator:
                      role: AXButton
                      title: Delete
            """)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["plan"]?["success"] == .bool(true))
    #expect(response.result?["plan"]?["dryRun"] == .bool(true))
    #expect(response.result?["plan"]?["trace"]?[0]?["op"] == .string("click"))
    #expect(response.result?["plan"]?["trace"]?[0]?["dryRun"] == .bool(true))
    #expect(response.result?["plan"]?["trace"]?[0]?["target"] == .string("snapshot:plan-dry-run:1"))
}

@Test func runPlanResolvesArgsInLocators() {
    var clickedTargets: [String] = []
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            planFixtureSnapshot(id: "plan-args", controls: [
                AXNode(role: "AXButton", title: "Launch", actions: ["AXPress"])
            ])
        },
        actions: PrimitiveActionHandlers(
            click: { target in
                clickedTargets.append(target)
                return PrimitiveActionResult(action: "click", target: target, strategy: "AXPress", success: true)
            }
        )
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("plan-args"),
        method: "run_plan",
        params: .object([
            "args": .object(["button": .string("Launch")]),
            "source": .string("""
            version: 1
            app: com.example.App
            steps:
              - click:
                  target:
                    locator:
                      role: AXButton
                      title: $args.button
            """)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["plan"]?["success"] == .bool(true))
    #expect(clickedTargets == ["snapshot:plan-args:1"])
}

@Test func runPlanAcceptsPlanFilePath() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("axon-plan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let planURL = directory.appendingPathComponent("plan.yaml")
    try """
    version: 1
    app: com.example.App
    steps:
      - read:
          as: state
    """.write(to: planURL, atomically: true, encoding: .utf8)

    let router = CommandRouter(
        captureSnapshot: { _, _ in
            planFixtureSnapshot(id: "plan-file", controls: [])
        }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("plan-file"),
        method: "run_plan",
        params: .object(["path": .string(planURL.path)])
    ))

    #expect(response.error == nil)
    #expect(response.result?["plan"]?["success"] == .bool(true))
    #expect(response.result?["plan"]?["outputs"]?["state"]?["snapshotId"] == .string("plan-file"))
}

@Test func runPlanCompactsSnapshotOutputsByDefault() {
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            planFixtureSnapshot(id: "plan-compact", controls: [
                AXNode(role: "AXButton", title: "NEW", actions: ["AXPress"])
            ])
        }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("plan-compact"),
        method: "run_plan",
        params: .object([
            "source": .string("""
            version: 1
            app: com.example.App
            steps:
              - read:
                  as: state
            """)
        ])
    ))

    let output = response.result?["plan"]?["outputs"]?["state"]
    #expect(response.error == nil)
    #expect(output?["snapshotId"] == .string("plan-compact"))
    #expect(output?["snapshot"]?["id"] == .string("plan-compact"))
    #expect(output?["snapshot"]?["indexedNodeCount"] == .int(2))
    #expect(output?["snapshot"]?["indexedNodes"] == nil)
}

@Test func runPlanCanReturnFullOutputsWhenRequested() {
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            planFixtureSnapshot(id: "plan-full", controls: [
                AXNode(role: "AXButton", title: "NEW", actions: ["AXPress"])
            ])
        }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("plan-full"),
        method: "run_plan",
        params: .object([
            "source": .string("""
            version: 1
            app: com.example.App
            result:
              outputs: full
            steps:
              - read:
                  as: state
            """)
        ])
    ))

    #expect(response.error == nil)
    #expect(response.result?["plan"]?["outputs"]?["state"]?["snapshot"]?["indexedNodes"]?[0]?["role"] == .string("AXWindow"))
}

@Test func runPlanFailureReportsStepAndMissingLocatorDetails() {
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            planFixtureSnapshot(id: "plan-missing", controls: [
                AXNode(role: "AXButton", title: "Existing", actions: ["AXPress"])
            ])
        }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("plan-missing"),
        method: "run_plan",
        params: .object([
            "source": .string("""
            version: 1
            app: com.example.App
            steps:
              - read:
                  as: before
              - click:
                  target:
                    locator:
                      role: AXButton
                      title: Missing
              - read:
                  as: after
            """)
        ])
    ))

    let plan = response.result?["plan"]
    let error = plan?["trace"]?[1]
    #expect(response.error == nil)
    #expect(plan?["success"] == .bool(false))
    #expect(plan?["outputs"]?["before"]?["snapshotId"] == .string("plan-missing"))
    #expect(plan?["outputs"]?["after"] == nil)
    #expect(error?["op"] == .string("error"))
    #expect(error?["stepIndex"] == .int(1))
    #expect(error?["stepPath"] == .string("steps[1]"))
    #expect(error?["stepOp"] == .string("click"))
    #expect(error?["target"]?["locator"]?["title"] == .string("Missing"))
    #expect(error?["resolution"]?["status"] == .string("missing"))
    #expect(error?["resolution"]?["snapshotID"] == .string("plan-missing"))
    #expect(error?["resolution"]?["candidateCount"] == .int(0))
}

@Test func runPlanFailureReportsAmbiguousLocatorCandidates() {
    let router = CommandRouter(
        captureSnapshot: { _, _ in
            planFixtureSnapshot(id: "plan-ambiguous", controls: [
                AXNode(role: "AXButton", title: "Delete", actions: ["AXPress"]),
                AXNode(role: "AXButton", title: "Delete", actions: ["AXPress"])
            ])
        }
    )

    let response = router.handle(JSONRPCRequest(
        id: .string("plan-ambiguous"),
        method: "run_plan",
        params: .object([
            "source": .string("""
            version: 1
            app: com.example.App
            steps:
              - click:
                  target:
                    locator:
                      role: AXButton
                      title: Delete
            """)
        ])
    ))

    let error = response.result?["plan"]?["trace"]?[0]
    #expect(response.error == nil)
    #expect(response.result?["plan"]?["success"] == .bool(false))
    #expect(error?["stepIndex"] == .int(0))
    #expect(error?["stepPath"] == .string("steps[0]"))
    #expect(error?["stepOp"] == .string("click"))
    #expect(error?["resolution"]?["status"] == .string("ambiguous"))
    #expect(error?["resolution"]?["candidateCount"] == .int(2))
    #expect(error?["resolution"]?["candidates"]?[0]?["handle"] == .string("snapshot:plan-ambiguous:1"))
    #expect(error?["resolution"]?["candidates"]?[1]?["handle"] == .string("snapshot:plan-ambiguous:2"))
}

private func planFixtureSnapshot(id: String, controls: [AXNode]) -> AppSnapshot {
    AppSnapshot(
        id: SnapshotID(id),
        app: AppIdentity(bundleIdentifier: "com.example.App", name: "Example", processIdentifier: 42),
        windows: [
            AXNode(role: "AXWindow", title: "Main", children: controls)
        ],
        screenshot: nil
    )
}
