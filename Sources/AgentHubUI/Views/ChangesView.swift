import AgentHubCore
import SwiftUI

/// The files an agent run changed, with per-file diffs and Keep / Undo.
struct ChangesView: View {
    @Environment(AppState.self) private var state
    let changes: RunChanges
    let runID: UUID
    let model: ConversationModel

    @State private var expanded = Set<String>()
    @State private var editedSinceRun: [String] = []
    @State private var showConflict = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(spacing: 0) {
                ForEach(changes.files) { file in
                    fileRow(file)
                    if expanded.contains(file.path) {
                        DiffLinesView(file: fileDiffs.first { $0.path == file.path })
                    }
                    if file.id != changes.files.last?.id {
                        Rectangle().fill(Theme.stroke).frame(height: 1)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.codeBackground))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if changes.truncated {
                Text("Diff is too large to show in full.").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
        .confirmationDialog("Files changed after this run", isPresented: $showConflict) {
            Button("Undo Anyway", role: .destructive) { undo(force: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These files were edited again after the agent finished, and undo would discard those edits too:\n\n" + editedSinceRun.joined(separator: "\n"))
        }
    }

    private var fileDiffs: [FileDiff] {
        expanded.isEmpty ? [] : FileDiff.parse(changes.diff)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.badge.ellipsis").foregroundStyle(Theme.cyan)
            Text("\(changes.files.count) file\(changes.files.count == 1 ? "" : "s") changed")
                .font(.system(size: 12.5, weight: .semibold))
            Text("+\(changes.additions)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.emerald)
            Text("−\(changes.deletions)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.rose)
            Spacer()
            switch changes.state {
            case .pending:
                if busy { ProgressView().controlSize(.small) }
                Button {
                    undo(force: false)
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(busy)
                Button {
                    state.keepChanges(runID: runID, in: model)
                } label: {
                    Label("Keep", systemImage: "checkmark")
                }
                .buttonStyle(NeonButtonStyle())
                .disabled(busy)
            case .kept:
                Label("Kept", systemImage: "checkmark.circle.fill").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.emerald)
            case .undone:
                Label("Undone", systemImage: "arrow.uturn.backward.circle.fill").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func fileRow(_ file: ChangedFile) -> some View {
        Button {
            if expanded.contains(file.path) { expanded.remove(file.path) } else { expanded.insert(file.path) }
        } label: {
            HStack(spacing: 8) {
                Text(file.status.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor(file.status))
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(statusColor(file.status).opacity(0.15)))
                Text(file.path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .strikethrough(changes.state == .undone)
                Spacer()
                if let added = file.additions, let removed = file.deletions {
                    Text("+\(added)").foregroundStyle(Theme.emerald)
                    Text("−\(removed)").foregroundStyle(Theme.rose)
                } else {
                    Text("binary").foregroundStyle(Theme.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded.contains(file.path) ? 90 : 0))
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusColor(_ status: ChangedFile.Status) -> Color {
        switch status {
        case .added: return Theme.emerald
        case .modified: return Theme.amber
        case .deleted: return Theme.rose
        }
    }

    private func undo(force: Bool) {
        busy = true
        Task {
            let edited = await state.undoChanges(runID: runID, in: model, force: force)
            busy = false
            if !edited.isEmpty {
                editedSinceRun = edited
                showConflict = true
            }
        }
    }
}

/// One file's diff lines, colored by kind.
struct DiffLinesView: View {
    static let maxLines = 600
    let file: FileDiff?

    var body: some View {
        if let file, !file.lines.isEmpty {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.lines.prefix(Self.maxLines).enumerated()), id: \.offset) { _, line in
                        Text(prefix(line.kind) + line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(foreground(line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 0.5)
                            .background(background(line.kind))
                    }
                    if file.lines.count > Self.maxLines {
                        Text("… \(file.lines.count - Self.maxLines) more lines")
                            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(10)
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 420)
        } else {
            Text("No text changes to show.")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(10)
        }
    }

    private func prefix(_ kind: FileDiff.Line.Kind) -> String {
        switch kind {
        case .added: return "+ "
        case .removed: return "− "
        case .context: return "  "
        case .hunk, .note: return ""
        }
    }

    private func foreground(_ kind: FileDiff.Line.Kind) -> Color {
        switch kind {
        case .added: return Theme.emerald
        case .removed: return Theme.rose
        case .hunk: return Theme.violet
        case .note: return Theme.textTertiary
        case .context: return Theme.textSecondary
        }
    }

    private func background(_ kind: FileDiff.Line.Kind) -> Color {
        switch kind {
        case .added: return Theme.emerald.opacity(0.08)
        case .removed: return Theme.rose.opacity(0.08)
        case .hunk: return Theme.violet.opacity(0.08)
        default: return .clear
        }
    }
}
