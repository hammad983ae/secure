import AgentHubCore
import SwiftUI

/// A closed terminal session (or a chat saved before chats existed).
struct HistoryDetailView: View {
    @Environment(AppState.self) private var state
    let record: SessionRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    AgentAvatar(symbol: record.agentSymbol, color: AgentColors.color(id: record.agentID), size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.title).font(Theme.display(20)).lineLimit(2)
                        Text(record.agentName).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    StatusBadge(status: record.status)
                    Spacer()
                    Button("Run Again") { state.rerun(record) }
                        .buttonStyle(NeonButtonStyle())
                    Button("Delete") { state.deleteHistory(record) }
                        .buttonStyle(GlassButtonStyle())
                }

                VStack(alignment: .leading, spacing: 10) {
                    detailRow("Started", record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    detailRow("Last active", record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    if let directory = record.workingDirectory { detailRow("Folder", directory) }
                    if let commandLine = record.commandLine { detailRow("Command", commandLine, mono: true) }
                    if let task = record.task, !task.isEmpty { detailRow("Task", task) }
                }
                .padding(16)
                .glassCard()

                if record.messages.isEmpty {
                    Text("Terminal output isn't saved. Run Again starts the same agent with the same task and folder.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(record.messages) { message in
                            RunMessageView(message: message, accent: AgentColors.color(id: record.agentID))
                        }
                    }
                    .padding(16)
                    .glassCard()
                }
            }
            .padding(26)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private func detailRow(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).hudLabel().frame(width: 90, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .textSelection(.enabled)
        }
    }
}
