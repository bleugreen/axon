import Testing
@testable import AxonCore

private let container = AXFrame(x: 0, y: 0, width: 200, height: 100)

private func candidate(y: Double, performs: Bool) -> ScrollToVisibleCandidate {
    ScrollToVisibleCandidate(frame: AXFrame(x: 0, y: y, width: 200, height: 20), performsScrollToVisible: performs)
}

@Test func scrollSelectionSkipsADescendantThatDoesNotAdvertiseTheAction() {
    // Finder's sidebar rows are exactly this shape: correctly placed below the viewport, and
    // advertising only AXShowDefaultUI and AXShowAlternateUI. Choosing one commits the scroll to a
    // mechanism that does not exist.
    let selection = ScrollToVisibleSelector.select(
        from: [candidate(y: 200, performs: false)],
        container: container,
        deltaX: 0,
        deltaY: -400
    )

    #expect(selection == nil)
}

@Test func scrollSelectionPrefersAnAdvertisedActionOverANearerElementThatCannotPerformIt() {
    // Eligibility filters before ranking rather than breaking its ties: the nearer element is not a
    // better answer than the reachable one further away, it is not an answer at all.
    let selection = ScrollToVisibleSelector.select(
        from: [candidate(y: 480, performs: false), candidate(y: 200, performs: true)],
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
        from: [candidate(y: 200, performs: true), candidate(y: 480, performs: true), candidate(y: 900, performs: true)],
        container: container,
        deltaX: 0,
        deltaY: -400
    )

    #expect(selection == 1)
}

@Test func scrollSelectionIgnoresElementsTheDeltaWouldNotHaveToTravelTo() {
    // Already inside the viewport, and above it in the direction of travel: neither needs revealing.
    let selection = ScrollToVisibleSelector.select(
        from: [candidate(y: 40, performs: true), candidate(y: -300, performs: true)],
        container: container,
        deltaX: 0,
        deltaY: -400
    )

    #expect(selection == nil)
}

@Test func scrollSelectionFollowsTheDominantAxis() {
    let rightOfContainer = ScrollToVisibleCandidate(
        frame: AXFrame(x: 300, y: 10, width: 50, height: 20),
        performsScrollToVisible: true
    )
    let belowContainer = ScrollToVisibleCandidate(
        frame: AXFrame(x: 10, y: 300, width: 50, height: 20),
        performsScrollToVisible: true
    )

    #expect(ScrollToVisibleSelector.select(from: [rightOfContainer, belowContainer], container: container, deltaX: -400, deltaY: 0) == 0)
    #expect(ScrollToVisibleSelector.select(from: [rightOfContainer, belowContainer], container: container, deltaX: 0, deltaY: -400) == 1)
}

@Test func scrollSelectionChoosesNothingWithoutADelta() {
    #expect(ScrollToVisibleSelector.select(from: [candidate(y: 200, performs: true)], container: container, deltaX: 0, deltaY: 0) == nil)
}
