import AxonCore
import SwiftUI

struct RecipeCanvas: View {
    @Binding var blocks: [AxonRecipeBlock]
    @Binding var editorMetadata: AxonRecipeEditorMetadata
    @Binding var selectedBlockID: String?
    let inputNames: [String]
    let trace: [JSONValue]

    var body: some View {
        VStack(spacing: 0) {
            RecipeSequenceHeader(stepCount: blocks.count, addNote: addNote)
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(blocks.indices, id: \.self) { index in
                        RecipeStepView(
                            index: index,
                            block: $blocks[index],
                            isSelected: selectedBlockID == blocks[index].id,
                            isBreakpoint: isBreakpoint(blocks[index]),
                            canMoveUp: index > 0,
                            canMoveDown: index < blocks.count - 1,
                            traceRecord: traceRecord(for: blocks[index]),
                            inputNames: inputNames,
                            select: { selectedBlockID = blocks[index].id },
                            toggleBreakpoint: { toggleBreakpoint(blocks[index]) },
                            moveUp: { move(index, by: -1) },
                            moveDown: { move(index, by: 1) },
                            duplicate: { duplicate(index) },
                            delete: { delete(index) }
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 1040)
                .frame(maxWidth: .infinity)
            }
        }
        .background(RecipeEditorPalette.canvasBackground)
    }

    private func traceRecord(for block: AxonRecipeBlock) -> JSONValue? {
        guard let id = block.id else {
            return nil
        }
        return trace.first { record in
            record["actionId"] == .string(id)
        }
    }

    private func isBreakpoint(_ block: AxonRecipeBlock) -> Bool {
        guard let id = block.id else {
            return false
        }
        return editorMetadata.breakpoints.contains(id)
    }

    private func toggleBreakpoint(_ block: AxonRecipeBlock) {
        guard let id = block.id else {
            return
        }
        if let index = editorMetadata.breakpoints.firstIndex(of: id) {
            editorMetadata.breakpoints.remove(at: index)
        } else {
            editorMetadata.breakpoints.append(id)
        }
    }

    private func move(_ index: Int, by delta: Int) {
        let destination = index + delta
        guard blocks.indices.contains(index), blocks.indices.contains(destination) else {
            return
        }
        blocks.swapAt(index, destination)
    }

    private func duplicate(_ index: Int) {
        guard blocks.indices.contains(index) else {
            return
        }
        var copy = blocks[index]
        copy.id = nextBlockID()
        blocks.insert(copy, at: index + 1)
        selectedBlockID = copy.id
    }

    private func delete(_ index: Int) {
        guard blocks.indices.contains(index) else {
            return
        }
        let removedID = blocks[index].id
        blocks.remove(at: index)
        if let removedID {
            editorMetadata.breakpoints.removeAll { $0 == removedID }
        }
        if selectedBlockID == removedID {
            selectedBlockID = blocks[safe: min(index, blocks.count - 1)]?.id
        }
    }

    private func addNote() {
        blocks.append(.note(AxonRecipeNote(fields: ["note": .string("New note")])))
        blocks[blocks.count - 1].id = nextBlockID()
        selectedBlockID = blocks.last?.id
    }

    private func nextBlockID() -> String {
        let usedIDs = Set(blocks.compactMap(\.id))
        var nextID = 1
        while true {
            let id = "b\(String(format: "%03d", nextID))"
            if !usedIDs.contains(id) {
                return id
            }
            nextID += 1
        }
    }
}

private struct RecipeSequenceHeader: View {
    let stepCount: Int
    let addNote: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(stepCount) step\(stepCount == 1 ? "" : "s")")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: addNote) {
                Label("Add Note", systemImage: "note.text.badge.plus")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 11)
        .background(RecipeEditorPalette.canvasBackground)
    }
}

struct EditorStatusBar: View {
    let status: String
    let error: String?
    let traceCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(status)
                .foregroundStyle(error == nil ? Color.secondary : Color.red)
            if traceCount > 0 {
                Text("\(traceCount) action\(traceCount == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(RecipeEditorPalette.sidebarBackground)
    }
}
