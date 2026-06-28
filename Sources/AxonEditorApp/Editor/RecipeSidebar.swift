import AxonCore
import SwiftUI

enum EditorSidebarLayer: String, CaseIterable {
    case inputs
    case tree

    var title: String {
        switch self {
        case .inputs:
            return "Inputs"
        case .tree:
            return "AX Tree"
        }
    }

    var symbolName: String {
        switch self {
        case .inputs:
            return "slider.horizontal.3"
        case .tree:
            return "square.stack.3d.down.right"
        }
    }
}

struct EditorSidebar: View {
    let appName: String?
    let actedOnTarget: JSONValue?
    @Binding var args: [AxonRecipeArgument]
    @Binding var selectedIndex: Int?
    @Binding var selectedLayer: EditorSidebarLayer
    let treeRefreshToken: Int
    let hideSidebar: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let appName {
                            Text(appName)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                        }
                        Text("Recipe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: hideSidebar) {
                        Label("Hide Sidebar", systemImage: "sidebar.left")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Hide sidebar")
                }

                HStack {
                    ForEach(EditorSidebarLayer.allCases, id: \.self) { layer in
                        Button {
                            selectedLayer = layer
                        } label: {
                            Label(layer.title, systemImage: layer.symbolName)
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help(layer.title)
                        .foregroundStyle(selectedLayer == layer ? RecipeEditorPalette.debugCursor : .secondary)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            switch selectedLayer {
            case .inputs:
                RecipeInputsSidebar(args: $args, selectedIndex: $selectedIndex)
            case .tree:
                AXTreeInspector(appName: appName, actedOnTarget: actedOnTarget, refreshToken: treeRefreshToken)
            }
        }
        .background(RecipeEditorPalette.sidebarBackground)
    }
}

private struct RecipeInputsSidebar: View {
    @Binding var args: [AxonRecipeArgument]
    @Binding var selectedIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inputs")
                    .font(.headline)
                Spacer()
                Button {
                    args.append(AxonRecipeArgument(fields: [
                        "name": .string("new_input"),
                        "type": .string("string")
                    ]))
                    selectedIndex = args.indices.last
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Add input")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .padding(.top, 12)

            if args.isEmpty {
                Spacer()
                Text("No inputs")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(args.indices, id: \.self) { index in
                            if selectedIndex == index {
                                ParameterEditor(arg: $args[index], done: {
                                    selectedIndex = nil
                                }) {
                                    deleteParameter(at: index)
                                }
                            } else {
                                ParameterRow(arg: args[index])
                                    .onTapGesture {
                                        selectedIndex = index
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 18)
                }
            }
        }
    }

    private func deleteParameter(at index: Int) {
        guard args.indices.contains(index) else {
            return
        }
        args.remove(at: index)
        selectedIndex = args[safe: min(index, args.count - 1)] == nil ? nil : min(index, args.count - 1)
    }
}

private struct ParameterRow: View {
    let arg: AxonRecipeArgument

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(arg.fields["name"]?.editableString.nilIfEmpty ?? "unnamed")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                if let defaultValue = arg.fields["default"]?.compactLiteral.nilIfEmpty {
                    Text("Default: \(defaultValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let description = arg.fields["description"]?.editableString.nilIfEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(arg.fields["type"]?.editableString.nilIfEmpty ?? "string")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(RecipeEditorPalette.pillBackground))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(RecipeEditorPalette.quietFill)
        )
        .contentShape(Rectangle())
    }
}

private struct ParameterEditor: View {
    @Binding var arg: AxonRecipeArgument
    let done: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                RecipeTextField(label: "Name", value: field("name"))
                Button(action: done) {
                    Label("Done", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Close input editor")
                .padding(.top, 20)
                Button(role: .destructive, action: delete) {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Delete input")
                .padding(.top, 20)
            }
            RecipePickerField(label: "Type", value: field("type"), options: ["string", "number", "bool", "path", "email", "secret"])
            RecipeTextField(label: "Description", value: field("description"))
            RecipeTextField(label: "Default", value: field("default"))
            if arg.fields["source"] != nil {
                RecipeTextField(label: "Source", value: field("source"))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(RecipeEditorPalette.selectionFill))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(RecipeEditorPalette.selectionStroke, lineWidth: 1)
        )
    }

    private func field(_ key: String) -> Binding<String> {
        Binding(
            get: { arg.fields[key]?.editableString ?? "" },
            set: { value in
                if value.isEmpty {
                    arg.fields.removeValue(forKey: key)
                } else {
                    arg.fields[key] = .string(value)
                }
            }
        )
    }
}

struct SidebarRevealRail: View {
    let showSidebar: (EditorSidebarLayer) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Button {
                showSidebar(.inputs)
            } label: {
                Label("Inputs", systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Show inputs")
            .padding(.top, 14)

            Button {
                showSidebar(.tree)
            } label: {
                Label("AX Tree", systemImage: EditorSidebarLayer.tree.symbolName)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Show AX tree")

            Spacer()
        }
        .frame(width: 42)
        .background(RecipeEditorPalette.sidebarBackground)
    }
}
