# Agent Hub

A native macOS command center for your AI agents, with a chat interface on top.

- **Chat with any agent.** Type `@claude fix the flaky tests` or `@claude @codex each review this module` and the agents' replies, tool steps, file edits, and token counts stream in as cards. Follow-ups continue the same agent session, and agents see what the other agents in the chat said.
- **Works with the agents you already use.** Claude Code and Codex run headless in the chat (`claude -p --output-format stream-json`, `codex exec --json`). Gemini CLI, Aider, and your own scripts show live output. `@shell <command>` runs a command. API models (Claude, OpenAI, OpenAI-compatible) chat directly with your keys.
- **Terminals when you want them.** Open any agent in a real terminal, or click *Open in Terminal* on a chat reply to continue that exact session interactively. Up to four terminals can sit side by side.
- **Shared MCP servers.** Set them up once; Claude Code, Codex, and API models all get them. API models ask before each tool call.
- **Auto-routing.** Describe a task without an `@mention` and a fast model picks the agent.
- **Usage tracking.** A dashboard plus a **menu bar widget** with today's tokens, estimated cost, a 7-day sparkline, live runs, and a quick-ask box. Counts API chats exactly and reads Claude Code / Codex usage from their logs.
- **Mission Control.** Every run and terminal grouped by *Running*, *Needs input*, *Done*, *Failed*, with notifications.

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
| New chat | `⌘N` |
| Ask an agent | Type `@handle task` in the chat box. `⏎` sends, `⇧⏎` adds a line, `Tab` completes a mention |
| Follow up | Type without a mention; it goes to the agent you addressed last |
| Everyone in the chat | `@all your message` |
| Set the folder agents work in | The folder chip at the top of a chat |
| Open an agent in a terminal | `⌘K`, the terminal icon next to an agent, or *Open in Terminal* on a reply |
| Mission Control | `⇧⌘B` |
| Usage dashboard | `⇧⌘U`, or *Usage* in the sidebar |
| Add/remove a terminal from split view | `⌘D`, or right-click it |
| Menu bar widget | Click the ✦ icon in the menu bar (toggle in Settings → General) |
| Close a session | `⇧⌘W` or right-click it in the sidebar |
| Agents, MCP servers, API keys | `⌘,` (Settings) |

Built-in handles: `@claude`, `@codex`, `@gemini`, `@aider`, `@claude-api`, `@openai`, `@shell`. You can add, edit, or remove agents in Settings.

### What agents may do from chat

When a terminal agent runs from chat it can't ask you for permission, so each agent has a setting (Settings → Agents → *When asked from chat*):

| Setting | Claude Code | Codex |
| --- | --- | --- |
| Read only | `--permission-mode default` (edits and commands are refused) | `--sandbox read-only` |
| Edit files in the folder (default) | `--permission-mode acceptEdits` | `--sandbox workspace-write` |
| Full access | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` |

Use *Full access* only for folders you trust. For anything that needs case-by-case approval, use *Open in Terminal*.

Chat mode needs a recent Codex CLI (one that supports `codex exec --json`).

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
