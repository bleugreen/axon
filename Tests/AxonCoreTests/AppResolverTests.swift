import Testing
@testable import AxonCore

@Test func recordableAppFilterKeepsOnlyRegularUIApps() {
    let apps = AppResolver.recordableApps(from: [
        RunningAppDescriptor(
            bundleIdentifier: "com.example.Editor",
            localizedName: "Editor",
            processIdentifier: 10,
            activationPolicy: .regular,
            isTerminated: false
        ),
        RunningAppDescriptor(
            bundleIdentifier: "com.example.Helper",
            localizedName: "Editor Helper",
            processIdentifier: 11,
            activationPolicy: .prohibited,
            isTerminated: false
        ),
        RunningAppDescriptor(
            bundleIdentifier: "com.example.MenuExtra",
            localizedName: "Menu Extra",
            processIdentifier: 12,
            activationPolicy: .accessory,
            isTerminated: false
        ),
        RunningAppDescriptor(
            bundleIdentifier: "com.example.Old",
            localizedName: "Old",
            processIdentifier: 13,
            activationPolicy: .regular,
            isTerminated: true
        )
    ])

    #expect(apps.map(\.name) == ["Editor"])
    #expect(apps.map(\.processIdentifier) == [10])
}

@Test func recordableAppFilterSortsRecentAppsBeforeAlphabeticalRemainder() {
    let apps = AppResolver.recordableApps(from: [
        RunningAppDescriptor(
            bundleIdentifier: "com.example.Browser",
            localizedName: "Browser",
            processIdentifier: 10,
            activationPolicy: .regular,
            isTerminated: false
        ),
        RunningAppDescriptor(
            bundleIdentifier: "com.example.Editor",
            localizedName: "Editor",
            processIdentifier: 11,
            activationPolicy: .regular,
            isTerminated: false
        ),
        RunningAppDescriptor(
            bundleIdentifier: "com.example.Terminal",
            localizedName: "Terminal",
            processIdentifier: 12,
            activationPolicy: .regular,
            isTerminated: false
        ),
        RunningAppDescriptor(
            bundleIdentifier: "com.example.Notes",
            localizedName: "Notes",
            processIdentifier: 13,
            activationPolicy: .regular,
            isTerminated: false
        )
    ], recency: AppRecencySnapshot(entries: [
        AppRecencyEntry(bundleIdentifier: "com.example.Terminal", processIdentifier: nil, lastActivatedAt: 20),
        AppRecencyEntry(bundleIdentifier: nil, processIdentifier: 11, lastActivatedAt: 30)
    ]))

    #expect(apps.map(\.name) == ["Editor", "Terminal", "Browser", "Notes"])
}
