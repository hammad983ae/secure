# Agent Hub

A native macOS app that gives you one command line for all your AI agents.

- **Terminal agents**: Claude Code, Codex CLI, Gemini CLI, Aider, or any command you register. Each runs in its own live terminal tab.
- **API models**: chat with Claude, OpenAI, or any OpenAI-compatible server (Ollama, LM Studio, OpenRouter, ...) using your own keys.
- **Shared MCP servers**: set up MCP servers once and they're passed to every agent that supports it.
- **MCP tools for API models**: API chats can call your shared MCP servers' tools, with an Allow/Deny prompt for each call.
- **One command bar** for all of them:
  - `@claude @codex fix the failing tests` starts a session on each agent with that task.
  - `@all run the test suite again` sends the text to every live session.
  - Plain text goes to the selected session.
  - With no session selected, plain text is **auto-routed**: a fast model picks the best agent for the task.
- **Token usage dashboard**: tokens per day, per agent and per model, with estimated cost. Covers the app's own API chats exactly, plus Claude Code and Codex usage read from their local logs.
- **Session history**: sessions are saved. Continue an old chat, or re-run a terminal session with the same task and folder.
- **Split view**: up to four sessions side by side (`⌘D` adds the current session).
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
| Usage dashboard | `⇧⌘U`, or *Usage* in the sidebar |
| Add/remove current session from split view | `⌘D`, or right-click a session |
| Reopen a past session | Click it under *History* in the sidebar |
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

### Token usage

- **API chats** (Claude, OpenAI, compatible servers): exact counts from each API response, including cache reads and writes.
- **Claude Code**: read from `~/.claude/projects/**/*.jsonl` (also `~/.config/claude` and `$CLAUDE_CONFIG_DIR`).
- **Codex CLI**: read from `~/.codex/sessions/**/*.jsonl` (also `$CODEX_HOME`).
- **Gemini CLI and Aider** don't keep usage logs, so they aren't counted.

Costs are estimates at public API list prices. If you use a subscription (Claude Pro/Max, ChatGPT), you aren't billed per token, so the figure is the API-equivalent cost. Models with no known price show "—". You can turn off log reading in Settings → General.

### MCP tools in API chats

When an API agent has *Let the model use shared MCP tools* on (Settings → Agents), the app connects to your enabled MCP servers and offers their tools to the model. Tools appear as `server__tool`. By default each call waits for you to click **Allow** or **Deny** in the chat. Turn off *Ask before each tool call* to let it run tools freely.

### Auto-routing

With no session selected, typing a task without an `@mention` asks a fast model (default `claude-haiku-5-5`, using your Anthropic key) which agent fits best, using each agent's *What it's good at* description. Change the router agent and model in Settings → General, or turn routing off there.

### Privacy

- API keys are stored in your login Keychain, never in the config file.
- Config lives in `~/Library/Application Support/AgentHub/config.json` (owner-only permissions).
- The app sends API requests only to the provider configured on each agent (and to the router's provider for auto-routing).
- Session history and usage records are stored in the same folder (`sessions/`, `usage.jsonl`), readable only by you.

## Project layout

```
Sources/AgentHubCore/     Platform-independent logic (unit tested)
  Models/                 Agent definitions, presets, session status, activity tracking
  Launch/                 Builds the shell command for a terminal agent
  MCP/                    Shared MCP server config and per-agent rendering
  Routing/                @mention parsing and auto-routing
  API/                    Streaming, tool-use loop for Anthropic and OpenAI-style APIs
  MCP/                    MCP client (stdio + Streamable HTTP) and toolbox
  Usage/                  Token counting, pricing, Claude Code / Codex log parsers
  Storage/                Config, session history, usage log
Sources/AgentHub/         macOS app (SwiftUI + SwiftTerm)
Tests/AgentHubCoreTests/  Unit tests for the core
```

## Roadmap

- Save terminal scrollback with session history
- Smarter status detection per agent (parse each CLI's prompt)
- Per-session token counts for terminal agents (match log entries to sessions)
- Editable price table
