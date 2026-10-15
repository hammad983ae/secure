import AgentHubCore
import AppKit
import SwiftUI

/// A conversation with one or more agents.
struct ChatScreen: View {
    @Environment(AppState.self) private var state
    let model: ConversationModel

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(model: model)
            if model.conversation.entries.isEmpty {
                ChatWelcome(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                timeline
            }
            Composer(model: model)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .padding(.top, 8)
        }
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.conversation.entries) { entry in
                        Group {
                            if let run = entry.run {
                                RunCard(run: run, model: model)
                            } else {
                                UserBubble(text: entry.text, date: entry.date)
                            }
                        }
                        .id(entry.id)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.conversation.entries.count)
            }
            .scrollIndicators(.automatic)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.conversation.updatedAt) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

struct ChatHeader: View {
    @Environment(AppState.self) private var state
    let model: ConversationModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.conversation.title)
                    .font(Theme.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ForEach(model.conversation.participants, id: \.agentID) { participant in
                        if let agent = state.agent(id: participant.agentID) {
                            HStack(spacing: 4) {
                                AgentAvatar(symbol: agent.symbol, color: AgentColors.color(for: agent), size: 14)
                                Text(agent.name).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    if model.conversation.participants.isEmpty {
                        Text("No agents yet").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            Spacer()
            FolderChip(model: model)
            if !model.conversation.usage.isEmpty {
                UsagePill(usage: model.conversation.usage, model: nil)
            }
            if model.isBusy {
                Button {
                    state.stopAll(in: model)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }
}

/// Shows and changes the folder terminal agents work in.
struct FolderChip: View {
    @Environment(AppState.self) private var state
    let model: ConversationModel

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(Theme.cyan)
                Text(label).lineLimit(1).truncationMode(.head)
            }
            .frame(maxWidth: 220)
        }
        .buttonStyle(GlassButtonStyle())
        .help(model.conversation.workingDirectory ?? "Choose the folder agents work in")
    }

    private var label: String {
        guard let path = model.conversation.workingDirectory, !path.isEmpty else { return "Choose folder" }
        return (path as NSString).lastPathComponent
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            state.setWorkingDirectory(url.path, for: model)
        }
    }
}

/// Empty-chat hero with suggestions.
struct ChatWelcome: View {
    @Environment(AppState.self) private var state
    let model: ConversationModel

    private struct Suggestion: Hashable {
        let mention: String
        let text: String
    }

    private let suggestions = [
        Suggestion(mention: "@claude", text: "Explain how this codebase is structured"),
        Suggestion(mention: "@codex", text: "Find and fix the failing tests"),
        Suggestion(mention: "@claude @codex", text: "Each propose a refactor for the slowest module"),
        Suggestion(mention: "@shell", text: "git status && git log --oneline -5"),
    ]

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            ZStack {
                Circle().fill(Theme.accentWide).frame(width: 74, height: 74).blur(radius: 26).opacity(0.7)
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(Circle().fill(Theme.accentWide))
                    .overlay(Circle().strokeBorder(.white.opacity(0.3)))
            }
            VStack(spacing: 8) {
                Text("What should your agents work on?")
                    .font(Theme.display(30))
                    .multilineTextAlignment(.center)
                Text("Mention an agent with @, or just describe the task and Agent Hub picks one.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        state.send("\(suggestion.mention) \(suggestion.text)", in: model)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(suggestion.mention).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.cyan)
                            Text(suggestion.text).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.leading)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                        .glassCard(radius: 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 620)
            HStack(spacing: 8) {
                ForEach(state.chatAgents.prefix(7)) { agent in
                    VStack(spacing: 5) {
                        AgentAvatar(symbol: agent.symbol, color: AgentColors.color(for: agent), size: 34)
                        Text("@\(agent.handle)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(width: 74)
                    .opacity(state.isInstalled(agent) == false ? 0.35 : 1)
                }
            }
            Spacer()
        }
        .padding(30)
    }
}

// MARK: - Entries

struct UserBubble: View {
    let text: String
    let date: Date

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 4) {
                MentionText(text: text)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(colors: [Theme.cyan.opacity(0.28), Theme.violet.opacity(0.30)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14)))
                Text(date, format: .dateTime.hour().minute())
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// Highlights `@mentions` in a message.
struct MentionText: View {
    let text: String

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        for (index, word) in words.enumerated() {
            var part = AttributedString(String(word))
            if word.hasPrefix("@"), word.count > 1 {
                part.swiftUI.foregroundColor = Theme.cyan
                part.swiftUI.font = .system(size: 13.5, weight: .semibold)
            }
            result += part
            if index < words.count - 1 { result += AttributedString(" ") }
        }
        return result
    }
}

/// One agent's reply: header, streamed text, tool steps, and actions.
struct RunCard: View {
    @Environment(AppState.self) private var state
    let run: AgentRun
    let model: ConversationModel

    private var color: Color { AgentColors.color(id: run.agentID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if run.messages.isEmpty && run.isActive {
                ThinkingIndicator(color: color)
            }
            ForEach(run.messages) { message in
                RunMessageView(message: message, accent: color)
            }
            if !run.isActive {
                footer
            }
        }
        .padding(16)
        .glassCard(radius: 16, tint: color, glow: run.isActive)
        .animation(.easeOut(duration: 0.2), value: run.messages.count)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AgentAvatar(symbol: run.agentSymbol, color: color, size: 30, active: run.status == .running)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.agentName).font(.system(size: 13, weight: .semibold))
                if let model = run.model, !model.isEmpty {
                    Text(model).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                }
            }
            StatusBadge(status: run.status)
            Spacer()
            if !run.usage.isEmpty || run.reportedCost != nil {
                UsagePill(usage: run.usage, model: run.model, cost: run.reportedCost)
            }
            if run.isActive {
                IconButton(symbol: "stop.fill", help: "Stop", tint: Theme.rose) {
                    state.stop(runID: run.id, in: model)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let finished = run.finishedAt {
                Text(durationText(from: run.startedAt, to: finished))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            if let agent = state.agent(id: run.agentID), agent.runsInTerminal {
                Button {
                    state.openInTerminal(run, in: model)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
                .buttonStyle(GlassButtonStyle())
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(run.replyText, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(GlassButtonStyle())
            .disabled(run.replyText.isEmpty)
        }
    }

    private func durationText(from start: Date, to end: Date) -> String {
        let seconds = Int(end.timeIntervalSince(start))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

struct ThinkingIndicator: View {
    let color: Color
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .opacity(0.3 + 0.7 * max(0, sin(phase + Double(index) * 0.9)))
            }
            Text("Working…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 }
        }
    }
}

struct RunMessageView: View {
    let message: ChatMessage
    let accent: Color

    var body: some View {
        switch message.role {
        case .assistant:
            MarkdownView(text: message.text)
        case .output:
            ScrollView(.horizontal) {
                Text(message.text.trimmingCharacters(in: .newlines))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textPrimary.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        case .tool:
            ToolStepView(message: message)
        case .system:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                Text(message.text).textSelection(.enabled)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
        case .user:
            Text(message.text)
        }
    }
}

/// A tool call: one line with status; expands to input and output.
struct ToolStepView: View {
    @Environment(AppState.self) private var state
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    stateIcon.frame(width: 14)
                    Text(displayName).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if message.toolState == .awaitingApproval {
                HStack(spacing: 8) {
                    Text("Allow this tool call?").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.amber)
                    Spacer()
                    Button("Deny") { state.resolveApproval(messageID: message.id, approved: false) }
                        .buttonStyle(GlassButtonStyle())
                    Button("Allow") { state.resolveApproval(messageID: message.id, approved: true) }
                        .buttonStyle(NeonButtonStyle())
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let args = message.toolArguments, !args.isEmpty {
                        Text(args).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                    if !message.text.isEmpty {
                        Divider().overlay(Theme.stroke)
                        Text(message.text.prefix(4000)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(borderColor))
    }

    private var displayName: String {
        let name = message.toolName ?? "tool"
        // MCP tools are exposed as server__tool.
        return name.replacingOccurrences(of: "__", with: " › ")
    }

    private var detail: String {
        (message.toolArguments ?? "").replacingOccurrences(of: "\n", with: " ")
    }

    private var borderColor: Color {
        message.toolState == .awaitingApproval ? Theme.amber.opacity(0.6) : Theme.stroke
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch message.toolState {
        case .awaitingApproval: Image(systemName: "hand.raised.fill").foregroundStyle(Theme.amber)
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark").foregroundStyle(Theme.emerald)
        case .failed: Image(systemName: "xmark").foregroundStyle(Theme.rose)
        case .denied: Image(systemName: "nosign").foregroundStyle(Theme.textTertiary)
        case nil: Image(systemName: "wrench.and.screwdriver")
        }
    }
}

struct UsagePill: View {
    let usage: TokenUsage
    let model: String?
    var cost: Double? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.fill").foregroundStyle(Theme.cyan)
            Text(Formatters.tokens(usage.total))
            if let shown = cost ?? model.flatMap({ ModelPricing.cost(model: $0, usage: usage) }) {
                Text("·").foregroundStyle(Theme.textTertiary)
                Text(Formatters.cost(shown))
            }
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.surfaceRaised))
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .help("In \(usage.input) · out \(usage.output) · cache read \(usage.cacheRead) · cache write \(usage.cacheWrite)")
    }
}
