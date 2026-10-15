import AgentHubCore
import Charts
import SwiftUI

/// Token usage across Agent Hub's API chats and the Claude Code / Codex logs.
struct UsageView: View {
    @Environment(AppState.self) private var state
    @State private var period: Period = .week

    enum Period: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 Days"
        case month = "30 Days"
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

    var body: some View {
        let summary = state.usageSummary(since: period.start)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Usage").font(.largeTitle.bold())
                    Spacer()
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .labelsHidden()
                    Button {
                        state.refreshUsage()
                    } label: {
                        if state.isScanningUsage {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .help("Re-read agent logs")
                }

                tiles(summary)

                if summary.daily.isEmpty {
                    ContentUnavailableView {
                        Label("No usage in this period", systemImage: "chart.bar")
                    } description: {
                        Text("Usage from API chats appears here, plus Claude Code and Codex sessions read from their logs.")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    chart(summary)
                    breakdown(summary)
                }

                footnote
            }
            .padding(20)
        }
        .task {
            // Refresh while the dashboard is open.
            while !Task.isCancelled {
                state.refreshUsage()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func tiles(_ summary: UsageSummary) -> some View {
        HStack(spacing: 12) {
            StatTile(title: "Total tokens", value: Formatters.tokens(summary.total.total), detail: "\(summary.calls) calls")
            StatTile(title: "Input", value: Formatters.tokens(summary.total.input), detail: "uncached")
            StatTile(title: "Output", value: Formatters.tokens(summary.total.output), detail: "generated")
            StatTile(
                title: "Cache",
                value: Formatters.tokens(summary.total.cacheRead + summary.total.cacheWrite),
                detail: "\(Formatters.tokens(summary.total.cacheRead)) read · \(Formatters.tokens(summary.total.cacheWrite)) write"
            )
            StatTile(
                title: "Est. cost",
                value: Formatters.cost(summary.knownCost),
                detail: summary.unpricedTokens > 0 ? "+\(Formatters.tokens(summary.unpricedTokens)) unpriced" : "at API list prices"
            )
        }
    }

    private func chart(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tokens per day").font(.headline)
            Chart(summary.daily) { day in
                BarMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Tokens", day.usage.total)
                )
                .foregroundStyle(by: .value("Source", day.source))
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let count = value.as(Int.self) { Text(Formatters.tokens(count)) }
                    }
                }
            }
            .frame(height: 220)
        }
    }

    private func breakdown(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By agent and model").font(.headline)
            Table(summary.rows) {
                TableColumn("Source", value: \.source)
                TableColumn("Model", value: \.model)
                TableColumn("Calls") { Text("\($0.calls)").monospacedDigit() }
                TableColumn("Input") { Text(Formatters.tokens($0.usage.input)).monospacedDigit() }
                TableColumn("Output") { Text(Formatters.tokens($0.usage.output)).monospacedDigit() }
                TableColumn("Cache read") { Text(Formatters.tokens($0.usage.cacheRead)).monospacedDigit() }
                TableColumn("Cache write") { Text(Formatters.tokens($0.usage.cacheWrite)).monospacedDigit() }
                TableColumn("Est. cost") { row in
                    Text(row.cost.map(Formatters.cost) ?? "—").monospacedDigit()
                }
            }
            .frame(minHeight: CGFloat(min(summary.rows.count, 12)) * 26 + 32)
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude Code and Codex usage is read from their local logs (~/.claude/projects and ~/.codex/sessions). Gemini CLI and Aider don't keep usage logs, so they aren't counted.")
            Text("Costs are estimates at public API list prices. On a subscription plan (Claude Pro/Max, ChatGPT) you aren't billed per token; the figure shows the API-equivalent cost.")
            if let last = state.lastUsageScan {
                Text("Logs last read \(last.formatted(.relative(presentation: .named))).")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
