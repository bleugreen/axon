import AxonCore
import SwiftUI

struct RecipeIntent {
    let title: String
    let detail: String?
    let generatedTitle: String
    let symbolName: String
    let symbolColor: Color
    let parameterNames: [String]

    init(block: AxonRecipeBlock) {
        switch block {
        case let .note(note):
            let text = note.text?.nilIfEmpty ?? "New note"
            self.init(
                title: text,
                detail: nil,
                generatedTitle: text,
                symbolName: "note.text",
                symbolColor: RecipeEditorPalette.note,
                parameterNames: []
            )
        case let .action(action):
            self.init(action: action)
        }
    }

    private init(
        title: String,
        detail: String?,
        generatedTitle: String,
        symbolName: String,
        symbolColor: Color,
        parameterNames: [String]
    ) {
        self.title = title
        self.detail = detail
        self.generatedTitle = generatedTitle
        self.symbolName = symbolName
        self.symbolColor = symbolColor
        self.parameterNames = parameterNames
    }

    init(action: AxonRecipeAction) {
        let generated = Self.generatedTitle(for: action)
        let label = action.fields["label"]?.editableString.nilIfEmpty
        title = label ?? generated
        detail = label == nil ? Self.detail(for: action) : generated
        generatedTitle = generated
        symbolName = Self.symbolName(for: action.tool)
        symbolColor = Self.symbolColor(for: action.tool)
        parameterNames = Self.parameters(in: action)
    }

    private static func generatedTitle(for action: AxonRecipeAction) -> String {
        switch action.tool {
        case "type":
            let value = action.fields["value"]?.editableString.nilIfEmpty ?? "text"
            let destination = LocatorSummary(target: action.fields["target"]).intentName ?? "field"
            return "Type \(value) into \(destination)"
        case "click":
            let target = LocatorSummary(target: action.fields["target"]).intentName ?? "target"
            return "Click \(target)"
        case "keyboard":
            if let text = action.fields["text"]?.editableString.nilIfEmpty {
                return "Type \(text)"
            }
            let keys = action.fields["keys"]?.editableString.nilIfEmpty ?? "keys"
            return "Press \(keys)"
        case "scroll":
            let target = LocatorSummary(target: action.fields["target"]).intentName ?? action.fields["app"]?.editableString.nilIfEmpty ?? "current view"
            return "Scroll \(target)"
        case "drag":
            let from = LocatorSummary(target: action.fields["from"]).intentName ?? "source"
            let to = LocatorSummary(target: action.fields["to"]).intentName ?? "destination"
            return "Drag \(from) to \(to)"
        case "invoke":
            let name = action.fields["name"]?.editableString.nilIfEmpty ?? "action"
            let target = LocatorSummary(target: action.fields["target"]).intentName ?? "target"
            return "Run \(name) on \(target)"
        case "look":
            if let target = LocatorSummary(target: action.fields["target"]).intentName {
                return "Read \(target)"
            }
            return "Read the current interface"
        case "find":
            let target = LocatorSummary(target: action.fields["locator"]).intentName ?? "element"
            return "Find \(target)"
        default:
            return action.tool.map { "Run \($0)" } ?? "Run action"
        }
    }

    private static func detail(for action: AxonRecipeAction) -> String? {
        switch action.tool {
        case "type", "click", "invoke":
            return nil
        case "scroll":
            let dx = action.fields["deltaX"]?.compactLiteral
            let dy = action.fields["deltaY"]?.compactLiteral
            let movement = [dx.map { "x \($0)" }, dy.map { "y \($0)" }].compactMap { $0 }.joined(separator: ", ")
            let context = LocatorSummary(target: action.fields["target"]).contextLine ?? action.fields["app"]?.editableString
            if movement.isEmpty {
                return context
            }
            return [context, movement].compactMap { $0?.nilIfEmpty }.joined(separator: " - ")
        case "drag":
            return action.fields["app"]?.editableString.nilIfEmpty
        case "keyboard":
            return action.fields["app"]?.editableString.nilIfEmpty
        case "find":
            return action.fields["app"]?.editableString.nilIfEmpty
        default:
            return nil
        }
    }

    private static func symbolName(for tool: String?) -> String {
        switch tool {
        case "click":
            return "cursorarrow.click"
        case "type":
            return "text.cursor"
        case "keyboard":
            return "keyboard"
        case "scroll":
            return "arrow.up.and.down"
        case "drag":
            return "hand.draw"
        case "invoke":
            return "bolt"
        case "look", "find":
            return "eye"
        default:
            return "gearshape"
        }
    }

    private static func symbolColor(for tool: String?) -> Color {
        switch tool {
        case "type", "keyboard":
            return RecipeEditorPalette.write
        case "click", "invoke", "drag":
            return RecipeEditorPalette.action
        case "look", "find":
            return RecipeEditorPalette.read
        case "scroll":
            return RecipeEditorPalette.motion
        default:
            return .secondary
        }
    }

    private static func parameters(in action: AxonRecipeAction) -> [String] {
        var names: [String] = []
        for key in ["value", "keys", "text"] {
            if let value = action.fields[key]?.editableString {
                names.append(contentsOf: parameterTokenNames(in: value))
            }
        }
        return Array(Set(names)).sorted()
    }
}
