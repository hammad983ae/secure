import AgentHubCore
import SwiftUI

/// The chat input: multi-line, with @mention autocomplete and quick agent chips.
struct Composer: View {
    @Environment(AppState.self) private var state
    let model: ConversationModel
    @State private var text = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var promptSuggestions: [SavedPrompt] {
        PromptLibrary.completions(for: text, prompts: state.config.prompts)
    }

    private var suggestions: [AgentDefinition] {
        let handles = CommandParser.completions(for: text, handles: state.chatAgents.map { $0.handle.lowercased() })
        return handles.compactMap { state.agent(handle: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty {
                mentionMenu
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !promptSuggestions.isEmpty {
                promptMenu
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Message your agents — @claude, @codex, @all, or /prompt…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...8)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if !suggestions.isEmpty { complete(suggestions[min(highlighted, suggestions.count - 1)]); return .handled }
                        if !promptSuggestions.isEmpty, !text.contains(" ") {
                            let prompt = promptSuggestions[min(highlighted, promptSuggestions.count - 1)]
                            if text.dropFirst().lowercased() != prompt.name.lowercased() { completePrompt(prompt); return .handled }
                        }
                        submit()
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        if let first = suggestions.first { complete(first); return .handled }
                        if !promptSuggestions.isEmpty {
                            completePrompt(promptSuggestions[min(highlighted, promptSuggestions.count - 1)])
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.downArrow) {
                        let count = suggestions.isEmpty ? promptSuggestions.count : suggestions.count
                        guard count > 0 else { return .ignored }
                        highlighted = min(highlighted + 1, count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !suggestions.isEmpty || !promptSuggestions.isEmpty else { return .ignored }
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                    .onChange(of: text) { _, _ in highlighted = 0 }

                HStack(spacing: 6) {
                    ForEach(state.chatAgents.prefix(5)) { agent in
                        Button {
                            insertMention(agent)
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
                    if state.isRouting { ProgressView().controlSize(.small) }
                    Text("⏎ send · ⇧⏎ new line")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(canSend ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surfaceRaised)))
                            .shadow(color: Theme.violet.opacity(canSend ? 0.6 : 0), radius: 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(14)
            .glassCard(radius: 18, tint: focused ? Theme.cyan : nil, glow: focused)
            .animation(.easeOut(duration: 0.2), value: focused)

            if let notice = state.notice {
                Text(notice)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: suggestions.count)
        .onAppear { focused = true }
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var mentionMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, agent in
                Button {
                    complete(agent)
                } label: {
                    HStack(spacing: 10) {
                        AgentAvatar(symbol: agent.symbol, color: AgentColors.color(for: agent), size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 6) {
                                Text(agent.name).font(.system(size: 12.5, weight: .semibold))
                                Text("@\(agent.handle)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.cyan)
                            }
                            if !agent.summary.isEmpty {
                                Text(agent.summary).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(index == highlighted ? Theme.cyan.opacity(0.14) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(maxWidth: 420)
        .glassCard(radius: 12)
    }

    private var promptMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(promptSuggestions.enumerated()), id: \.element.id) { index, prompt in
                Button {
                    completePrompt(prompt)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "text.badge.star")
                            .foregroundStyle(Theme.violet)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 6) {
                                Text("/\(prompt.name)").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.cyan)
                                Text(prompt.title).font(.system(size: 12.5, weight: .medium))
                            }
                            Text(prompt.agents.isEmpty ? "Uses the agents you mention" : "Default: " + prompt.agents.map { "@\($0)" }.joined(separator: " "))
                                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(index == highlighted ? Theme.violet.opacity(0.16) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(maxWidth: 460)
        .glassCard(radius: 12)
    }

    private func completePrompt(_ prompt: SavedPrompt) {
        text = "/\(prompt.name) "
        highlighted = 0
        focused = true
    }

    private func submit() {
        guard canSend else { return }
        let input = text
        text = ""
        state.send(input, in: model)
        focused = true
    }

    private func complete(_ agent: AgentDefinition) {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if !words.isEmpty { words.removeLast() }
        words.append("@\(agent.handle) ")
        text = words.joined(separator: " ")
        focused = true
    }

    private func insertMention(_ agent: AgentDefinition) {
        let mention = "@\(agent.handle)"
        if !text.contains(mention) {
            text = mention + " " + text
        }
        focused = true
    }
}
