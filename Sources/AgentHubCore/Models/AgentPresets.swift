import Foundation

/// Built-in agent definitions offered on first launch.
/// Preset IDs are fixed so persisted sessions keep pointing at the same agent.
public enum AgentPresets {
    public static let claudeCode = AgentDefinition(
        id: UUID(uuidString: "6C1A0C0D-0000-4000-8000-000000000001")!,
        name: "Claude Code", handle: "claude", kind: .cli, symbol: "sparkle",
        command: "claude", promptStyle: .positional, mcpInjection: .claudeMCPConfigFlag
    )

    public static let codex = AgentDefinition(
        id: UUID(uuidString: "6C1A0C0D-0000-4000-8000-000000000002")!,
        name: "Codex CLI", handle: "codex", kind: .cli, symbol: "chevron.left.forwardslash.chevron.right",
        command: "codex", promptStyle: .positional, mcpInjection: .codexConfigOverrides
    )

    public static let gemini = AgentDefinition(
        id: UUID(uuidString: "6C1A0C0D-0000-4000-8000-000000000003")!,
        name: "Gemini CLI", handle: "gemini", kind: .cli, symbol: "diamond",
        command: "gemini", promptStyle: .flag("-i")
    )

    public static let aider = AgentDefinition(
        id: UUID(uuidString: "6C1A0C0D-0000-4000-8000-000000000004")!,
        name: "Aider", handle: "aider", kind: .cli, symbol: "wrench.and.screwdriver",
        command: "aider", promptStyle: .typeAfterLaunch
    )

    public static let claudeAPI = AgentDefinition(
        id: UUID(uuidString: "6C1A0C0D-0000-4000-8000-000000000005")!,
        name: "Claude (API)", handle: "claude-api", kind: .api, symbol: "bubble.left.and.text.bubble.right",
        provider: .anthropic, model: "claude-opus-5-5"
    )

    public static let openAI = AgentDefinition(
        id: UUID(uuidString: "6C1A0C0D-0000-4000-8000-000000000006")!,
        name: "OpenAI (API)", handle: "openai", kind: .api, symbol: "bubble.left",
        provider: .openai, model: "gpt-5"
    )

    public static let shell = AgentDefinition(
        id: UUID(uuidString: "6C1A0C0D-0000-4000-8000-000000000007")!,
        name: "Shell", handle: "shell", kind: .script, symbol: "apple.terminal",
        command: "", promptStyle: .typeAfterLaunch
    )

    public static let all: [AgentDefinition] = [claudeCode, codex, gemini, aider, claudeAPI, openAI, shell]
}
