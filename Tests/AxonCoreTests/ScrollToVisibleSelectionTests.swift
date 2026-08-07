import Testing
@testable import AxonCore

private let container = AXFrame(x: 0, y: 0, width: 200, height: 100)

private func candidate(y: Double, _ capability: ScrollToVisibleCapability) -> ScrollToVisibleCandidate {
    ScrollToVisibleCandidate(frame: AXFrame(x: 0, y: y, width: 200, height: 20), capability: capability)
}

@Test func scrollSelectionSkipsADescendantThatDoesNotAdvertiseTheAction() {
    // Finder's sidebar rows are exactly this shape: correctly placed below the viewport, and
    // advertising only AXShowDefaultUI and AXShowAlternateUI. Choosing one commits the scroll to a
    // mechanism that does not exist.
    let selection = ScrollToVisibleSelector.select(
        from: [candidate(y: 200, .absent)],
        container: container,
        deltaX: 0,
        deltaY: -400
    )

    #expect(selection == nil)
}

@Test func scrollSelectionKeepsACandidateWhoseCapabilityCouldNotBeRead() {
    // Silence is not a negative answer. Dropping this candidate would turn a transient accessibility
    // fault into a wheel burst, so it stays in the running and the action it is sent decides.
    let selection = ScrollToVisibleSelector.select(
        from: [candidate(y: 200, .unknown)],
        container: container,
        deltaX: 0,
        deltaY: -400
    )

    #expect(selection == 0)
}

@Test func scrollSelectionRanksAnUnreadableCandidateOnGeometryLikeAnyOther() {
    // Unknown is not a penalty either: among candidates that were not proved incapable, placement
    // is still what decides, so the nearer unreadable element wins over a further advertised one.
    let selection = ScrollToVisibleSelector.select(
        from: [candidate(y: 200, .advertised), candidate(y: 480, .unknown)],
        container: container,
        deltaX: 0,
        deltaY: -400
    )

    #expect(selection == 1)
}

@Test func scrollSelectionPrefersAnAdvertisedActionOverANearerElementThatCannotPerformIt() {
    // Eligibility filters before ranking rather than breaking its ties: the nearer element is not a
    // better answer than the reachable one further away, it is not an answer at all.
    let selection = ScrollToVisibleSelector.select(
        from: [candidate(y: 480, .absent), candidate(y: 200, .advertised)],
        container: container,
        deltaX: 0,
        deltaY: -400
    )

    #expect(selection == 1)
}

@Test func scrollSelectionRanksEligibleCandidatesByWhereTheDeltaWantsToLand() {
    // Ranking among what remains is unchanged: a 400px downward delta reaches for y = 500, so the
    // element centered nearest that coordinate is the one whose reveal moves about that far.
    let selection = ScrollToVisibleSelector.select(
        from: [candidate(y: 200, .advertised), candidate(y: 480, .advertised), candidate(y: 900, .advertised)],
        container: container,
        deltaX: 0,
        deltaY: -400
    )

    #expect(selection == 1)
}

@Test func scrollSelectionIgnoresElementsTheDeltaWouldNotHaveToTravelTo() {
    // Already inside the viewport, and above it in the direction of travel: neither needs revealing.
    let selection = ScrollToVisibleSelector.select(
        from: [candidate(y: 40, .advertised), candidate(y: -300, .advertised)],
        container: container,
        deltaX: 0,
        deltaY: -400
    )

    #expect(selection == nil)
}

@Test func scrollSelectionFollowsTheDominantAxis() {
    let rightOfContainer = ScrollToVisibleCandidate(
        frame: AXFrame(x: 300, y: 10, width: 50, height: 20),
        capability: .advertised
    )
    let belowContainer = ScrollToVisibleCandidate(
        frame: AXFrame(x: 10, y: 300, width: 50, height: 20),
        capability: .advertised
    )

    #expect(ScrollToVisibleSelector.select(from: [rightOfContainer, belowContainer], container: container, deltaX: -400, deltaY: 0) == 0)
    #expect(ScrollToVisibleSelector.select(from: [rightOfContainer, belowContainer], container: container, deltaX: 0, deltaY: -400) == 1)
}

@Test func scrollSelectionChoosesNothingWithoutADelta() {
    #expect(ScrollToVisibleSelector.select(from: [candidate(y: 200, .advertised)], container: container, deltaX: 0, deltaY: 0) == nil)
}
