import AgentHubCore
import Charts
import SwiftUI

/// Token usage across API chats and the Claude Code / Codex logs.
struct UsageScreen: View {
    @Environment(AppState.self) private var state
    @State private var period: UsagePeriod = .week

    var body: some View {
        let summary = state.usageSummary(since: period.start)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Usage").font(Theme.display(26))
                        Text("Tokens and estimated cost across every agent.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    PeriodPicker(period: $period)
                    IconButton(symbol: "arrow.clockwise", help: "Re-read agent logs") { state.refreshUsage() }
                        .opacity(state.isScanningUsage ? 0.4 : 1)
                }

                HStack(spacing: 12) {
                    MetricTile(title: "Tokens", value: Formatters.tokens(summary.total.total), detail: "\(summary.calls) calls", color: Theme.cyan)
                    MetricTile(title: "Input", value: Formatters.tokens(summary.total.input), detail: "uncached", color: Theme.violet)
                    MetricTile(title: "Output", value: Formatters.tokens(summary.total.output), detail: "generated", color: Theme.magenta)
                    MetricTile(
                        title: "Cache",
                        value: Formatters.tokens(summary.total.cacheRead + summary.total.cacheWrite),
                        detail: "\(Formatters.tokens(summary.total.cacheRead)) read · \(Formatters.tokens(summary.total.cacheWrite)) write",
                        color: Theme.emerald
                    )
                    MetricTile(
                        title: "Est. cost",
                        value: Formatters.cost(summary.knownCost),
                        detail: summary.unpricedTokens > 0 ? "+\(Formatters.tokens(summary.unpricedTokens)) unpriced" : "at API list prices",
                        color: Theme.amber
                    )
                }

                if summary.daily.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 30)).accentGradient()
                        Text("No usage in this period").font(Theme.title)
                        Text("API chats appear here, plus Claude Code and Codex runs read from their logs.")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                    .glassCard()
                } else {
                    chart(summary)
                    breakdown(summary)
                }

                footnote
            }
            .padding(26)
        }
    }

    private func chart(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tokens per day").hudLabel()
            Chart(summary.daily) { day in
                BarMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Tokens", day.usage.total)
                )
                .cornerRadius(4)
                .foregroundStyle(by: .value("Source", day.source))
            }
            .chartForegroundStyleScale(range: [Theme.cyan, Theme.violet, Theme.magenta, Theme.emerald, Theme.amber])
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Theme.stroke)
                    AxisValueLabel {
                        if let count = value.as(Int.self) {
                            Text(Formatters.tokens(count)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated)).foregroundStyle(Theme.textTertiary)
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 230)
        }
        .padding(18)
        .glassCard()
    }

    private func breakdown(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By agent and model").hudLabel()
            let maxTotal = max(summary.rows.map(\.usage.total).max() ?? 1, 1)
            ForEach(summary.rows) { row in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.source).font(.system(size: 13, weight: .medium))
                        Text(row.model).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    }
                    .frame(width: 200, alignment: .leading)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: max(4, geo.size.width * CGFloat(row.usage.total) / CGFloat(maxTotal)))
                            .shadow(color: Theme.cyan.opacity(0.5), radius: 4)
                    }
                    .frame(height: 6)
                    Text(Formatters.tokens(row.usage.total))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 64, alignment: .trailing)
                    Text("\(row.calls) calls")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 70, alignment: .trailing)
                    Text(row.cost.map(Formatters.cost) ?? "—")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 70, alignment: .trailing)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(18)
        .glassCard()
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude Code and Codex usage is read from their local logs (~/.claude/projects, ~/.codex/sessions). Gemini CLI and Aider don't keep usage logs.")
            Text("Costs are estimates at public API list prices. On a subscription (Claude Pro/Max, ChatGPT) the figure is the API-equivalent cost, not your bill.")
            if let last = state.lastUsageScan {
                Text("Logs last read \(last.formatted(.relative(presentation: .named))).")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textTertiary)
    }
}

enum UsagePeriod: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "7D"
    case month = "30D"
    var id: String { rawValue }

    var start: Date {
        let today = Calendar.current.startOfDay(for: Date())
        switch self {
        case .today: return today
        case .week: return Calendar.current.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: return Calendar.current.date(byAdding: .day, value: -29, to: today) ?? today
        }
    }
}

/// Segmented control in the glass style.
struct PeriodPicker: View {
    @Binding var period: UsagePeriod

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsagePeriod.allCases) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { period = option }
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(period == option ? .white : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background {
                            if period == option { Capsule().fill(Theme.accent).shadow(color: Theme.violet.opacity(0.5), radius: 6) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.stroke))
    }
}
