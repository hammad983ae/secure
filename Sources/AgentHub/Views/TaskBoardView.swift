import AgentHubCore
import SwiftUI

/// Every session at a glance, grouped by status.
struct TaskBoardView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.sessions.isEmpty {
            ContentUnavailableView {
                Label("No sessions", systemImage: "rectangle.3.group")
            } description: {
                Text("Type `@claude your task` below, or press ⌘K to start agents.")
            }
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(SessionStatus.allCases, id: \.self) { status in
                        column(status)
                    }
                }
                .padding()
            }
        }
    }

    private func column(_ status: SessionStatus) -> some View {
        let items = state.sessions.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusBadge(status: status)
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items) { session in
                Button {
                    state.select(session)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(session.agent.name, systemImage: session.agent.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(session.title).lineLimit(3)
                        Text(session.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 230)
    }
}
