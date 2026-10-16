import AgentHubCore
import AppKit
import SwiftUI

/// A borderless panel that can take keyboard focus.
private final class QuickPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The floating ⌥Space prompt: type a task, press Return, and it starts a new chat.
@MainActor
final class QuickPromptController {
    private let panel: QuickPromptPanel
    private weak var state: AppState?
    private var resignObserver: NSObjectProtocol?

    init(state: AppState) {
        self.state = state
        panel = QuickPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 150),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: QuickPromptView(
            onSubmit: { [weak self] text in self?.submit(text) },
            onCancel: { [weak self] in self?.close() }
        ).environment(state))
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func toggle() {
        panel.isVisible ? close() : show()
    }

    func show() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + frame.height * 0.68))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .quickPromptShown, object: nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    private func submit(_ text: String) {
        close()
        guard let state else { return }
        state.quickAsk(text)
        state.showMainWindow()
    }
}

extension Notification.Name {
    static let quickPromptShown = Notification.Name("AgentHubQuickPromptShown")
}

struct QuickPromptView: View {
    @Environment(AppState.self) private var state
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.accentWide)
                TextField("Ask your agents… @claude fix the login bug", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .medium))
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand(perform: onCancel)
            }
            HStack(spacing: 6) {
                ForEach(state.chatAgents.prefix(6)) { agent in
                    Button {
                        if !text.contains("@\(agent.handle)") { text = "@\(agent.handle) " + text }
                        focused = true
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(AgentColors.color(for: agent)).frame(width: 6, height: 6)
                            Text("@\(agent.handle)")
                        }
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.surface))
                        .overlay(Capsule().strokeBorder(Theme.stroke))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("⏎ new chat · esc close")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(20)
        .frame(width: 640)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Theme.void, Theme.deep], startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Theme.cyan.opacity(0.6), Theme.violet.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .foregroundStyle(Theme.textPrimary)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .quickPromptShown)) { _ in
            text = ""
            focused = true
        }
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        text = ""
        onSubmit(value)
    }
}
