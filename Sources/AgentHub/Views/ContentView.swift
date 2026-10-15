import AgentHubCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if let session = state.selectedSession {
                        SessionDetailView(session: session)
                            .id(session.id)
                    } else {
                        TaskBoardView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                CommandBar()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.showPalette = true
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .help("Start a session (⌘K)")
            }
        }
        .sheet(isPresented: $state.showPalette) {
            CommandPalette()
        }
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        List(selection: $state.selection) {
            Label("Task Board", systemImage: "rectangle.3.group")
                .tag(SidebarItem.board)

            Section("Sessions") {
                if state.sessions.isEmpty {
                    Text("No sessions yet. Press ⌘K.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(state.sessions) { session in
                    SessionRow(session: session)
                        .tag(SidebarItem.session(session.id))
                        .contextMenu {
                            Button("Close Session", role: .destructive) { state.close(session) }
                        }
                }
            }

            Section("Agents") {
                ForEach(state.config.agents) { agent in
                    AgentRow(agent: agent)
                }
            }
        }
        .onChange(of: state.selection) { _, newValue in
            if case let .session(id) = newValue { state.sessions.first { $0.id == id }?.unread = false }
        }
    }
}

struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.agent.symbol)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                    .fontWeight(session.unread ? .semibold : .regular)
                StatusBadge(status: session.status)
            }
        }
    }
}

struct AgentRow: View {
    @Environment(AppState.self) private var state
    let agent: AgentDefinition

    var body: some View {
        HStack {
            Label(agent.name, systemImage: agent.symbol)
            Spacer()
            if state.isInstalled(agent) == false {
                Text("not found")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("`\(agent.command)` isn't on your shell's PATH")
            }
            Button {
                state.startSession(agent: agent, task: nil)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Start \(agent.name)")
        }
    }
}

struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(status.color).frame(width: 7, height: 7)
            Text(status.title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

extension SessionStatus {
    var color: Color {
        switch self {
        case .running: return .blue
        case .needsInput: return .orange
        case .done: return .green
        case .failed: return .red
        }
    }
}
