import Foundation

public enum ToolTarget: Equatable, Sendable {
    case handle(String)
    case locator(app: String, locator: AXLocator)
    case point(ActionPoint)
    case textLocation(TextLocationTarget)

    public var kind: ToolTargetKind {
        switch self {
        case .handle:
            return .handle
        case .locator:
            return .locator
        case .point:
            return .point
        case .textLocation:
            return .textLocation
        }
    }

    public init(jsonValue: JSONValue, acceptedKinds: ToolTargetKindSet = .pointer, fieldName: String = "target") throws {
        if case let .string(handle) = jsonValue {
            guard acceptedKinds.contains(.handle) else {
                throw JSONRPCError.invalidParams("\(fieldName) does not accept handle targets; accepted target kinds: \(acceptedKinds.description)")
            }
            self = .handle(handle)
            return
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

        if object["app"] != nil || object["locator"] != nil {
            guard acceptedKinds.contains(.locator) else {
                throw JSONRPCError.invalidParams("\(fieldName) does not accept locator targets; accepted target kinds: \(acceptedKinds.description)")
            }
            guard case let .string(app) = object["app"], !app.isEmpty else {
                throw JSONRPCError.invalidParams("Locator target must include string app")
            }
            guard let locatorValue = object["locator"] else {
                throw JSONRPCError.invalidParams("Locator target must include locator")
            }
            self = .locator(app: app, locator: try AXLocator(jsonValue: locatorValue))
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
