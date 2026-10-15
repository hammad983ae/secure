import AgentHubCore
import AppKit
import Charts
import SwiftUI

/// The menu bar item: today's tokens next to the icon.
struct MenuBarLabel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let today = state.todaySummary
        let busy = !state.activeRuns.isEmpty
        HStack(spacing: 4) {
            Image(systemName: busy ? "sparkles" : "sparkle")
            if today.total.total > 0 {
                Text(Formatters.tokens(today.total.total))
                    .monospacedDigit()
            }
        }
    }
}

/// The menu bar panel: today's usage, a 7-day sparkline, live runs, and a quick prompt.
struct MenuBarPanel: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var prompt = ""

    var body: some View {
        let today = state.todaySummary
        let week = state.usageSummary(since: UsagePeriod.week.start)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accentWide))
                Text("AGENT HUB").font(.system(size: 12, weight: .heavy, design: .rounded)).tracking(2)
                Spacer()
                Text(Date(), format: .dateTime.weekday(.wide)).hudLabel()
            }

            HStack(spacing: 10) {
                stat("Today", Formatters.tokens(today.total.total), "tokens", Theme.cyan)
                stat("Est. cost", Formatters.cost(today.knownCost), "today", Theme.amber)
                stat("Week", Formatters.tokens(week.total.total), Formatters.cost(week.knownCost), Theme.violet)
            }

            sparkline(week)

            VStack(alignment: .leading, spacing: 6) {
                Text("Live").hudLabel()
                let runs = state.activeRuns
                let terminals = state.terminals.filter { !$0.isFinished }
                if runs.isEmpty && terminals.isEmpty {
                    Text("No agents running.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                ForEach(runs.prefix(5)) { item in
                    liveRow(symbol: item.run.agentSymbol, color: AgentColors.color(id: item.run.agentID),
                            title: item.run.agentName, subtitle: item.conversation.conversation.title, status: item.run.status) {
                        state.selection = .chat(item.conversation.id)
                        showMainWindow()
                    }
                }
                ForEach(terminals.prefix(3)) { session in
                    liveRow(symbol: session.agent.symbol, color: AgentColors.color(for: session.agent),
                            title: session.agent.name, subtitle: "Terminal", status: session.status) {
                        state.select(session)
                        showMainWindow()
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Ask an agent… (@claude, @codex)", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .glassCard(radius: 12)

            HStack {
                Button("Open Agent Hub") { showMainWindow() }
                    .buttonStyle(GlassButtonStyle())
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(16)
        .frame(width: 340)
        .foregroundStyle(Theme.textPrimary)
        .background(
            ZStack {
                LinearGradient(colors: [Theme.void, Theme.deep], startPoint: .top, endPoint: .bottom)
                Circle().fill(Theme.violet.opacity(0.25)).frame(width: 260).blur(radius: 60).offset(x: -100, y: -120)
                Circle().fill(Theme.cyan.opacity(0.18)).frame(width: 220).blur(radius: 60).offset(x: 120, y: 140)
            }
        )
        .preferredColorScheme(.dark)
    }

    private func stat(_ title: String, _ value: String, _ detail: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).hudLabel()
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(LinearGradient(colors: [Theme.textPrimary, color], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(detail).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 10, tint: color)
    }

    private func sparkline(_ week: UsageSummary) -> some View {
        let days = (0..<7).compactMap { offset -> DayPoint? in
            guard let day = Calendar.current.date(byAdding: .day, value: -6 + offset, to: Calendar.current.startOfDay(for: Date())) else { return nil }
            let total = week.daily.filter { Calendar.current.isDate($0.day, inSameDayAs: day) }.reduce(0) { $0 + $1.usage.total }
            return DayPoint(day: day, total: total)
        }
        return Chart(days) { point in
            AreaMark(x: .value("Day", point.day, unit: .day), y: .value("Tokens", point.total))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [Theme.cyan.opacity(0.45), Theme.violet.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Day", point.day, unit: .day), y: .value("Tokens", point.total))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.accent)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow)).foregroundStyle(Theme.textTertiary)
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 70)
    }

    private struct DayPoint: Identifiable {
        let day: Date
        let total: Int
        var id: Date { day }
    }

    private func liveRow(symbol: String, color: Color, title: String, subtitle: String, status: SessionStatus,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AgentAvatar(symbol: symbol, color: color, size: 20, active: status == .running)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer()
                StatusBadge(status: status, compact: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        state.quickAsk(text)
        showMainWindow()
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
