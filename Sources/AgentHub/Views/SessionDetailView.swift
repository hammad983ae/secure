import AgentHubCore
import AppKit
import SwiftUI

struct SessionDetailView: View {
    @Environment(AppState.self) private var state
    let session: AgentSession
    /// In split view, the focused pane receives command-bar input.
    let isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let terminal = session.terminal {
                TerminalHostView(controller: terminal)
            } else {
                ChatView(session: session)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: session.agent.symbol)
            Text(session.title).font(.headline).lineLimit(1)
            StatusBadge(status: session.status)
            Spacer(minLength: 8)
            if let commandLine = session.commandLine {
                Text(commandLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if session.isChat, !session.usage.isEmpty {
                UsagePill(usage: session.usage, model: session.agent.model ?? "")
            }
            if session.isBusy {
                Button("Stop") { state.stop(session) }
            }
            Button {
                state.toggleSplit(session)
            } label: {
                Image(systemName: state.isInSplit(session) ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
            }
            .buttonStyle(.borderless)
            .help(state.isInSplit(session) ? "Remove from split view" : "Add to split view")
            Button {
                state.close(session)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isFocused ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { state.select(session) }
    }
}

/// Up to four sessions side by side. Clicking a pane's header focuses it.
struct SplitSessionsView: View {
    @Environment(AppState.self) private var state
    let sessions: [AgentSession]

    var body: some View {
        HSplitView {
            ForEach(sessions) { session in
                SessionDetailView(session: session, isFocused: state.selectedSession?.id == session.id)
                    .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        if state.selectedSession?.id == session.id {
                            Rectangle().fill(Color.accentColor).frame(height: 2)
                        }
                    }
            }
        }
    }
}

struct UsagePill: View {
    let usage: TokenUsage
    let model: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "number")
            Text(Formatters.tokens(usage.total))
            if let cost = ModelPricing.cost(model: model, usage: usage) {
                Text("· \(Formatters.cost(cost))")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1), in: Capsule())
        .help("In \(usage.input) · out \(usage.output) · cache read \(usage.cacheRead) · cache write \(usage.cacheWrite)")
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
                    if session.isBusy {
                        ProgressView().controlSize(.small)
                            .id("progress")
                    }
                }
                .padding()
            }
            .onChange(of: session.messages.last) { _, last in
                if let last { proxy.scrollTo(last.id, anchor: .bottom) }
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
                .textSelection(.enabled)
        case .tool:
            ToolCallView(message: message)
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

/// A tool call in a chat: name, arguments, result, and approve/deny when needed.
struct ToolCallView: View {
    @Environment(AppState.self) private var state
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                stateIcon
                Text(message.toolName ?? "tool").font(.callout.monospaced().bold())
                Text(stateTitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(expanded ? "Hide details" : "Details") { expanded.toggle() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if message.toolState == .awaitingApproval {
                Text(argumentsPreview)
                    .font(.caption.monospaced())
                    .lineLimit(6)
                    .textSelection(.enabled)
                HStack {
                    Button("Allow") { state.resolveApproval(messageID: message.id, approved: true) }
                        .keyboardShortcut(.defaultAction)
                    Button("Deny", role: .destructive) { state.resolveApproval(messageID: message.id, approved: false) }
                }
            }
            if expanded {
                Text("Input").font(.caption.bold())
                Text(argumentsPreview).font(.caption.monospaced()).textSelection(.enabled)
                if !message.text.isEmpty {
                    Text("Result").font(.caption.bold())
                    Text(message.text).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var argumentsPreview: String {
        let raw = message.toolArguments ?? ""
        return raw.isEmpty ? "{}" : raw
    }

    private var stateTitle: String {
        switch message.toolState {
        case .awaitingApproval: return "wants to run"
        case .running: return "running…"
        case .succeeded: return "done"
        case .failed: return "failed"
        case .denied: return "denied"
        case nil: return ""
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch message.toolState {
        case .awaitingApproval: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .denied: Image(systemName: "nosign").foregroundStyle(.secondary)
        case nil: Image(systemName: "wrench.and.screwdriver")
        }
    }
}
