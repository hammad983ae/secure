import AgentHubCore
import AppKit
import SwiftUI

/// ⌘K: start a task on one or more agents, or jump to an open session.
struct CommandPalette: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var task = ""
    @State private var chosen: Set<UUID> = []
    @State private var directory = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Session").font(.title2.bold())

            TextField("What should the agent do? (optional)", text: $task, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)

            Text("Agents").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.config.agents) { agent in
                        Toggle(isOn: binding(for: agent.id)) {
                            HStack {
                                Label(agent.name, systemImage: agent.symbol)
                                Text("@\(agent.handle)").foregroundStyle(.secondary)
                                if state.isInstalled(agent) == false {
                                    Text("not found on PATH").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)

            HStack {
                TextField("Working directory (terminal agents)", text: $directory)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…", action: chooseDirectory)
            }

            if !state.sessions.isEmpty {
                Text("Open sessions").font(.headline)
                ForEach(state.sessions.filter(matchesQuery)) { session in
                    Button {
                        state.select(session)
                        dismiss()
                    } label: {
                        HStack {
                            Label(session.title, systemImage: session.agent.symbol)
                            Spacer()
                            StatusBadge(status: session.status)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count > 1 ? "Start \(chosen.count) Sessions" : "Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            directory = state.config.defaultWorkingDirectory ?? ""
            if chosen.isEmpty, let first = state.config.agents.first { chosen = [first.id] }
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(id) },
            set: { isOn in if isOn { chosen.insert(id) } else { chosen.remove(id) } }
        )
    }

    private func matchesQuery(_ session: AgentSession) -> Bool {
        let query = task.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || session.title.localizedCaseInsensitiveContains(query)
    }

    private func start() {
        let dir = directory.trimmingCharacters(in: .whitespaces)
        for agent in state.config.agents where chosen.contains(agent.id) {
            state.startSession(agent: agent, task: task, workingDirectory: dir.isEmpty ? nil : dir)
        }
        dismiss()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }
}
