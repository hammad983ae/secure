import AgentHubCore
import SwiftUI

/// The always-visible command line at the bottom of the window.
struct CommandBar: View {
    @Environment(AppState.self) private var state
    @State private var text = ""
    @FocusState private var focused: Bool

    private var completions: [String] {
        CommandParser.completions(for: text, handles: state.config.agents.map { $0.handle.lowercased() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !completions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(completions, id: \.self) { handle in
                        Button("@\(handle)") { complete(handle) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "chevron.right.2")
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .focused($focused)
                    .onSubmit(submit)
                Button("Send", action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message = state.commandBarMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.bar)
    }

    private var placeholder: String {
        if let session = state.selectedSession {
            return "Message \(session.agent.name)…   (@agent starts a new session, @all broadcasts)"
        }
        return "@claude @codex fix the failing tests   (@all sends to every live session)"
    }

    private func submit() {
        let input = text
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        text = ""
        state.dispatch(input)
        focused = true
    }

    private func complete(_ handle: String) {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if !words.isEmpty { words.removeLast() }
        words.append("@\(handle) ")
        text = words.joined(separator: " ")
        focused = true
    }
}
