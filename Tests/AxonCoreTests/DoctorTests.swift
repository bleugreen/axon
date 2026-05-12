import Testing
@testable import AxonCore

@Test func doctorReportsReadyWhenAccessibilityIsTrusted() {
    let report = Doctor.run(permissionProvider: { true })

    #expect(report.isReady)
    #expect(report.accessibility.status == .trusted)
}

@Test func doctorReportsNotReadyWhenAccessibilityIsDenied() {
    let report = Doctor.run(permissionProvider: { false })

    #expect(!report.isReady)
    #expect(report.accessibility.status == .denied)
}
