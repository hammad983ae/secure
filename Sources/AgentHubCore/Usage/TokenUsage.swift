import Foundation

/// Token counts for one or more model calls.
/// `input` excludes cached tokens; cache reads and writes are counted separately.
public struct TokenUsage: Codable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public static let zero = TokenUsage()

    public var total: Int { input + output + cacheRead + cacheWrite }
    public var isEmpty: Bool { total == 0 }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) { lhs = lhs + rhs }

    /// Field-wise maximum. Streaming APIs report usage more than once per call
    /// (start and end); the largest value of each field is the call's total.
    public func merged(with other: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: max(input, other.input),
            output: max(output, other.output),
            cacheRead: max(cacheRead, other.cacheRead),
            cacheWrite: max(cacheWrite, other.cacheWrite)
        )
    }
}

/// One recorded model call (or a group of calls) attributed to an agent.
public struct UsageRecord: Codable, Hashable, Sendable {
    /// Where the usage came from, e.g. "Claude Code", "Codex", or an API agent's name.
    public var source: String
    public var model: String
    public var date: Date
    public var usage: TokenUsage
    /// Agent Hub session that made the call, when known.
    public var sessionID: UUID?

    public init(source: String, model: String, date: Date, usage: TokenUsage, sessionID: UUID? = nil) {
        self.source = source
        self.model = model
        self.date = date
        self.usage = usage
        self.sessionID = sessionID
    }
}

/// List prices in US dollars per million tokens.
public struct ModelPrice: Hashable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead ?? input * 0.1
        self.cacheWrite = cacheWrite ?? input * 1.25
    }

    public func cost(of usage: TokenUsage) -> Double {
        (Double(usage.input) * input
            + Double(usage.output) * output
            + Double(usage.cacheRead) * cacheRead
            + Double(usage.cacheWrite) * cacheWrite) / 1_000_000
    }
}

/// Estimated API cost by model. Prices are list prices for direct API use;
/// subscriptions (Claude Max, ChatGPT plans) aren't billed per token, so for
/// those this is an "API-equivalent" figure.
public enum ModelPricing {
    /// Matched by longest prefix of the model ID.
    static let table: [(prefix: String, price: ModelPrice)] = [
        // Anthropic
        ("claude-fable-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", ModelPrice(input: 10, output: 50)),
        ("claude-mythos", ModelPrice(input: 10, output: 50)),
        ("claude-opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-8", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-7", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-6", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-5", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4", ModelPrice(input: 15, output: 75)), // Opus 4 and 4.1
        ("claude-sonnet-5-5", ModelPrice(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-5", ModelPrice(input: 2, output: 10)),
        ("claude-sonnet-4", ModelPrice(input: 3, output: 15)),
        ("claude-3-7-sonnet", ModelPrice(input: 3, output: 15)),
        ("claude-haiku-5-5", ModelPrice(input: 0.10, output: 0.50)),
        ("claude-haiku-4-5", ModelPrice(input: 1, output: 5)),
        ("claude-3-5-haiku", ModelPrice(input: 0.80, output: 4)),
        // OpenAI (cache writes are free; cached reads are discounted)
        ("gpt-5-nano", ModelPrice(input: 0.05, output: 0.40, cacheRead: 0.005, cacheWrite: 0)),
        ("gpt-5-mini", ModelPrice(input: 0.25, output: 2, cacheRead: 0.025, cacheWrite: 0)),
        ("gpt-5", ModelPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 0)),
        ("gpt-4.1-mini", ModelPrice(input: 0.40, output: 1.60, cacheRead: 0.10, cacheWrite: 0)),
        ("gpt-4.1", ModelPrice(input: 2, output: 8, cacheRead: 0.50, cacheWrite: 0)),
        ("gpt-4o-mini", ModelPrice(input: 0.15, output: 0.60, cacheRead: 0.075, cacheWrite: 0)),
        ("gpt-4o", ModelPrice(input: 2.50, output: 10, cacheRead: 1.25, cacheWrite: 0)),
        ("o4-mini", ModelPrice(input: 1.10, output: 4.40, cacheRead: 0.275, cacheWrite: 0)),
        ("o3", ModelPrice(input: 2, output: 8, cacheRead: 0.50, cacheWrite: 0)),
    ]

    public static func price(for model: String) -> ModelPrice? {
        let id = model.lowercased()
        return table
            .filter { id.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .price
    }

    /// nil when the model's price is unknown (local models, new releases).
    public static func cost(model: String, usage: TokenUsage) -> Double? {
        price(for: model)?.cost(of: usage)
    }
}
