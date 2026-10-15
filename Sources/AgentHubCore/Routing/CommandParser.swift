import Foundation

/// Result of parsing a line typed in the command bar.
public struct ParsedCommand: Equatable, Sendable {
    /// Agent handles mentioned with `@handle`, in order, without duplicates.
    public var mentions: [String]
    /// `@all` was used: send to every open session.
    public var mentionsAll: Bool
    /// The task text with the mentions removed.
    public var task: String
}

/// Parses command-bar input like `@claude @codex fix the failing tests`.
///
/// Only leading mentions route the task, so an `@` in the middle of the text
/// (an email, a decorator, `@MainActor`) stays part of the task.
public enum CommandParser {
    public static func parse(_ input: String, knownHandles: Set<String>) -> ParsedCommand {
        var mentions: [String] = []
        var mentionsAll = false
        var rest = Substring(input.trimmingCharacters(in: .whitespacesAndNewlines))

        while rest.hasPrefix("@") {
            let wordEnd = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
            let handle = rest[rest.index(after: rest.startIndex)..<wordEnd].lowercased()
            if handle == "all" {
                mentionsAll = true
            } else if knownHandles.contains(handle) {
                if !mentions.contains(handle) { mentions.append(handle) }
            } else {
                break
            }
            rest = rest[wordEnd...].drop(while: { $0.isWhitespace })
        }

        return ParsedCommand(mentions: mentions, mentionsAll: mentionsAll, task: String(rest))
    }

    /// Handle suggestions for the word being typed, for autocomplete.
    public static func completions(for input: String, handles: [String]) -> [String] {
        guard let last = input.split(separator: " ", omittingEmptySubsequences: false).last,
              last.hasPrefix("@") else { return [] }
        let prefix = last.dropFirst().lowercased()
        return (handles + ["all"]).filter { $0.hasPrefix(prefix) && $0 != prefix }
    }
}
