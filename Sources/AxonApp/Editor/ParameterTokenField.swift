import SwiftUI

struct ParameterTokenField: View {
    let label: String
    @Binding var value: String
    let inputNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !inputNames.isEmpty {
                    Picker("", selection: valueMode) {
                        Text("Literal").tag(ValueMode.literal)
                        Text("Input").tag(ValueMode.input)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
            }

            if valueMode.wrappedValue == .input, !inputNames.isEmpty {
                Picker("Input", selection: selectedInput) {
                    ForEach(inputNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 260, alignment: .leading)
            } else {
                TextField(label, text: $value, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            }
        }
    }

    private var exactInputName: String? {
        let tokens = parameterTokenNames(in: value)
        guard tokens.count == 1 else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "{{\(tokens[0])}}" ? tokens[0] : nil
    }

    private var valueMode: Binding<ValueMode> {
        Binding(
            get: {
                if let exactInputName, inputNames.contains(exactInputName) {
                    return .input
                }
                return .literal
            },
            set: { mode in
                switch mode {
                case .literal:
                    value = ""
                case .input:
                    value = "{{\(inputNames.first ?? "")}}"
                }
            }
        )
    }

    private var selectedInput: Binding<String> {
        Binding(
            get: { exactInputName ?? inputNames.first ?? "" },
            set: { value = "{{\($0)}}" }
        )
    }
}

private enum ValueMode: Hashable {
    case literal
    case input
}

struct ParameterChipRow: View {
    let names: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(RecipeEditorPalette.parameterFill))
                    .foregroundStyle(RecipeEditorPalette.parameterText)
            }
        }
    }
}
