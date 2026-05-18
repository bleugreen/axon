import SwiftUI

struct RecipeTextField: View {
    let label: String
    @Binding var value: String
    var prompt: String = "Optional"

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $value, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
        }
    }
}

struct RecipePickerField: View {
    let label: String
    @Binding var value: String
    let options: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(label, selection: $value) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RecipeToggleField: View {
    let label: String
    @Binding var value: String

    var body: some View {
        Toggle(label, isOn: Binding(
            get: { value == "true" },
            set: { value = $0 ? "true" : "false" }
        ))
        .font(.caption)
    }
}

enum RecipeEditorPalette {
    static let canvasBackground = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Color(nsColor: .underPageBackgroundColor)
    static let stepFill = Color(nsColor: .controlBackgroundColor).opacity(0.72)
    static let selectedStepFill = Color(red: 0.19, green: 0.23, blue: 0.20).opacity(0.56)
    static let quietFill = Color.secondary.opacity(0.07)
    static let pillBackground = Color.secondary.opacity(0.14)
    static let selectionFill = Color(red: 0.40, green: 0.52, blue: 0.43).opacity(0.22)
    static let selectionStroke = Color(red: 0.55, green: 0.68, blue: 0.57).opacity(0.72)
    static let debugCursor = Color(red: 0.82, green: 0.68, blue: 0.38).opacity(0.86)
    static let stepStroke = Color.secondary.opacity(0.15)
    static let breakpoint = Color(red: 0.67, green: 0.28, blue: 0.20)
    static let parameterFill = Color(red: 0.45, green: 0.55, blue: 0.46).opacity(0.22)
    static let parameterText = Color(red: 0.70, green: 0.82, blue: 0.70)
    static let write = Color(red: 0.62, green: 0.71, blue: 0.62)
    static let action = Color(red: 0.72, green: 0.61, blue: 0.45)
    static let read = Color(red: 0.55, green: 0.66, blue: 0.70)
    static let motion = Color(red: 0.68, green: 0.58, blue: 0.72)
    static let note = Color(red: 0.77, green: 0.68, blue: 0.45)
}
