import AgentHubCore
import SwiftUI

/// A closed session from history: what happened, and a way to pick it back up.
struct HistoryDetailView: View {
    @Environment(AppState.self) private var state
    let record: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: record.agentSymbol)
                Text(record.title).font(.headline).lineLimit(1)
                StatusBadge(status: record.status)
                Spacer()
                if !record.usage.isEmpty {
                    UsagePill(usage: record.usage, model: state.config.agents.first { $0.id == record.agentID }?.model ?? "")
                }
                Button(record.kind == .chat ? "Continue Chat" : "Run Again") { state.reopen(record) }
                    .buttonStyle(.borderedProminent)
                Button("Delete", role: .destructive) { state.deleteHistory(record) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Agent").foregroundStyle(.secondary)
                            Text(record.agentName)
                        }
                        GridRow {
                            Text("Started").foregroundStyle(.secondary)
                            Text(record.createdAt, format: .dateTime)
                        }
                        GridRow {
                            Text("Last active").foregroundStyle(.secondary)
                            Text(record.updatedAt, format: .dateTime)
                        }
                        if let directory = record.workingDirectory {
                            GridRow {
                                Text("Folder").foregroundStyle(.secondary)
                                Text(directory).textSelection(.enabled)
                            }
                        }
                        if let commandLine = record.commandLine {
                            GridRow {
                                Text("Command").foregroundStyle(.secondary)
                                Text(commandLine).font(.callout.monospaced()).textSelection(.enabled)
                            }
                        }
                        if let task = record.task, !task.isEmpty {
                            GridRow {
                                Text("Task").foregroundStyle(.secondary)
                                Text(task).textSelection(.enabled)
                            }
                        }
                    }

                    if record.kind == .chat {
                        Divider()
                        ForEach(record.messages) { message in
                            ChatBubble(message: message)
                                .disabled(true)
                        }
                    } else {
                        Text("Terminal output isn't saved. Run Again starts the same agent with the same task and folder.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
