import AxonCore
import SwiftUI

struct AxnStepEditor: View {
    @Binding var action: AxnAction
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

extension AxnAction {
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
    @Binding var note: AxnNote

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
    @Binding var action: AxnAction
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
    @Binding var action: AxnAction
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
    @Binding var action: AxnAction

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
    @Binding var action: AxnAction

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
    @Binding var action: AxnAction

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
    @Binding var action: AxnAction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecipeToggleField(label: "Screenshot", value: field("screenshot"))
            RecipeToggleField(label: "Screen text", value: field("screenText"))
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
    let action: AxnAction

    var body: some View {
        Text("The editor doesn't render this action's fields yet. The recipe will still replay; open an issue at github.com/bleugreen/axon if you'd like editing support.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
