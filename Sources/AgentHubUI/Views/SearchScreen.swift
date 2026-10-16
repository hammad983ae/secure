import AgentHubCore
import SwiftUI

/// Searches every chat: your messages, agent replies, tool commands, and tool output.
struct SearchScreen: View {
    @Environment(AppState.self) private var state
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.cyan)
                TextField("Search all chats, including tool output", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .glassCard(radius: 14, tint: focused ? Theme.cyan : nil, glow: focused)
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 30)
                .padding(.vertical, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(hits) { hit in
                        Button {
                            state.open(hit)
                        } label: {
                            SearchHitRow(hit: hit, query: query)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .onAppear { focused = true }
        .task(id: query) {
            // Wait for a pause in typing.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            hits = state.search(query)
        }
    }

    private var summary: String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Type to search \(state.conversations.count) chats." }
        if hits.isEmpty { return "No matches." }
        return hits.count >= 200 ? "Showing the 200 newest matches." : "\(hits.count) match\(hits.count == 1 ? "" : "es")"
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(hit.conversationTitle).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text("·").foregroundStyle(Theme.textTertiary)
                Text(hit.source).font(.system(size: 11.5)).foregroundStyle(Theme.cyan).lineLimit(1)
                Spacer()
                Text(hit.date, format: .relative(presentation: .named))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(highlighted)
                .font(.system(size: 12, design: hit.source.contains("·") ? .monospaced : .default))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 12)
        .contentShape(Rectangle())
    }

    /// The snippet with each query word highlighted.
    private var highlighted: AttributedString {
        var text = AttributedString(hit.snippet)
        var mark = AttributeContainer()
        mark.swiftUI.foregroundColor = Theme.textPrimary
        mark.swiftUI.backgroundColor = Theme.cyan.opacity(0.25)
        for word in query.split(whereSeparator: \.isWhitespace) {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text[searchRange].range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive]) {
                text[range].mergeAttributes(mark)
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return text
    }
}
