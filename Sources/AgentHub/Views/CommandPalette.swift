import AgentHubCore
import AppKit
import SwiftUI

/// ⌘K: start agents in interactive terminals, or jump to a chat.
struct CommandPalette: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var directory = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.cyan)
                TextField("Search chats, or filter agents…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
            }
            .padding(12)
            .glassCard(radius: 12)

            Text("Open a terminal").hudLabel()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(terminalAgents) { agent in
                    Button {
                        let dir = directory.trimmingCharacters(in: .whitespaces)
                        state.startTerminal(agent: agent, task: nil, workingDirectory: dir.isEmpty ? nil : dir)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            AgentAvatar(symbol: agent.symbol, color: AgentColors.color(for: agent), size: 22)
                            Text(agent.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .glassCard(radius: 10, tint: AgentColors.color(for: agent))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isInstalled(agent) == false)
                    .opacity(state.isInstalled(agent) == false ? 0.4 : 1)
                }
            }

            HStack {
                TextField("Folder (optional)", text: $directory)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .glassCard(radius: 8)
                Button("Choose…", action: chooseDirectory).buttonStyle(GlassButtonStyle())
            }

            if !matchingChats.isEmpty {
                Text("Chats").hudLabel()
                ForEach(matchingChats.prefix(6)) { model in
                    Button {
                        state.selection = .chat(model.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(Theme.textTertiary)
                            Text(model.conversation.title).lineLimit(1)
                            Spacer()
                            Text(model.conversation.updatedAt, format: .relative(presentation: .named))
                                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button("New Chat") {
                    state.newConversation()
                    dismiss()
                }
                .buttonStyle(NeonButtonStyle())
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(LinearGradient(colors: [Theme.void, Theme.deep], startPoint: .top, endPoint: .bottom))
        .foregroundStyle(Theme.textPrimary)
        .preferredColorScheme(.dark)
        .onAppear { directory = state.config.defaultWorkingDirectory ?? "" }
    }

    private var terminalAgents: [AgentDefinition] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return state.config.agents.filter { $0.runsInTerminal && (q.isEmpty || $0.name.lowercased().contains(q) || $0.handle.contains(q)) }
    }

    private var matchingChats: [ConversationModel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return state.sortedConversations.filter {
            !$0.conversation.entries.isEmpty && (q.isEmpty || $0.conversation.title.localizedCaseInsensitiveContains(q))
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }
}
