import ApplicationServices
import Testing
@testable import AxonCore

@Test func accessibilityErrorsAreNamedAlongsideTheirCode() {
    // The two codes are adjacent and were confused in a bug report: -25205 names an unsupported
    // attribute, and the action error is -25206. A message that carries the name cannot be misread.
    #expect(AXError.actionUnsupported.axonDescription == "actionUnsupported (-25206)")
    #expect(AXError.attributeUnsupported.axonDescription == "attributeUnsupported (-25205)")
    #expect(AXError.cannotComplete.axonDescription == "cannotComplete (-25204)")
    #expect(AXError.success.axonDescription == "success (0)")
}
