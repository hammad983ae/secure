import Foundation

/// Everything needed to start a terminal agent in a pseudo-terminal.
public struct LaunchSpec: Equatable, Sendable {
    /// Executable to spawn (the user's login shell).
    public var executable: String
    public var arguments: [String]
    /// Variables added on top of the inherited environment.
    public var environment: [String: String]
    /// Text to type into the terminal once the agent is up, if the agent
    /// can't take the task on its command line.
    public var pendingInput: String?
    /// The command line the shell will run, for display and debugging.
    public var commandLine: String
}

public enum LaunchPlanner {
    /// Builds the launch for a terminal agent.
    ///
    /// Agents run through the user's login shell (`$SHELL -l -c ...`) because apps
    /// started from Finder don't inherit the PATH set up in `.zshrc`/`.zprofile`,
    /// which is where npm/pipx/homebrew installs of agent CLIs usually live.
    public static func plan(
        agent: AgentDefinition,
        task: String?,
        mcpServers: [MCPServerConfig] = [],
        mcpConfigPath: String? = nil,
        shell: String = "/bin/zsh"
    ) -> LaunchSpec {
        let task = task?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTask = !(task ?? "").isEmpty
        let enabledServers = mcpServers.filter(\.enabled)

        var words: [String] = []
        var pendingInput: String?

        if agent.command.trimmingCharacters(in: .whitespaces).isEmpty {
            // Plain shell session: interactive login shell, task typed in.
            let commandLine = "exec \(shellQuote(shell)) -l"
            return LaunchSpec(
                executable: shell,
                arguments: ["-l", "-c", withDirectory(agent.workingDirectory, commandLine)],
                environment: agent.environment,
                pendingInput: hasTask ? task : nil,
                commandLine: commandLine
            )
        }

        words.append(agent.command)
        words += agent.arguments

        if !enabledServers.isEmpty {
            switch agent.mcpInjection {
            case .none:
                break
            case .claudeMCPConfigFlag:
                if let mcpConfigPath { words += ["--mcp-config", mcpConfigPath] }
            case .codexConfigOverrides:
                words += MCPConfigRenderer.codexOverrides(enabledServers)
            }
        }

        if hasTask, let task {
            switch agent.promptStyle {
            case .positional:
                words.append(task)
            case let .flag(flag):
                words += [flag, task]
            case .typeAfterLaunch:
                pendingInput = task
            }
        }

        // The command itself is left unquoted when it is a plain word so users
        // can write things like `npx my-agent` as command + args.
        let head = isPlainWord(agent.command) ? agent.command : shellQuote(agent.command)
        let commandLine = (["exec", head] + words.dropFirst().map(shellQuote)).joined(separator: " ")

        return LaunchSpec(
            executable: shell,
            arguments: ["-l", "-c", withDirectory(agent.workingDirectory, commandLine)],
            environment: agent.environment,
            pendingInput: pendingInput,
            commandLine: commandLine
        )
    }

    /// POSIX single-quote quoting.
    public static func shellQuote(_ word: String) -> String {
        if !word.isEmpty, isPlainWord(word) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isPlainWord(_ word: String) -> Bool {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,")
        return !word.isEmpty && word.allSatisfy { safe.contains($0) }
    }

    static func withDirectory(_ directory: String?, _ commandLine: String) -> String {
        guard let directory, !directory.isEmpty else { return commandLine }
        let expanded = directory.hasPrefix("~")
            ? "\"$HOME\"" + shellQuote(String(directory.dropFirst()))
            : shellQuote(directory)
        return "cd \(expanded) && \(commandLine)"
    }
}
