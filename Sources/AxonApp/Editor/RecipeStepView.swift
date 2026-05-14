import AxonCore
import SwiftUI

struct RecipeStepView: View {
    let index: Int
    @Binding var block: AxonRecipeBlock
    let isSelected: Bool
    let isBreakpoint: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let traceRecord: JSONValue?
    let inputNames: [String]
    let select: () -> Void
    let toggleBreakpoint: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            StepGutter(
                index: index,
                isBreakpoint: isBreakpoint,
                traceRecord: traceRecord,
                toggleBreakpoint: toggleBreakpoint
            )

            VStack(alignment: .leading, spacing: 12) {
                StepHeader(
                    block: block,
                    isSelected: isSelected,
                    canMoveUp: canMoveUp,
                    canMoveDown: canMoveDown,
                    moveUp: moveUp,
                    moveDown: moveDown,
                    duplicate: duplicate,
                    delete: delete
                )

                if isSelected, hasSelectedEditor {
                    Divider()
                    selectedEditor
                }

                if let error = traceError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? RecipeEditorPalette.selectedStepFill : RecipeEditorPalette.stepFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? RecipeEditorPalette.selectionStroke : RecipeEditorPalette.stepStroke, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Duplicate", action: duplicate)
            Button("Move Up", action: moveUp)
                .disabled(!canMoveUp)
            Button("Move Down", action: moveDown)
                .disabled(!canMoveDown)
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
    }

    @ViewBuilder
    private var selectedEditor: some View {
        switch block {
        case let .note(note):
            NoteStepEditor(note: Binding(
                get: { note },
                set: { block = .note($0) }
            ))
        case let .action(action):
            RecipeStepEditor(action: Binding(
                get: {
                    if case let .action(current) = block {
                        return current
                    }
                    return action
                },
                set: { block = .action($0) }
            ), inputNames: inputNames)
        }
    }

    private var hasSelectedEditor: Bool {
        switch block {
        case .note:
            return true
        case let .action(action):
            return action.hasPrimaryEditor
        }
    }

    private var traceError: String? {
        guard traceRecord?["success"] == .bool(false),
              case let .string(error)? = traceRecord?["error"]
        else {
            return nil
        }
        return error
    }
}

private struct StepHeader: View {
    let block: AxonRecipeBlock
    let isSelected: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    var body: some View {
        let intent = RecipeIntent(block: block)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: intent.symbolName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(intent.symbolColor)
                .frame(width: 22, height: 24)

            VStack(alignment: .leading, spacing: 5) {
                Text(intent.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)

                if let detail = intent.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(isSelected ? 3 : 1)
                        .textSelection(.enabled)
                }

            }
            Spacer(minLength: 0)
            if isSelected {
                StepActions(
                    canMoveUp: canMoveUp,
                    canMoveDown: canMoveDown,
                    moveUp: moveUp,
                    moveDown: moveDown,
                    duplicate: duplicate,
                    delete: delete
                )
            }
        }
    }
}

private struct StepGutter: View {
    let index: Int
    let isBreakpoint: Bool
    let traceRecord: JSONValue?
    let toggleBreakpoint: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Button(action: toggleBreakpoint) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(isBreakpoint ? "Remove breakpoint" : "Add breakpoint")

            Text(String(index + 1))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 34)
    }

    private var iconName: String {
        if traceRecord?["success"] == .bool(false) {
            return "xmark.circle.fill"
        }
        if traceRecord?["success"] == .bool(true) {
            return "checkmark.circle.fill"
        }
        return isBreakpoint ? "circle.fill" : "circle"
    }

    private var iconColor: Color {
        if traceRecord?["success"] == .bool(false) {
            return .red
        }
        if traceRecord?["success"] == .bool(true) {
            return .green
        }
        return isBreakpoint ? RecipeEditorPalette.breakpoint : .secondary
    }
}

private struct StepActions: View {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: moveUp) {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(!canMoveUp)
            Button(action: moveDown) {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(!canMoveDown)
            Button(action: duplicate) {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive, action: delete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.caption)
    }
}
