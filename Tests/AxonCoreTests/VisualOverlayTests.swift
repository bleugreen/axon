import Testing
@testable import AxonCore

@Test func visualOverlayConfigurationDefaultsEnabled() {
    let configuration = VisualOverlayConfiguration.fromEnvironment([:])

    #expect(configuration.enabled)
    #expect(configuration.plannedDuration == 0.25)
    #expect(configuration.resultDuration == 1.10)
}

@Test func visualOverlayConfigurationCanBeDisabled() {
    let configuration = VisualOverlayConfiguration.fromEnvironment([
        "AXON_VISUAL_OVERLAY": "0"
    ])

    #expect(configuration.enabled == false)
}

@Test func visualOverlayConfigurationReadsEnvironment() {
    let configuration = VisualOverlayConfiguration.fromEnvironment([
        "AXON_VISUAL_OVERLAY": "1",
        "AXON_VISUAL_OVERLAY_PLANNED_MS": "75",
        "AXON_VISUAL_OVERLAY_RESULT_MS": "250"
    ])

    #expect(configuration.enabled)
    #expect(configuration.plannedDuration == 0.075)
    #expect(configuration.resultDuration == 0.25)
}

@Test func visualTargetCarriesFrameLabelStateAndDuration() {
    let target = VisualTarget(
        frame: AXFrame(x: 1, y: 2, width: 3, height: 4),
        label: "AXPress",
        state: .planned,
        duration: 0.1
    )

    #expect(target.frame == AXFrame(x: 1, y: 2, width: 3, height: 4))
    #expect(target.label == "AXPress")
    #expect(target.state == .planned)
    #expect(target.duration == 0.1)
}
