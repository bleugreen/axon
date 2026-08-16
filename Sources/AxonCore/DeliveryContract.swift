import Foundation

/// What a single mutating action is allowed to do to the user's session.
///
/// The policy is per action and never daemon state: it is decoded from the request that carries it
/// and is not inherited by anything that runs later, including later steps of the same .axn run.
public enum DeliveryPolicy: String, Codable, Equatable, Sendable, CaseIterable {
    /// Forbids application activation, system-focus changes, movement of the real pointer, global
    /// keyboard input, and clipboard access. This is what a caller gets when it says nothing.
    case backgroundOnly
    /// Permits the backend to escalate this one action to the foreground rung.
    case foregroundPermitted

    public static let `default` = DeliveryPolicy.backgroundOnly

    /// Decodes a wire value, rejecting anything outside the vocabulary before a target is resolved.
    public static func validated(_ rawValue: String) throws -> DeliveryPolicy {
        guard let policy = DeliveryPolicy(rawValue: rawValue) else {
            let known = DeliveryPolicy.allCases.map(\.rawValue).joined(separator: ", ")
            throw JSONRPCError.invalidParams("deliveryPolicy must be one of: \(known)")
        }
        return policy
    }

    public var permitsForeground: Bool {
        self == .foregroundPermitted
    }
}

/// The mechanism that actually delivered an action, classified by observable side effect rather
/// than by the name of the API that produced it.
public enum DeliveryRung: String, Codable, Equatable, Sendable, CaseIterable {
    /// An accessibility-level mutation (AX, UIA, AT-SPI) that neither focused nor activated.
    case semantic
    /// Target-bound input derived from verified window geometry, delivered without activating the
    /// application and without moving the real pointer.
    case pixel
    /// Global input devices: CGEvent posted to the HID tap, SendInput, XTest, or a virtual pointer.
    case foreground

    /// Ladder position. Candidates are always enumerated in this order.
    public var order: Int {
        switch self {
        case .semantic: return 0
        case .pixel: return 1
        case .foreground: return 2
        }
    }

    /// Whether reaching this rung requires the caller to have opted in.
    public var requiresForegroundOptIn: Bool {
        self == .foreground
    }
}

/// The mechanism class a candidate depends on. Naming it lets a refusal say which faculty was
/// missing rather than only which rung was blocked.
public enum DeliveryCapability: String, Codable, Equatable, Sendable, CaseIterable {
    /// Performing a named accessibility action on a resolved element.
    case semanticAction
    /// Setting an accessibility value directly on a resolved element.
    case semanticValue
    /// Process- or window-targeted input that never touches global devices.
    case backgroundPixelInput
    /// Global input devices shared with the human at the keyboard.
    case globalInput
    /// The system pasteboard. Modelled so a future fallback cannot silently introduce it; no
    /// ladder in Axon contains a clipboard candidate, and the planner refuses one on sight.
    case clipboard

    /// Capabilities Axon will never dispatch through, at any policy.
    public var isForbidden: Bool {
        self == .clipboard
    }
}

/// Why delivery stopped before any native side effect.
public enum DeliveryRefusalReason: String, Codable, Equatable, Sendable, CaseIterable {
    /// The only remaining rung was foreground and the action did not permit it.
    case foregroundNotPermitted
    /// No target-bound mechanism on this platform, compositor, toolkit, or window could carry the
    /// action without global input.
    case backgroundPixelUnsupported
    /// The request named coordinates that cannot be bound to an application and window, so no
    /// background mechanism could prove where the input would land.
    case targetIdentityUnavailable
    /// A clipboard-backed candidate was offered. Always refused.
    case clipboardForbidden
    /// Foreground escalation could not prove the target became frontmost, so nothing was posted.
    case activationNotProved
    /// This rung's mechanism does not exist on this backend, so the action has no way to run.
    case noDeliveryCandidate
}

/// A rung the ladder walked past, and the obstacle that stopped it there.
///
/// Which refusal is *reported* is a ranking decision, and the ranking is right: among rungs that
/// would otherwise work, the policy boundary is the most actionable thing a caller can be told. The
/// obstacles below it are ranked against nothing, and they are where the platform-specific evidence
/// lives — the process a background click could not be bound to, the toolkit that declined. A
/// caller told only `foregroundNotPermitted` learns to opt in and learns nothing about whether the
/// quiet rung would ever work against this target, which is a different piece of advice. So the
/// winning reason keeps its place and every other obstacle rides along beside it.
public struct DeliveryObstacle: Codable, Equatable, Sendable {
    public let rung: DeliveryRung
    public let reason: DeliveryRefusalReason
    public let message: String

    public init(rung: DeliveryRung, reason: DeliveryRefusalReason, message: String) {
        self.rung = rung
        self.reason = reason
        self.message = message
    }

    /// The obstacle a refusal becomes once a later rung supersedes it as the reported one.
    public init(_ refusal: DeliveryRefusal) {
        self.init(rung: refusal.requiredRung, reason: refusal.reason, message: refusal.message)
    }

    public var jsonValue: JSONValue {
        .object([
            "rung": .string(rung.rawValue),
            "reason": .string(reason.rawValue),
            "message": .string(message)
        ])
    }
}

/// A refusal is an action result, not a transport error: the request was well formed and the target
/// resolved, and the daemon declined to act.
public struct DeliveryRefusal: Codable, Equatable, Sendable {
    public let reason: DeliveryRefusalReason
    /// The rung the action would have needed to reach to be delivered.
    public let requiredRung: DeliveryRung
    /// The mechanism class that was missing or forbidden, when one is responsible.
    public let capability: DeliveryCapability?
    public let message: String
    /// Every other rung the ladder walked past, in ladder order, each carrying its own obstacle.
    /// Empty for a refusal no ladder walk produced, such as one raised by a foreground transaction
    /// that had already been selected.
    public let alsoRefused: [DeliveryObstacle]

    public init(
        reason: DeliveryRefusalReason,
        requiredRung: DeliveryRung,
        capability: DeliveryCapability? = nil,
        message: String,
        alsoRefused: [DeliveryObstacle] = []
    ) {
        self.reason = reason
        self.requiredRung = requiredRung
        self.capability = capability
        self.message = message
        self.alsoRefused = alsoRefused
    }

    /// Attaches the obstacles a ladder walk collected. File-private on purpose: the planner is the
    /// only thing that walks a ladder, so it is the only thing that can honestly say what was
    /// walked past.
    fileprivate func alsoRefusing(_ obstacles: [DeliveryObstacle]) -> DeliveryRefusal {
        DeliveryRefusal(
            reason: reason,
            requiredRung: requiredRung,
            capability: capability,
            message: message,
            alsoRefused: obstacles
        )
    }

    public var jsonValue: JSONValue {
        .object([
            "reason": .string(reason.rawValue),
            "requiredRung": .string(requiredRung.rawValue),
            "capability": capability.map { .string($0.rawValue) } ?? .null,
            "message": .string(message),
            "alsoRefused": .array(alsoRefused.map(\.jsonValue))
        ])
    }
}

/// Evidence that a foreground escalation was transactional: what held the foreground before, what
/// Axon did to it, and whether the session was handed back.
public struct ForegroundCleanup: Codable, Equatable, Sendable {
    public let priorApp: String?
    public let priorAppProcessIdentifier: Int?
    /// True when no activation was performed: either the target already held the foreground, or the
    /// action named no application and so had nothing to raise.
    public let alreadyFrontmost: Bool
    /// True when the target was observed frontmost before anything was posted, and nil when the
    /// action named no application, so there was no target to observe and nothing was proved.
    ///
    /// The nil case is the honest answer to a question that does not apply. Reporting `true` there
    /// read as evidence that an activation had succeeded, which sent a field investigation after the
    /// wrong mechanism entirely.
    public let activationProved: Bool?
    /// True when the prior application was observed frontmost again afterwards. Also true when
    /// nothing needed restoring because the target already held the foreground.
    public let restored: Bool
    /// Nil when the dispatch never moved the pointer, so there was nothing to put back.
    public let pointerRestored: Bool?
    public let message: String?

    public init(
        priorApp: String?,
        priorAppProcessIdentifier: Int?,
        alreadyFrontmost: Bool,
        activationProved: Bool?,
        restored: Bool,
        pointerRestored: Bool? = nil,
        message: String? = nil
    ) {
        self.priorApp = priorApp
        self.priorAppProcessIdentifier = priorAppProcessIdentifier
        self.alreadyFrontmost = alreadyFrontmost
        self.activationProved = activationProved
        self.restored = restored
        self.pointerRestored = pointerRestored
        self.message = message
    }

    public var jsonValue: JSONValue {
        .object([
            "priorApp": priorApp.map(JSONValue.string) ?? .null,
            "priorAppProcessIdentifier": priorAppProcessIdentifier.map(JSONValue.int) ?? .null,
            "alreadyFrontmost": .bool(alreadyFrontmost),
            "activationProved": activationProved.map(JSONValue.bool) ?? .null,
            "restored": .bool(restored),
            "pointerRestored": pointerRestored.map(JSONValue.bool) ?? .null,
            "message": message.map(JSONValue.string) ?? .null
        ])
    }
}

/// One rung of an action's delivery ladder.
///
/// A candidate that the runtime cannot satisfy right now still belongs in the ladder, carrying the
/// reason it is unavailable, so a refusal can name the missing faculty instead of falling silently
/// through to a louder mechanism.
public struct DeliveryCandidate: Equatable, Sendable {
    public let rung: DeliveryRung
    public let capability: DeliveryCapability
    /// The strategy name reported when this candidate dispatches, for example AXPress or CGEvent.
    public let strategy: String
    /// Set when this candidate exists in principle but cannot run against this target right now.
    public let unavailable: DeliveryRefusalReason?
    /// Why the candidate is unavailable, in the caller's terms.
    public let unavailableMessage: String?

    public init(
        rung: DeliveryRung,
        capability: DeliveryCapability,
        strategy: String,
        unavailable: DeliveryRefusalReason? = nil,
        unavailableMessage: String? = nil
    ) {
        self.rung = rung
        self.capability = capability
        self.strategy = strategy
        self.unavailable = unavailable
        self.unavailableMessage = unavailableMessage
    }

    public var isAvailable: Bool {
        unavailable == nil && !capability.isForbidden
    }
}

public enum DeliverySelection: Equatable, Sendable {
    case candidate(DeliveryCandidate)
    case refusal(DeliveryRefusal)
}

/// Chooses the rung an action will use before anything native happens.
///
/// The ladder is fixed per action and ordered semantic, then pixel, then foreground. The planner's
/// only job is to answer which of those the caller's policy and the current runtime allow, and to
/// explain the answer when it is none of them.
public enum DeliveryPlanner {
    /// Selects the first candidate strictly above `after` that the policy and runtime allow.
    ///
    /// Passing `after` is how a failed attempt advances: the rung that just failed, and everything
    /// below it, is skipped.
    public static func select(
        from candidates: [DeliveryCandidate],
        policy: DeliveryPolicy,
        after: DeliveryRung? = nil
    ) -> DeliverySelection {
        var blocked: DeliveryRefusal?
        // Every candidate the walk passed over, in ladder order. The newest block is the one that
        // gets reported; the one it supersedes is demoted to an obstacle rather than dropped.
        var walkedPast: [DeliveryObstacle] = []
        func block(_ refusal: DeliveryRefusal) {
            if let previous = blocked {
                walkedPast.append(DeliveryObstacle(previous))
            }
            blocked = refusal
        }
        for candidate in candidates.sorted(by: { $0.rung.order < $1.rung.order }) {
            if let after, candidate.rung.order <= after.order {
                continue
            }
            if candidate.capability.isForbidden {
                block(DeliveryRefusal(
                    reason: .clipboardForbidden,
                    requiredRung: candidate.rung,
                    capability: candidate.capability,
                    message: "\(candidate.strategy) would deliver through the \(candidate.capability.rawValue) capability, which Axon never uses"
                ))
                continue
            }
            // A rung the runtime cannot offer is reported as missing whatever the policy says:
            // telling a caller to opt in to a mechanism that does not exist would be a lie.
            if let unavailable = candidate.unavailable {
                block(DeliveryRefusal(
                    reason: unavailable,
                    requiredRung: candidate.rung,
                    capability: candidate.capability,
                    message: candidate.unavailableMessage
                        ?? "\(candidate.strategy) is unavailable for this target"
                ))
                continue
            }
            if candidate.rung.requiresForegroundOptIn, !policy.permitsForeground {
                // Among rungs that would otherwise work, the policy boundary is the most actionable
                // thing a caller can be told, so it outranks any capability gap below it. What the
                // gaps below still have to say travels in `alsoRefused` rather than being dropped.
                block(DeliveryRefusal(
                    reason: .foregroundNotPermitted,
                    requiredRung: candidate.rung,
                    capability: candidate.capability,
                    message: "\(candidate.strategy) requires foreground delivery; this action ran under \(policy.rawValue)"
                ))
                continue
            }
            return .candidate(candidate)
        }
        // Nothing declined an action with no blocked rung; it simply has no mechanism, so there is
        // no obstacle to report beyond the absence itself.
        return .refusal(blocked?.alsoRefusing(walkedPast) ?? DeliveryRefusal(
            reason: .noDeliveryCandidate,
            requiredRung: after.map { $0 == .semantic ? .pixel : .foreground } ?? .semantic,
            capability: nil,
            message: "No delivery mechanism remains for this action"
        ))
    }
}
