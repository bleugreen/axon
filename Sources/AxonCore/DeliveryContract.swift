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

/// A refusal is an action result, not a transport error: the request was well formed and the target
/// resolved, and the daemon declined to act.
public struct DeliveryRefusal: Codable, Equatable, Sendable {
    public let reason: DeliveryRefusalReason
    /// The rung the action would have needed to reach to be delivered.
    public let requiredRung: DeliveryRung
    /// The mechanism class that was missing or forbidden, when one is responsible.
    public let capability: DeliveryCapability?
    public let message: String

    public init(
        reason: DeliveryRefusalReason,
        requiredRung: DeliveryRung,
        capability: DeliveryCapability? = nil,
        message: String
    ) {
        self.reason = reason
        self.requiredRung = requiredRung
        self.capability = capability
        self.message = message
    }

    public var jsonValue: JSONValue {
        .object([
            "reason": .string(reason.rawValue),
            "requiredRung": .string(requiredRung.rawValue),
            "capability": capability.map { .string($0.rawValue) } ?? .null,
            "message": .string(message)
        ])
    }
}

/// Evidence that a foreground escalation was transactional: what held the foreground before, what
/// Axon did to it, and whether the session was handed back.
public struct ForegroundCleanup: Codable, Equatable, Sendable {
    public let priorApp: String?
    public let priorAppProcessIdentifier: Int?
    /// True when the target already held the foreground, so no activation was performed.
    public let alreadyFrontmost: Bool
    /// True when the target was observed frontmost before anything was posted.
    public let activationProved: Bool
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
        activationProved: Bool,
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
            "activationProved": .bool(activationProved),
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
        for candidate in candidates.sorted(by: { $0.rung.order < $1.rung.order }) {
            if let after, candidate.rung.order <= after.order {
                continue
            }
            if candidate.capability.isForbidden {
                blocked = DeliveryRefusal(
                    reason: .clipboardForbidden,
                    requiredRung: candidate.rung,
                    capability: candidate.capability,
                    message: "\(candidate.strategy) would deliver through the \(candidate.capability.rawValue) capability, which Axon never uses"
                )
                continue
            }
            // A rung the runtime cannot offer is reported as missing whatever the policy says:
            // telling a caller to opt in to a mechanism that does not exist would be a lie.
            if let unavailable = candidate.unavailable {
                blocked = DeliveryRefusal(
                    reason: unavailable,
                    requiredRung: candidate.rung,
                    capability: candidate.capability,
                    message: candidate.unavailableMessage
                        ?? "\(candidate.strategy) is unavailable for this target"
                )
                continue
            }
            if candidate.rung.requiresForegroundOptIn, !policy.permitsForeground {
                // Among rungs that would otherwise work, the policy boundary is the most actionable
                // thing a caller can be told, so it outranks any capability gap below it.
                blocked = DeliveryRefusal(
                    reason: .foregroundNotPermitted,
                    requiredRung: candidate.rung,
                    capability: candidate.capability,
                    message: "\(candidate.strategy) requires foreground delivery; this action ran under \(policy.rawValue)"
                )
                continue
            }
            return .candidate(candidate)
        }
        return .refusal(blocked ?? DeliveryRefusal(
            reason: .noDeliveryCandidate,
            requiredRung: after.map { $0 == .semantic ? .pixel : .foreground } ?? .semantic,
            capability: nil,
            message: "No delivery mechanism remains for this action"
        ))
    }
}
