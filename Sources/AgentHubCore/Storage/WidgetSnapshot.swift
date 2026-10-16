import Foundation

/// The small summary the app writes for its desktop widget.
///
/// The widget is a separate, sandboxed process. It reads this file through a
/// read-only sandbox exception for `~/Library/Application Support/AgentHub/`.
public struct WidgetSnapshot: Codable, Hashable, Sendable {
    public struct Run: Codable, Hashable, Sendable {
        public var agent: String
        public var symbol: String
        public var title: String
        public var status: SessionStatus

        public init(agent: String, symbol: String, title: String, status: SessionStatus) {
            self.agent = agent
            self.symbol = symbol
            self.title = title
            self.status = status
        }
    }

    public struct BudgetGauge: Codable, Hashable, Sendable {
        public var name: String
        public var fraction: Double

        public init(name: String, fraction: Double) {
            self.name = name
            self.fraction = fraction
        }
    }

    public var updated: Date
    public var todayTokens: Int
    public var todayCost: Double
    public var weekTokens: Int
    public var weekCost: Double
    /// Tokens per day, oldest first, ending today (7 values).
    public var lastSevenDays: [Int]
    public var runs: [Run]
    public var budgets: [BudgetGauge]

    public init(updated: Date = Date(), todayTokens: Int = 0, todayCost: Double = 0, weekTokens: Int = 0, weekCost: Double = 0,
                lastSevenDays: [Int] = Array(repeating: 0, count: 7), runs: [Run] = [], budgets: [BudgetGauge] = []) {
        self.updated = updated
        self.todayTokens = todayTokens
        self.todayCost = todayCost
        self.weekTokens = weekTokens
        self.weekCost = weekCost
        self.lastSevenDays = lastSevenDays
        self.runs = runs
        self.budgets = budgets
    }

    public static let placeholder = WidgetSnapshot(
        todayTokens: 1_240_000, todayCost: 4.82, weekTokens: 9_300_000, weekCost: 31.40,
        lastSevenDays: [900_000, 1_400_000, 1_100_000, 2_000_000, 1_300_000, 1_360_000, 1_240_000],
        runs: [Run(agent: "Claude Code", symbol: "sparkle", title: "Fix the flaky checkout tests", status: .running)],
        budgets: [BudgetGauge(name: "All agents · daily", fraction: 0.62)]
    )

    /// The user's real home folder (a sandboxed process's `NSHomeDirectory()` is its container).
    public static var realHome: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    public static var fileURL: URL {
        URL(fileURLWithPath: realHome)
            .appendingPathComponent("Library/Application Support/AgentHub/widget.json")
    }

    public static func load(from url: URL = fileURL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
