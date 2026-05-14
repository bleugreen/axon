import AxonCore
import SwiftUI

struct RecipeStepEditor: View {
    @Binding var action: AxonRecipeAction
    let inputNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch action.tool {
            case "type":
                TypeActionEditor(action: $action, inputNames: inputNames)
            case "click":
                ClickActionEditor()
            case "keyboard":
                KeyboardActionEditor(action: $action, inputNames: inputNames)
            case "scroll":
                ScrollActionEditor(action: $action)
            case "drag":
                DragActionEditor(action: $action)
            case "invoke":
                InvokeActionEditor(action: $action)
            case "look":
                LookActionEditor(action: $action)
            case "find":
                FindActionEditor()
            default:
                UnsupportedActionEditor(action: action)
            }
        }
    }
}

extension AxonRecipeAction {
    var hasPrimaryEditor: Bool {
        switch tool {
        case "type", "keyboard", "scroll", "drag", "invoke", "look":
            return true
        case "click", "find":
            return false
        default:
            return true
        }
    }
}

struct NoteStepEditor: View {
    @Binding var note: AxonRecipeNote

    var body: some View {
        RecipeTextField(
            label: "Note",
            value: Binding(
                get: { note.text ?? "" },
                set: { note.text = $0 }
            ),
            prompt: "Add context for this part of the recipe"
        )
    }
}

private struct TypeActionEditor: View {
    @Binding var action: AxonRecipeAction
    let inputNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ParameterTokenField(label: "Text", value: field("value"), inputNames: inputNames)
        }
    }

    private func field(_ key: String) -> Binding<String> {
        Binding(
            get: { action.fields[key]?.editableString ?? "" },
            set: { action.setEditableString(value: $0, forKey: key) }
        )
    }
}

private struct ClickActionEditor: View {
    var body: some View {
        EmptyView()
    }
}

private struct KeyboardActionEditor: View {
    @Binding var action: AxonRecipeAction
    let inputNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ParameterTokenField(label: "Keys", value: field("keys"), inputNames: inputNames)
            ParameterTokenField(label: "Text", value: field("text"), inputNames: inputNames)
        }
    }

    private func field(_ key: String) -> Binding<String> {
        Binding(
            get: { action.fields[key]?.editableString ?? "" },
            set: { action.setEditableString(value: $0, forKey: key) }
        )
    }
}

private struct ScrollActionEditor: View {
    @Binding var action: AxonRecipeAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RecipeTextField(label: "Delta X", value: field("deltaX"))
                RecipeTextField(label: "Delta Y", value: field("deltaY"))
            }
        }
    }

    private func field(_ key: String) -> Binding<String> {
        Binding(
            get: { action.fields[key]?.editableString ?? "" },
            set: { action.setEditableString(value: $0, forKey: key) }
        )
    }
}

private struct DragActionEditor: View {
    @Binding var action: AxonRecipeAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecipeTextField(label: "Duration ms", value: field("durationMs"))
        }
    }

    private func field(_ key: String) -> Binding<String> {
        Binding(
            get: { action.fields[key]?.editableString ?? "" },
            set: { action.setEditableString(value: $0, forKey: key) }
        )
    }
}

private struct InvokeActionEditor: View {
    @Binding var action: AxonRecipeAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecipeTextField(label: "Action", value: field("name"))
        }
    }

    private func field(_ key: String) -> Binding<String> {
        Binding(
            get: { action.fields[key]?.editableString ?? "" },
            set: { action.setEditableString(value: $0, forKey: key) }
        )
    }
}

private struct LookActionEditor: View {
    @Binding var action: AxonRecipeAction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecipeTextField(label: "Target", value: field("target"))
            RecipeToggleField(label: "Screenshot", value: field("screenshot"))
            RecipeToggleField(label: "Screen text", value: field("screenText"))
            RecipeToggleField(label: "Sensitive", value: field("sensitive"))
        }
    }

    private func field(_ key: String) -> Binding<String> {
        Binding(
            get: { action.fields[key]?.editableString ?? "" },
            set: { action.setEditableString(value: $0, forKey: key) }
        )
    }
}

private struct FindActionEditor: View {
    var body: some View {
        EmptyView()
    }
}

private struct UnsupportedActionEditor: View {
    let action: AxonRecipeAction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This action has fields the editor does not understand yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(action.fields.keys.filter { $0 != "id" && $0 != "tool" }.sorted(), id: \.self) { key in
                Text("\(key): \(action.fields[key]?.compactDescription ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
