# Agent Hub

A native macOS command center for your AI agents, with a chat interface on top.

- **Chat with any agent.** Type `@claude fix the flaky tests` or `@claude @codex each review this module` and the agents' replies, tool steps, file edits, and token counts stream in as cards. Follow-ups continue the same agent session, and agents see what the other agents in the chat said.
- **Works with the agents you already use.** Claude Code and Codex run headless in the chat (`claude -p --output-format stream-json`, `codex exec --json`). Gemini CLI, Aider, and your own scripts show live output. `@shell <command>` runs a command. API models (Claude, OpenAI, OpenAI-compatible) chat directly with your keys.
- **Terminals when you want them.** Open any agent in a real terminal, or click *Open in Terminal* on a chat reply to continue that exact session interactively. Up to four terminals can sit side by side.
- **Shared MCP servers.** Set them up once; Claude Code, Codex, and API models all get them. API models ask before each tool call.
- **Auto-routing.** Describe a task without an `@mention` and a fast model picks the agent.
- **Usage tracking.** A dashboard plus a **menu bar widget** with today's tokens, estimated cost, a 7-day sparkline, live runs, and a quick-ask box. Counts API chats exactly and reads Claude Code / Codex usage from their logs.
- **Diff review and undo.** When an agent edits files in a git folder, its reply shows exactly what changed, file by file, with **Keep** and **Undo**.
- **Budgets.** Daily or monthly token or dollar limits per agent, with alerts at 80% and 100% and an optional hard stop.
- **Prompt library.** `/review`, `/tests`, `/explain`, `/fix`, or your own saved prompts, sent to their default agents.
- **Desktop widget.** Today's tokens and cost, the last 7 days, running agents, and budgets on your desktop or in Notification Center.
- **Pipelines.** `@claude implement login → @codex review it → @claude address the review` runs each step after the previous one finishes, and each step sees the earlier replies.
- **Compare mode.** `/compare @claude @codex fix the flaky test` runs the agents side by side, each in its own git worktree, with time, tokens, and cost per result. **Pick this** applies the winner's changes and throws the others away.
- **Git worktrees per agent.** Turn on the branch toggle in a chat and each terminal agent works in its own worktree; apply or discard each agent's changes from the bar at the top.
- **Search** every chat, including tool commands and output (`⇧⌘F`).
- **Attachments.** Drop files or screenshots on the chat box, or paste them (`⇧⌘V`). API models get images and small text files inline; Claude Code and Codex get the paths.
- **Quick prompt.** `⌥Space` from any app opens a floating prompt that starts a new chat.
- **Light and dark themes** plus five accent palettes (Settings → General).
- **Export** a chat as Markdown, to a file or the clipboard.
- **Scheduled tasks.** `/schedule every weekday at 9 @codex run the tests and summarize failures`. Each schedule posts to its own chat and notifies you when the agents finish.
- **Remote access from your phone.** Scan a QR code and watch live runs, approve tool calls, stop runs, and send messages from your phone's browser.
- **Mission Control.** Every run and terminal grouped by *Running*, *Needs input*, *Done*, *Failed*, with notifications.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later (Swift 5.9+)
- The agent CLIs you want to use, installed so they work in your normal terminal

## Build and run

**The full app (recommended):** a real `Agent Hub.app` with an icon, the desktop widget, launch at login, and notifications.

```bash
./App/make-project.sh        # installs XcodeGen if needed, generates and opens App/AgentHub.xcodeproj
```

In Xcode, pick the **AgentHub** scheme and press ⌘R. The first build asks you to trust SwiftTerm's build plugin: click **Trust & Enable**. To install it, use *Product → Archive* or copy `Agent Hub.app` from the build folder into `/Applications`.

To add the widget: run the app once, then right-click the desktop → *Edit Widgets…* (or open Notification Center) and search for **Agent Hub**. If it doesn't show up, set your Apple ID team for both targets under *Signing & Capabilities* and run again.

**Quick dev run (no Xcode project):**

```bash
swift run AgentHub            # no widget, notifications, or launch at login
swift test                    # core library tests
```

## Using it

| Action | How |
| --- | --- |
| New chat | `⌘N` |
| Ask an agent | Type `@handle task` in the chat box. `⏎` sends, `⇧⏎` adds a line, `Tab` completes a mention |
| Follow up | Type without a mention; it goes to the agent you addressed last |
| Everyone in the chat | `@all your message` |
| Set the folder agents work in | The folder chip at the top of a chat |
| Open an agent in a terminal | `⌘K`, the terminal icon next to an agent, or *Open in Terminal* on a reply |
| Pipeline | `@claude implement X → @codex review it → @claude fix what codex found` (`→`, `->`, or `=>`) |
| Compare agents | `/compare @claude @codex task`, then **Pick this** on the best result |
| Worktree per agent | The branch toggle in the chat header |
| Attach files | Drop them on the chat box, the 📎 menu, or `⇧⌘V` to paste a screenshot or copied files |
| Search all chats | `⇧⌘F`, or *Search* in the sidebar |
| Quick prompt from any app | `⌥Space` (turn off in Settings → General) |
| Export a chat | The share button in the chat header → *Save as Markdown…* or *Copy as Markdown* |
| Theme and accent color | Settings → General → Appearance |
| Schedule a task | `/schedule every morning at 9 @codex run the tests`, or Settings → Schedules |
| Use from your phone | Settings → Remote → turn on, then scan the QR code |
| Mission Control | `⇧⌘B` |
| Usage dashboard | `⇧⌘U`, or *Usage* in the sidebar |
| Add/remove a terminal from split view | `⌘D`, or right-click it |
| Run a saved prompt | Type `/` in the chat box, e.g. `/review` or `/tests the cart module` |
| Budgets, prompts | Settings → Budgets, Settings → Prompts |
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

### Diff review and undo

When a chat run uses a folder inside a git repository, Agent Hub snapshots the working tree just before and after the run. It writes git tree objects through a temporary index, so your staging area, branches, and stash are never touched. The reply card then lists every file the agent added, changed, or deleted, with an expandable diff.

- **Keep** just marks the changes as reviewed.
- **Undo** puts modified and deleted files back as they were before the run, and deletes files the run created. If you (or another agent) edited those files again after the run, it asks first.

If two agents work in the same folder at the same time, each run's diff includes the other's edits, so review those together.

### Budgets

Settings → Budgets: pick an agent (or all agents), daily or monthly, and a limit in estimated dollars or tokens. At 80% you get a notification and the menu bar icon shows a warning with the percentage; at 100% another notification. With **Hard stop**, Agent Hub won't start new runs for that agent until the period resets. Budgets count the same usage as the dashboard, including Claude Code and Codex runs outside Agent Hub, but can only stop runs started from Agent Hub.

### Prompt library

Type `/` in the chat box to see saved prompts. `{input}` in a prompt is replaced by whatever you type after the command (`/tests the cart module`); without it, your text is added at the end. If your message doesn't mention an agent, the prompt's default agents get it, and `/review @codex` sends it to Codex instead. Edit prompts in Settings → Prompts.

### Pipelines

Separate steps with `→` (or `->`, `=>`), and start every step with an agent mention. Steps run one at a time; each agent gets the earlier steps' replies as context, so "review it" means the previous step's work. A step with no text after the mention continues from the previous result. If a step fails or you press Stop, the remaining steps are skipped. Arrows inside normal text (`returns -> Int`) don't start a pipeline, because every part must begin with a mention.

### Compare mode and worktrees

`/compare @a @b task` sends the same task to each agent. In a git folder, each terminal agent gets its own worktree, a separate checkout in `~/Library/Application Support/AgentHub/worktrees/` that starts from your current files, uncommitted changes included. The agents can't step on each other, and the results show side by side with duration, tokens, cost, and files changed (the fastest and cheapest are highlighted). **Pick this** applies the chosen agent's changes to your folder as a patch and deletes the other worktrees. API models don't edit files, so picking one just marks it and continues the chat with that agent.

Turn on the branch toggle in a chat's header to give every terminal agent its own worktree for all messages, not just comparisons. The bar under the header lists each worktree with **Apply** (patch your folder, then remove the worktree), **Discard**, and a button to show it in Finder. If the patch doesn't apply cleanly because your folder changed in the meantime, nothing is changed and the worktree stays for you to look at. Worktrees don't create branches or commits in your repository. Agent sessions are tied to a folder, so an agent starts a fresh session when it moves into or out of a worktree.

### Scheduled tasks

Type `/schedule <when> <message>` in any chat, or add one in Settings → Schedules. The message is anything you'd type in a chat: mentions, `@all`, pipelines, or saved prompts. The folder comes from the chat you typed it in (or the one you pick in Settings).

Ways to say when: `every day at 9`, `every morning at 9:30`, `every evening at 7` (19:00), `every weekday at 6pm`, `every monday at 14:00`, `daily at 8am`, `every 2 hours`, `every 30 minutes`, `hourly`.

Each schedule has its own chat named ⏰ plus the schedule's name, so follow-ups keep the context. You get a notification when the agents finish. Schedules run while Agent Hub is open, and it keeps running in the menu bar after you close the window. If the Mac was asleep or the app was closed at the scheduled time, the task runs once as soon as it can, not once per missed time. If the previous run is still going, that run is skipped. Settings → Schedules has **Run Now**, an on/off switch, and the next and last run times. Turn on *Launch at Login* (Settings → General) so schedules survive a restart.

### Remote access from your phone

Settings → Remote → turn on *Let my phone watch and control Agent Hub*, then scan the QR code with your phone on the same Wi-Fi. The page that opens shows every chat with live replies, tool steps, output, and token counts, refreshing every two seconds. From there you can:

- **Allow** or **Deny** tool calls from API agents that ask first. Claude Code and Codex can't ask for permission in chat mode (see above), so there's nothing to approve for them.
- **Stop** a chat's runs.
- **Send** messages to an open chat or start a new one, including mentions, pipelines, `/compare`, `/schedule`, and saved prompts.

Add the page to your home screen (Share → Add to Home Screen) for an app-like icon.

Security:

- The QR code's link carries a random 256-bit pairing key, kept in your Keychain. The key sits after `#` in the link, so the browser keeps it on the phone and sends it only in an `Authorization` header. Every API call needs it, and repeated wrong keys get locked out for a minute.
- Anyone with the link can control your agents. **New Pairing Code** signs out every paired phone.
- It's plain HTTP on your local network (port 47823 by default), so use it on networks you trust. macOS may ask to allow incoming connections the first time.
- To use it away from home, put the Mac and phone on a private network such as [Tailscale](https://tailscale.com) and open the link with the Mac's Tailscale address (`http://100.x.y.z:47823/#token=…`). Don't forward the port on your router.

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
  Usage/                  Token counting, pricing, log parsers, budgets, saved prompts
  Git/                    Working-tree snapshots, diffs, undo, and worktrees
  Conversation/           Chats, context sharing, pipelines, search, export, attachments
  Scheduling/             Schedule rules, plain-English parsing, due checks
  Remote/                 HTTP parsing, pairing tokens, phone snapshot, phone web page
  Storage/                Config, session history, usage log
Sources/AgentHubUI/       macOS app UI and state (SwiftUI + SwiftTerm)
Sources/AgentHub/         `swift run` entry point
App/                      Xcode project (XcodeGen project.yml), app icon, widget extension
Tests/AgentHubCoreTests/  Unit tests for the core
```

## Roadmap

- Save terminal scrollback with session history
- Smarter status detection per agent (parse each CLI's prompt)
- Per-session token counts for terminal agents (match log entries to sessions)
- Editable price table
