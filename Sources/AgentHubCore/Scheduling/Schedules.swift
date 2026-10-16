import Foundation

/// When a scheduled task runs.
public enum ScheduleRule: Codable, Hashable, Sendable {
    /// Every day at a time.
    case daily(hour: Int, minute: Int)
    /// Monday to Friday at a time.
    case weekdays(hour: Int, minute: Int)
    /// One day a week (1 = Sunday … 7 = Saturday, like `Calendar`).
    case weekly(weekday: Int, hour: Int, minute: Int)
    /// Every N minutes.
    case interval(minutes: Int)

    /// The first time strictly after `date` the rule fires.
    public func nextFire(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case let .interval(minutes):
            return date.addingTimeInterval(TimeInterval(max(minutes, 1) * 60))
        case let .daily(hour, minute):
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)
        case let .weekly(weekday, hour, minute):
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, weekday: weekday), matchingPolicy: .nextTime)
        case let .weekdays(hour, minute):
            var candidate = date
            for _ in 0..<8 {
                guard let next = calendar.nextDate(after: candidate, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime) else { return nil }
                let weekday = calendar.component(.weekday, from: next)
                if weekday != 1 && weekday != 7 { return next }
                candidate = next
            }
            return nil
        }
    }

    /// "Every weekday at 9:00".
    public var summary: String {
        func time(_ hour: Int, _ minute: Int) -> String { String(format: "%d:%02d", hour, minute) }
        switch self {
        case let .daily(hour, minute): return "Every day at \(time(hour, minute))"
        case let .weekdays(hour, minute): return "Every weekday at \(time(hour, minute))"
        case let .weekly(weekday, hour, minute):
            let names = Calendar(identifier: .gregorian).weekdaySymbols
            let name = (1...7).contains(weekday) ? names[weekday - 1] : "day \(weekday)"
            return "Every \(name) at \(time(hour, minute))"
        case let .interval(minutes):
            if minutes % 60 == 0 { return minutes == 60 ? "Every hour" : "Every \(minutes / 60) hours" }
            return "Every \(minutes) minutes"
        }
    }
}

/// A message sent to agents on a schedule, e.g. `@codex run the tests and summarize failures`.
public struct ScheduledTask: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The chat message, with agent mentions.
    public var message: String
    public var rule: ScheduleRule
    public var workingDirectory: String?
    public var enabled: Bool
    public var createdAt: Date
    public var lastRun: Date?
    /// The chat results go to (reused while it exists).
    public var conversationID: UUID?

    public init(id: UUID = UUID(), name: String, message: String, rule: ScheduleRule, workingDirectory: String? = nil,
                enabled: Bool = true, createdAt: Date = Date(), lastRun: Date? = nil, conversationID: UUID? = nil) {
        self.id = id
        self.name = name
        self.message = message
        self.rule = rule
        self.workingDirectory = workingDirectory
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastRun = lastRun
        self.conversationID = conversationID
    }

    /// The next run after the last one (or after creation).
    public func nextRun(calendar: Calendar = .current) -> Date? {
        rule.nextFire(after: lastRun ?? createdAt, calendar: calendar)
    }

    /// Due now: enabled and its next run has passed. A run missed while the
    /// Mac was asleep or the app was closed happens once, as soon as possible.
    public func isDue(at now: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, let next = nextRun(calendar: calendar) else { return false }
        return next <= now
    }
}

/// Reads schedules written in plain words:
/// "every day at 9", "every morning at 9:30", "every weekday at 6pm",
/// "every monday at 14:00", "every 2 hours", "every 30 minutes", "hourly", "daily at 8am".
public enum ScheduleParser {
    /// Splits `text` into a rule and the rest of the message, or nil if it
    /// doesn't start with a schedule.
    public static func parse(_ text: String) -> (rule: ScheduleRule, message: String)? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        var index = 0
        func peek(_ offset: Int = 0) -> String? {
            index + offset < words.count ? words[index + offset].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",:;")) : nil
        }
        func rest() -> String { words[index...].joined(separator: " ") }

        if peek() == "hourly" { index += 1; return (.interval(minutes: 60), rest()) }
        var kind = "day"
        if peek() == "daily" {
            index += 1
        } else if peek() == "every" || peek() == "each" {
            index += 1
            guard let word = peek() else { return nil }
            if let count = Int(word), let unit = peek(1) {
                index += 2
                if unit.hasPrefix("min") { return count > 0 ? (.interval(minutes: count), rest()) : nil }
                if unit.hasPrefix("hour") || unit == "h" { return count > 0 ? (.interval(minutes: count * 60), rest()) : nil }
                return nil
            }
            index += 1
            switch word {
            case "hour": return (.interval(minutes: 60), rest())
            case "day", "morning", "evening", "night", "afternoon": kind = word
            case "weekday", "weekdays", "workday": kind = "weekday"
            default:
                guard weekdayNumber(word) != nil else { return nil }
                kind = word
            }
        } else {
            return nil
        }
        // "at 9", "at 9:30", "at 6pm", "at 6 pm"
        var hour = defaultHour(kind)
        var minute = 0
        if peek() == "at", let timeWord = peek(1) {
            index += 2
            var timeText = timeWord
            if let suffix = peek(), suffix == "am" || suffix == "pm" { timeText += suffix; index += 1 }
            guard let time = parseTime(timeText, kind: kind) else { return nil }
            (hour, minute) = time
        }
        let message = rest()
        if kind == "weekday" { return (.weekdays(hour: hour, minute: minute), message) }
        if let weekday = weekdayNumber(kind) { return (.weekly(weekday: weekday, hour: hour, minute: minute), message) }
        return (.daily(hour: hour, minute: minute), message)
    }

    private static func defaultHour(_ kind: String) -> Int {
        switch kind {
        case "evening", "night": return 18
        case "afternoon": return 14
        default: return 9
        }
    }

    static func parseTime(_ text: String, kind: String) -> (Int, Int)? {
        var value = text.lowercased()
        var pm = false, am = false
        if value.hasSuffix("pm") { pm = true; value.removeLast(2) } else if value.hasSuffix("am") { am = true; value.removeLast(2) }
        let parts = value.split(separator: ":")
        guard let first = parts.first, var hour = Int(first), parts.count <= 2 else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) ?? -1 : 0
        guard (0..<60).contains(minute) else { return nil }
        if pm, hour < 12 { hour += 12 }
        if am, hour == 12 { hour = 0 }
        // "every evening at 7" means 19:00.
        if !am, !pm, hour < 12, ["evening", "night", "afternoon"].contains(kind) { hour += 12 }
        guard (0..<24).contains(hour) else { return nil }
        return (hour, minute)
    }

    static func weekdayNumber(_ word: String) -> Int? {
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let trimmed = word.hasSuffix("s") ? String(word.dropLast()) : word
        return names.firstIndex(of: trimmed).map { $0 + 1 }
    }
}
