import Foundation

extension LaunchPlanner {
    /// Builds a non-interactive run of `agent` for the chat interface, or nil
    /// if the agent has no headless mode.
    ///
    /// - Parameters:
    ///   - resumeID: the agent's session id from an earlier run, to continue that conversation.
    public static func headless(
        agent: AgentDefinition,
        prompt: String,
        resumeID: String? = nil,
        mcpServers: [MCPServerConfig] = [],
        mcpConfigPath: String? = nil,
        shell: String = "/bin/zsh"
    ) -> LaunchSpec? {
        let enabledServers = mcpServers.filter(\.enabled)
        var words: [String]

        switch agent.headless {
        case .none:
            return nil

        case .claudeCode:
            words = [agent.command] + agent.arguments + ["-p", "--output-format", "stream-json", "--verbose"]
            switch agent.headlessPermission {
            case .readOnly: words += ["--permission-mode", "default"]
            case .editFiles: words += ["--permission-mode", "acceptEdits"]
            case .fullAccess: words += ["--dangerously-skip-permissions"]
            }
            if !enabledServers.isEmpty, let mcpConfigPath { words += ["--mcp-config", mcpConfigPath] }
            if let resumeID { words += ["--resume", resumeID] }
            words.append(prompt)

        case .codex:
            words = [agent.command] + agent.arguments + ["exec", "--json", "--skip-git-repo-check"]
            switch agent.headlessPermission {
            case .readOnly: words += ["--sandbox", "read-only"]
            case .editFiles: words += ["--sandbox", "workspace-write"]
            case .fullAccess: words += ["--dangerously-bypass-approvals-and-sandbox"]
            }
            if !enabledServers.isEmpty { words += MCPConfigRenderer.codexOverrides(enabledServers) }
            if let resumeID { words += ["resume", resumeID] }
            words.append(prompt)

        case let .textOutput(arguments):
            if agent.command.trimmingCharacters(in: .whitespaces).isEmpty {
                // Shell agent: the prompt is the command line.
                return LaunchSpec(
                    executable: shell,
                    arguments: ["-l", "-c", withDirectory(agent.workingDirectory, prompt)],
                    environment: headlessEnvironment(agent.environment),
                    pendingInput: nil,
                    commandLine: prompt
                )
            }
            words = [agent.command] + agent.arguments + arguments + [prompt]
        }

        let head = isPlainWord(agent.command) ? agent.command : shellQuote(agent.command)
        let commandLine = (["exec", head] + words.dropFirst().map(shellQuote)).joined(separator: " ")
        return LaunchSpec(
            executable: shell,
            arguments: ["-l", "-c", withDirectory(agent.workingDirectory, commandLine)],
            environment: headlessEnvironment(agent.environment),
            pendingInput: nil,
            commandLine: commandLine
        )
    }

    /// Arguments that reopen a headless session interactively in a terminal.
    public static func interactiveResumeArguments(for agent: AgentDefinition, resumeID: String) -> [String]? {
        switch agent.headless {
        case .claudeCode: return ["--resume", resumeID]
        case .codex: return ["resume", resumeID]
        default: return nil
        }
    }

    static func headlessEnvironment(_ extra: [String: String]) -> [String: String] {
        var env = extra
        env["NO_COLOR"] = env["NO_COLOR"] ?? "1"
        env["TERM"] = env["TERM"] ?? "dumb"
        env["AGENT_HUB"] = "1"
        return env
    }
}

/// Runs an agent as a child process and turns its output into `HeadlessEvent`s.
public struct HeadlessRunner: Sendable {
    public init() {}

    /// The stream finishes after `.finished`. Cancelling the consuming task
    /// terminates the process.
    public func run(_ spec: LaunchSpec, style: HeadlessStyle) -> AsyncThrowingStream<HeadlessEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let state = RunState(style: style)

            process.executableURL = URL(fileURLWithPath: spec.executable)
            process.arguments = spec.arguments
            var env = ProcessInfo.processInfo.environment
            for (key, value) in spec.environment { env[key] = value }
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                for event in state.consume(data) { continuation.yield(event) }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                state.appendStderr(data)
            }
            process.terminationHandler = { process in
                // Drain anything still buffered before reporting the end.
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let rest = stdout.fileHandleForReading.readDataToEndOfFile()
                state.appendStderr(stderr.fileHandleForReading.readDataToEndOfFile())
                for event in state.consume(rest) + state.flush() { continuation.yield(event) }
                if !state.finished {
                    let failed = process.terminationStatus != 0
                    let detail = state.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = failed
                        ? (detail.isEmpty ? "Exited with code \(process.terminationStatus)." : detail)
                        : nil
                    continuation.yield(.finished(isError: failed, message: message, costUSD: nil))
                }
                continuation.finish()
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Line buffering and parsing for one run, shared between pipe callbacks.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var claude = ClaudeStreamParser()
    private var codex = CodexStreamParser()
    private let style: HeadlessStyle
    private var stderrText = ""
    private var didFinish = false

    init(style: HeadlessStyle) {
        self.style = style
    }

    var finished: Bool { lock.withLock { didFinish } }
    var stderrTail: String { lock.withLock { stderrText } }

    func appendStderr(_ data: Data) {
        lock.withLock {
            stderrText = String((stderrText + String(decoding: data, as: UTF8.self)).suffix(3000))
        }
    }

    func consume(_ data: Data) -> [HeadlessEvent] {
        lock.withLock {
            buffer.append(data)
            var events: [HeadlessEvent] = []
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer.subdata(in: buffer.startIndex..<newline), as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                events += parse(line)
            }
            return events
        }
    }

    func flush() -> [HeadlessEvent] {
        lock.withLock {
            guard !buffer.isEmpty else { return [] }
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            return parse(line)
        }
    }

    /// Called with the lock held.
    private func parse(_ line: String) -> [HeadlessEvent] {
        let events: [HeadlessEvent]
        switch style {
        case .claudeCode: events = claude.parse(line: line)
        case .codex: events = codex.parse(line: line)
        case .textOutput, .none: events = TextOutputParser.parse(line: line)
        }
        if events.contains(where: { if case .finished = $0 { return true } else { return false } }) {
            didFinish = true
        }
        return events
    }
}
