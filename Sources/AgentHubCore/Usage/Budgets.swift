import Foundation

/// A spending limit for one agent, or for all agents together.
public struct Budget: Codable, Hashable, Sendable, Identifiable {
    public enum Period: String, Codable, CaseIterable, Sendable {
        case daily, monthly
        public var title: String { self == .daily ? "Daily" : "Monthly" }
    }

    public enum Limit: Codable, Hashable, Sendable {
        case tokens(Int)
        case dollars(Double)
    }

    public var id: UUID
    /// nil = every agent combined.
    public var agentID: UUID?
    public var period: Period
    public var limit: Limit
    /// Refuse to start new runs from Agent Hub once the limit is reached.
    public var hardStop: Bool

    public init(id: UUID = UUID(), agentID: UUID?, period: Period, limit: Limit, hardStop: Bool = false) {
        self.id = id
        self.agentID = agentID
        self.period = period
        self.limit = limit
        self.hardStop = hardStop
    }

    /// Start of the current period.
    public func periodStart(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch period {
        case .daily:
            return calendar.startOfDay(for: now)
        case .monthly:
            return calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? calendar.startOfDay(for: now)
        }
    }
}

/// How much of a budget has been used.
public struct BudgetStatus: Hashable, Sendable, Identifiable {
    public static let warningFraction = 0.8

    public var budget: Budget
    /// Tokens or dollars used this period, in the budget's unit.
    public var used: Double
    public var limit: Double
    public var id: UUID { budget.id }

    public var fraction: Double { limit > 0 ? used / limit : 0 }
    public var isWarning: Bool { fraction >= Self.warningFraction && !isExceeded }
    public var isExceeded: Bool { fraction >= 1 }

    /// Identifies this budget's current period, for "notify once per period".
    public func periodKey(now: Date = Date()) -> String {
        "\(budget.id.uuidString)-\(Int(budget.periodStart(now: now).timeIntervalSince1970))"
    }
}

public enum BudgetEvaluator {
    /// Usage record sources that belong to an agent. Claude Code and Codex
    /// usage read from their logs is labeled with the tool's name, not the
    /// agent's display name.
    public static func sources(for agent: AgentDefinition) -> Set<String> {
        var sources: Set<String> = [agent.name]
        switch agent.headless {
        case .claudeCode: sources.insert(ClaudeCodeLogParser.source)
        case .codex: sources.insert(CodexLogParser.source)
        default: break
        }
        return sources
    }

    public static func status(
        of budget: Budget,
        records: [UsageRecord],
        agents: [AgentDefinition],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> BudgetStatus {
        let start = budget.periodStart(now: now, calendar: calendar)
        var relevant = records.filter { $0.date >= start && $0.date <= now }
        if let agentID = budget.agentID {
            let sources = agents.first { $0.id == agentID }.map(Self.sources(for:)) ?? []
            relevant = relevant.filter { sources.contains($0.source) }
        }
        switch budget.limit {
        case let .tokens(limit):
            let used = relevant.reduce(0) { $0 + $1.usage.total }
            return BudgetStatus(budget: budget, used: Double(used), limit: Double(limit))
        case let .dollars(limit):
            let used = relevant.reduce(0.0) { $0 + (ModelPricing.cost(model: $1.model, usage: $1.usage) ?? 0) }
            return BudgetStatus(budget: budget, used: used, limit: limit)
        }
    }

    /// The first exceeded hard-stop budget that applies to `agent`, if any.
    public static func blockingBudget(for agent: AgentDefinition, statuses: [BudgetStatus]) -> BudgetStatus? {
        statuses.first { status in
            status.budget.hardStop && status.isExceeded && (status.budget.agentID == nil || status.budget.agentID == agent.id)
        }
    }
}

/// A reusable prompt, run with `/name` in the chat box.
public struct SavedPrompt: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Command name without the slash, e.g. `review`.
    public var name: String
    public var title: String
    /// Text sent to the agents. `{input}` is replaced by what follows the
    /// command; without a placeholder the input is appended.
    public var body: String
    /// Agent handles used when the message mentions none.
    public var agents: [String]

    public init(id: UUID = UUID(), name: String, title: String, body: String, agents: [String] = []) {
        self.id = id
        self.name = name
        self.title = title
        self.body = body
        self.agents = agents
    }

    public static let defaults: [SavedPrompt] = [
        SavedPrompt(
            id: UUID(uuidString: "5A7ED000-0000-4000-8000-000000000001")!,
            name: "review", title: "Review the current changes",
            body: "Review the uncommitted changes in this repository (git diff). Point out bugs, risky edge cases, and missing tests, most important first. Don't change any files.\n\n{input}",
            agents: ["claude"]
        ),
        SavedPrompt(
            id: UUID(uuidString: "5A7ED000-0000-4000-8000-000000000002")!,
            name: "tests", title: "Write tests",
            body: "Write tests for {input}. Follow the project's existing test style, run them, and fix anything that fails.",
            agents: ["claude"]
        ),
        SavedPrompt(
            id: UUID(uuidString: "5A7ED000-0000-4000-8000-000000000003")!,
            name: "explain", title: "Explain code",
            body: "Explain how {input} works: what it's for, the main flow, and anything surprising. Don't change any files.",
            agents: ["claude"]
        ),
        SavedPrompt(
            id: UUID(uuidString: "5A7ED000-0000-4000-8000-000000000004")!,
            name: "fix", title: "Fix a bug",
            body: "Find and fix this bug: {input}\n\nReproduce it first if you can, make the smallest fix, and run the relevant tests.",
            agents: ["codex"]
        ),
    ]
}

public enum PromptLibrary {
    /// Expands `/name rest of message` using `prompts`. Mentions in the message
    /// are kept; if there are none, the prompt's default agents are added.
    /// Returns nil when the message doesn't start with a known command.
    public static func expand(_ input: String, prompts: [SavedPrompt], knownHandles: Set<String>) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let nameEnd = trimmed.firstIndex(where: { $0.isWhitespace }) ?? trimmed.endIndex
        let name = trimmed[trimmed.index(after: trimmed.startIndex)..<nameEnd].lowercased()
        guard let prompt = prompts.first(where: { $0.name.lowercased() == name }) else { return nil }

        let rest = String(trimmed[nameEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let command = CommandParser.chatCommand(rest, knownHandles: knownHandles)
        let leading = command.mentionsAll ? ["@all"] : CommandParser.parse(rest, knownHandles: knownHandles).mentions.map { "@\($0)" }
        let text = leading.isEmpty ? rest : command.task

        let body: String
        if prompt.body.contains("{input}") {
            body = prompt.body.replacingOccurrences(of: "{input}", with: text)
        } else {
            body = text.isEmpty ? prompt.body : prompt.body + "\n\n" + text
        }

        let mentions: [String]
        if !leading.isEmpty {
            mentions = leading
        } else if !command.mentions.isEmpty {
            mentions = [] // mentions inside the text address the agents already
        } else {
            mentions = prompt.agents.filter { knownHandles.contains($0.lowercased()) }.map { "@\($0)" }
        }
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return (mentions + [cleanBody]).joined(separator: " ")
    }

    /// Prompt suggestions for a `/` being typed at the start of the message.
    public static func completions(for input: String, prompts: [SavedPrompt]) -> [SavedPrompt] {
        guard input.hasPrefix("/"), !input.contains(" ") else { return [] }
        let prefix = input.dropFirst().lowercased()
        return prompts.filter { $0.name.lowercased().hasPrefix(prefix) }
    }
}
