import Foundation

/// Totals for one (source, model) pair.
public struct UsageBreakdownRow: Hashable, Sendable, Identifiable {
    public var source: String
    public var model: String
    public var usage: TokenUsage
    public var calls: Int
    /// nil when any of the usage is for a model without a known price.
    public var cost: Double?
    public var id: String { source + "\u{1F}" + model }
}

/// Totals for one day and source, for charts.
public struct DailyUsage: Hashable, Sendable, Identifiable {
    public var day: Date
    public var source: String
    public var usage: TokenUsage
    public var cost: Double
    public var id: String { "\(day.timeIntervalSince1970)-\(source)" }
}

public struct UsageSummary: Sendable {
    public var total: TokenUsage
    /// Cost of usage whose model has a known price.
    public var knownCost: Double
    /// Tokens for models with no known price (excluded from `knownCost`).
    public var unpricedTokens: Int
    public var calls: Int
    public var rows: [UsageBreakdownRow]
    public var daily: [DailyUsage]

    /// Summarizes records dated within `[start, end)`.
    public init(records: [UsageRecord], from start: Date, to end: Date = .distantFuture, calendar: Calendar = .current) {
        var total = TokenUsage.zero
        var knownCost = 0.0
        var unpriced = 0
        var calls = 0
        var rows: [String: UsageBreakdownRow] = [:]
        var daily: [String: DailyUsage] = [:]

        for record in records where record.date >= start && record.date < end {
            let cost = ModelPricing.cost(model: record.model, usage: record.usage)
            total += record.usage
            calls += 1
            if let cost { knownCost += cost } else { unpriced += record.usage.total }

            let rowKey = record.source + "\u{1F}" + record.model
            var row = rows[rowKey] ?? UsageBreakdownRow(source: record.source, model: record.model, usage: .zero, calls: 0, cost: 0)
            row.usage += record.usage
            row.calls += 1
            let previousCost = row.cost
            row.cost = cost.flatMap { c in previousCost.map { $0 + c } }
            rows[rowKey] = row

            let day = calendar.startOfDay(for: record.date)
            let dayKey = "\(day.timeIntervalSince1970)-\(record.source)"
            var entry = daily[dayKey] ?? DailyUsage(day: day, source: record.source, usage: .zero, cost: 0)
            entry.usage += record.usage
            entry.cost += cost ?? 0
            daily[dayKey] = entry
        }

        self.total = total
        self.knownCost = knownCost
        self.unpricedTokens = unpriced
        self.calls = calls
        self.rows = rows.values.sorted { $0.usage.total > $1.usage.total }
        self.daily = daily.values.sorted { ($0.day, $0.source) < ($1.day, $1.source) }
    }
}
