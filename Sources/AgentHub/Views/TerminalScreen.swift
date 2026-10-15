import AgentHubCore
import AppKit
import SwiftUI

/// An interactive terminal running an agent.
struct TerminalScreen: View {
    @Environment(AppState.self) private var state
    let session: TerminalSession
    let isFocused: Bool
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalHostView(controller: session.controller)
                .padding(8)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isFocused ? Theme.cyan.opacity(0.35) : Theme.stroke))
                .padding(.horizontal, 12)
            inputBar
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AgentAvatar(symbol: session.agent.symbol, color: AgentColors.color(for: session.agent), size: 26,
                        active: session.status == .running)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(Theme.title).lineLimit(1)
                Text(session.commandLine)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            StatusBadge(status: session.status)
            Spacer(minLength: 8)
            IconButton(symbol: state.isInSplit(session) ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                       help: state.isInSplit(session) ? "Remove from split view" : "Add to split view (⌘D)") {
                state.toggleSplit(session)
            }
            IconButton(symbol: "xmark", help: "Close terminal") { state.close(session) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { state.select(session) }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.cyan)
            TextField("Type into \(session.agent.name) and press ⏎", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .onSubmit {
                    state.sendToTerminal(input, session)
                    input = ""
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassCard(radius: 10)
        .padding(12)
    }
}

/// Up to four terminals side by side. Clicking a pane's header focuses it.
struct TerminalSplitScreen: View {
    @Environment(AppState.self) private var state
    let sessions: [TerminalSession]

    var body: some View {
        HSplitView {
            ForEach(sessions) { session in
                TerminalScreen(session: session, isFocused: state.selectedTerminal?.id == session.id)
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
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
