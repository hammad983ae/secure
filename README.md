# Agent Hub

A native macOS app that gives you one command line for all your AI agents.

- **Terminal agents**: Claude Code, Codex CLI, Gemini CLI, Aider, or any command you register. Each runs in its own live terminal tab.
- **API models**: chat with Claude, OpenAI, or any OpenAI-compatible server (Ollama, LM Studio, OpenRouter, ...) using your own keys.
- **Shared MCP servers**: set up MCP servers once and they're passed to every agent that supports it.
- **One command bar** for all of them:
  - `@claude @codex fix the failing tests` starts a session on each agent with that task.
  - `@all run the test suite again` sends the text to every live session.
  - Plain text goes to the selected session.
- **Task board**: every session grouped by *Running*, *Needs input*, *Done*, *Failed*, with a macOS notification when an agent finishes or goes quiet.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later (Swift 5.9+)
- The agent CLIs you want to use, installed so they work in your normal terminal

## Build and run

```bash
swift run AgentHub            # quick dev run
swift test                    # core library tests
./scripts/bundle.sh           # builds build/AgentHub.app (needed for notifications)
open build/AgentHub.app
```

To work in Xcode, open `Package.swift` and run the `AgentHub` scheme.

## Using it

| Action | How |
| --- | --- |
| Start agents on a task | `⌘K`, or type `@handle task` in the command bar |
| Message the current session | Type in the command bar and press Return |
| Broadcast to every live session | `@all your message` |
| Task board | `⇧⌘B`, or *Task Board* in the sidebar |
| Close a session | `⇧⌘W` or right-click it in the sidebar |
| Agents, MCP servers, API keys | `⌘,` (Settings) |

Built-in handles: `@claude`, `@codex`, `@gemini`, `@aider`, `@claude-api`, `@openai`, `@shell`. You can add, edit, or remove agents in Settings.

### How terminal agents are started

Each agent runs through your login shell (`$SHELL -l -c "exec <agent> ..."`), so it finds the same `PATH` as your terminal. That matters for CLIs installed with npm, pipx, or Homebrew. An agent marked "not found" in the sidebar isn't on that `PATH`.

The task is passed the way each CLI expects: as an argument (`claude "task"`), after a flag (`gemini -i "task"`), or typed into the terminal once the agent is up (Aider, custom scripts).

### Status detection

Terminal agents don't report their state in any standard way, so Agent Hub infers it. While output is flowing the session is *Running*. After 4 seconds with no output it's marked *Needs input*. When the process exits it's *Done* (exit code 0) or *Failed*.

### MCP servers

Servers added in Settings → MCP Servers are written to `~/Library/Application Support/AgentHub/mcp-servers.json` and passed on:

- **Claude Code**: `--mcp-config <that file>` (stdio and HTTP servers)
- **Codex CLI**: `-c mcp_servers.<name>.command=...` overrides (stdio servers only)
- **Other agents**: not passed yet. Set *Shared MCP servers* on an agent if its CLI accepts one of the formats above.

### Privacy

- API keys are stored in your login Keychain, never in the config file.
- Config lives in `~/Library/Application Support/AgentHub/config.json` (owner-only permissions).
- The app sends API requests only to the provider configured on each agent.

## Project layout

```
Sources/AgentHubCore/     Platform-independent logic (unit tested)
  Models/                 Agent definitions, presets, session status, activity tracking
  Launch/                 Builds the shell command for a terminal agent
  MCP/                    Shared MCP server config and per-agent rendering
  Routing/                @mention command parsing
  API/                    Streaming clients for Anthropic and OpenAI-style APIs
  Storage/                JSON persistence
Sources/AgentHub/         macOS app (SwiftUI + SwiftTerm)
Tests/AgentHubCoreTests/  Unit tests for the core
```

## Roadmap

- MCP tool use for API models (run the agent loop in-app)
- Split panes: several terminals side by side
- Session history and restore
- Smarter status detection per agent (parse each CLI's prompt)
- Auto-routing: let a model pick the best agent for a task
