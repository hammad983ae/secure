import AgentHubCore
import SwiftUI

/// Mission Control: every run and terminal at a glance, by status.
struct BoardScreen: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let items = state.boardItems
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mission Control").font(Theme.display(26))
                    Text("Everything your agents are doing, live.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button {
                    state.newConversation()
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
                .buttonStyle(NeonButtonStyle())
            }

            HStack(spacing: 12) {
                ForEach(SessionStatus.allCases, id: \.self) { status in
                    let count = items.filter { $0.status == status }.count
                    MetricTile(title: status.title, value: "\(count)", color: status.color)
                }
            }

            if items.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 30)).accentGradient()
                    Text("Nothing running yet").font(Theme.title)
                    Text("Start a chat and mention an agent to see it here.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(SessionStatus.allCases, id: \.self) { status in
                            column(status, items: items.filter { $0.status == status })
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(26)
    }

    private func column(_ status: SessionStatus, items: [AppState.BoardItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusBadge(status: status)
                Spacer()
                Text("\(items.count)").font(Theme.label).foregroundStyle(Theme.textTertiary)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        Button {
                            state.open(item)
                        } label: {
                            BoardCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .frame(width: 260)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct BoardCard: View {
    let item: AppState.BoardItem

    var body: some View {
        let color = AgentColors.color(id: item.agentID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentAvatar(symbol: item.symbol, color: color, size: 22, active: item.status == .running)
                Text(item.subtitle).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(3).multilineTextAlignment(.leading)
            Text(item.date, format: .relative(presentation: .named))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 12, tint: color, glow: item.status == .running)
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var color: Color = Theme.cyan

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).hudLabel()
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(LinearGradient(colors: [Theme.textPrimary, color], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14, tint: color)
    }
}
