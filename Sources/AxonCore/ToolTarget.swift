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
            throw JSONRPCError.invalidParams("\(fieldName) semantic targets must be {app,name}")
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
        if let point = object["point"] {
            return try pointValue(point, fieldName: fieldName)
        }
        return try pointValue(value, fieldName: fieldName)
    }

    private static func pointValue(_ value: JSONValue, fieldName: String) throws -> ActionPoint {
        guard case let .object(object) = value else {
            throw JSONRPCError.invalidParams("\(fieldName) point must be an object")
        }
        guard let x = numericValue("x", in: object), let y = numericValue("y", in: object) else {
            throw JSONRPCError.invalidParams("\(fieldName) point requires numeric x and y")
        }
        let coordinateSpace = try coordinateSpaceValue(in: object, fieldName: fieldName)
        let app: String?
        if case let .string(value)? = object["app"], !value.isEmpty {
            app = value
        } else {
            app = nil
        }
        return ActionPoint(x: x, y: y, coordinateSpace: coordinateSpace, app: app)
    }

    private static func coordinateSpaceValue(
        in object: [String: JSONValue],
        fieldName: String
    ) throws -> ActionPointCoordinateSpace {
        let rawValue: String?
        if case let .string(value)? = object["coordinateSpace"] {
            rawValue = value
        } else if case let .string(value)? = object["space"] {
            rawValue = value
        } else {
            return .legacyScreen
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
