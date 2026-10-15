import AgentHubCore
import AppKit
import SwiftUI

struct SessionDetailView: View {
    @Environment(AppState.self) private var state
    let session: AgentSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: session.agent.symbol)
                Text(session.title).font(.headline).lineLimit(1)
                StatusBadge(status: session.status)
                Spacer()
                if let commandLine = session.commandLine {
                    Text(commandLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button("Close") { state.close(session) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if let terminal = session.terminal {
                TerminalHostView(controller: terminal)
            } else {
                ChatView(session: session)
            }
        }
    }
}

/// Hosts a session's long-lived terminal view.
struct TerminalHostView: NSViewRepresentable {
    let controller: TerminalController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if controller.view.superview !== nsView { attach(to: nsView) }
    }

    private func attach(to container: NSView) {
        let view = controller.view
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}

struct ChatView: View {
    let session: AgentSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if session.messages.isEmpty {
                        Text("Send a message with the command bar below. Model: \(session.agent.model ?? "–")")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: session.messages.last?.text) { _, _ in
                if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .system:
            Label(message.text, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .user, .assistant:
            VStack(alignment: .leading, spacing: 4) {
                Text(message.role == .user ? "You" : "Assistant")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(message.text.isEmpty ? "…" : message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(message.role == .user ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
