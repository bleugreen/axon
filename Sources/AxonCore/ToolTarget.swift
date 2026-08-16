import Foundation

public enum ToolTarget: Equatable, Sendable {
    case semanticName(app: String, name: String)
    case point(ActionPoint)
    case textLocation(TextLocationTarget)

    public var kind: ToolTargetKind {
        switch self {
        case .semanticName:
            return .semanticName
        case .point:
            return .point
        case .textLocation:
            return .textLocation
        }
    }

    public init(jsonValue: JSONValue, acceptedKinds: ToolTargetKindSet = .pointer, fieldName: String = "target") throws {
        if case let .string(value) = jsonValue {
            if (try? SnapshotHandle(value)) != nil {
                throw JSONRPCError.invalidParams("\(fieldName) no longer accepts snapshot handles; use {app,name} from look")
            }
            throw JSONRPCError.invalidParams("\(fieldName) semantic targets must be {app,name}; for an app observation pass the top-level app: parameter (bundle identifier, PID, or app name)")
        }

        guard case let .object(object) = jsonValue else {
            throw JSONRPCError.invalidParams("\(fieldName) must be one of: \(acceptedKinds.description)")
        }

        if object["point"] != nil || object["x"] != nil || object["y"] != nil {
            guard acceptedKinds.contains(.point) else {
                throw JSONRPCError.invalidParams("\(fieldName) does not accept point targets; accepted target kinds: \(acceptedKinds.description)")
            }
            self = .point(try Self.pointTarget(from: jsonValue, fieldName: fieldName))
            return
        }

        if let location = object["location"] {
            guard acceptedKinds.contains(.textLocation) else {
                throw JSONRPCError.invalidParams("\(fieldName) does not accept textLocation targets; accepted target kinds: \(acceptedKinds.description)")
            }
            self = .textLocation(try TextLocationTarget(jsonValue: location))
            return
        }

        if object["locator"] != nil, object["name"] == nil {
            throw JSONRPCError.invalidParams("\(fieldName) no longer accepts standalone locators; use {app,name} from look")
        }

        if object["app"] != nil || object["name"] != nil {
            guard acceptedKinds.contains(.semanticName) else {
                throw JSONRPCError.invalidParams("\(fieldName) does not accept semantic name targets; accepted target kinds: \(acceptedKinds.description)")
            }
            guard case let .string(app) = object["app"], !app.isEmpty else {
                throw JSONRPCError.invalidParams("Semantic target must include non-empty string app")
            }
            guard case let .string(name) = object["name"], !name.isEmpty else {
                throw JSONRPCError.invalidParams("Semantic target must include non-empty string name")
            }
            if object["locator"] != nil {
                throw JSONRPCError.invalidParams("Ordinary tool targets do not accept locator evidence; attached locators are reserved for v2 replay")
            }
            self = .semanticName(app: app, name: name)
            return
        }

        throw JSONRPCError.invalidParams("\(fieldName) must be one of: \(acceptedKinds.description)")
    }

    private static func pointTarget(from value: JSONValue, fieldName: String) throws -> ActionPoint {
        guard case let .object(object) = value else {
            throw JSONRPCError.invalidParams("\(fieldName) point target must be an object")
        }
        guard let point = object["point"] else {
            return try pointValue(value, fieldName: fieldName)
        }
        // A wrapped point is written `{app, coordinateSpace, point: {x, y}}` at least as often as
        // `{point: {x, y, app, coordinateSpace}}`, and the two say the same thing. Reading only the
        // nested object dropped whatever the wrapper said, and an app-scoped click that arrives
        // without its app is indistinguishable from a bare coordinate: delivery has no process to
        // bind or raise, so it posts global input into whichever application already holds the
        // foreground.
        return try pointValue(point, fieldName: fieldName, wrapper: object)
    }

    private static func pointValue(
        _ value: JSONValue,
        fieldName: String,
        wrapper: [String: JSONValue] = [:]
    ) throws -> ActionPoint {
        guard case let .object(object) = value else {
            throw JSONRPCError.invalidParams("\(fieldName) point must be an object")
        }
        guard let x = numericValue("x", in: object), let y = numericValue("y", in: object) else {
            throw JSONRPCError.invalidParams("\(fieldName) point requires numeric x and y")
        }
        // The point is the most specific statement of what it means, so what it declares wins and
        // the wrapper only fills in what the point left unsaid.
        let coordinateSpace = try declaredCoordinateSpace(in: object, fieldName: fieldName)
            ?? declaredCoordinateSpace(in: wrapper, fieldName: fieldName)
            ?? .legacyScreen
        let app = nonEmptyString("app", in: object) ?? nonEmptyString("app", in: wrapper)
        return ActionPoint(x: x, y: y, coordinateSpace: coordinateSpace, app: app)
    }

    private static func nonEmptyString(_ key: String, in object: [String: JSONValue]) -> String? {
        guard case let .string(value)? = object[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    /// The coordinate space this object states, or nil when it states none. Nil and `legacyScreen`
    /// are different answers: only the caller who said nothing anywhere gets the legacy default.
    private static func declaredCoordinateSpace(
        in object: [String: JSONValue],
        fieldName: String
    ) throws -> ActionPointCoordinateSpace? {
        let rawValue: String?
        if case let .string(value)? = object["coordinateSpace"] {
            rawValue = value
        } else if case let .string(value)? = object["space"] {
            rawValue = value
        } else {
            return nil
        }
        switch rawValue {
        case "screen":
            return .screen
        case "window":
            return .window
        case "screenshot":
            return .screenshot
        default:
            throw JSONRPCError.invalidParams("\(fieldName) point coordinateSpace must be screen, window, or screenshot")
        }
    }


    private static func numericValue(_ key: String, in params: [String: JSONValue]) -> Double? {
        switch params[key] {
        case let .double(value):
            return value
        case let .int(value):
            return Double(value)
        default:
            return nil
        }
    }
}
