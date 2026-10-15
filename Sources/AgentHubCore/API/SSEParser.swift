import Foundation

/// One Server-Sent Event.
public struct SSEEvent: Equatable, Sendable {
    public var event: String?
    public var data: String
}

/// Incremental Server-Sent Events parser. Feed it lines (without the trailing
/// newline); it returns an event each time a blank line completes one.
public struct SSEParser: Sendable {
    private var event: String?
    private var dataLines: [String] = []

    public init() {}

    public mutating func feed(line rawLine: String) -> SSEEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil } // comment / keep-alive

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event": event = String(value)
        case "data": dataLines.append(String(value))
        default: break // id, retry: not needed here
        }
        return nil
    }

    /// Emits any event left at end of stream (servers may omit the final blank line).
    public mutating func finish() -> SSEEvent? { flush() }

    private mutating func flush() -> SSEEvent? {
        defer { event = nil; dataLines = [] }
        guard !dataLines.isEmpty || event != nil else { return nil }
        return SSEEvent(event: event, data: dataLines.joined(separator: "\n"))
    }

    /// Parses a complete SSE body at once.
    public static func parseAll(_ body: String) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if let event = parser.feed(line: String(line)) { events.append(event) }
        }
        if let event = parser.finish() { events.append(event) }
        return events
    }
}
