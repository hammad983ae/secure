import AgentHubCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AgentsSettings()
                .tabItem { Label("Agents", systemImage: "person.2") }
            MCPSettings()
                .tabItem { Label("MCP Servers", systemImage: "point.3.connected.trianglepath.dotted") }
            APIKeySettings()
                .tabItem { Label("API Keys", systemImage: "key") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 720, height: 520)
    }
}

// MARK: - Agents

private struct AgentsSettings: View {
    @Environment(AppState.self) private var state
    @State private var selectedID: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(state.config.agents) { agent in
                        Label(agent.name, systemImage: agent.symbol).tag(agent.id)
                    }
                }
                HStack {
                    Menu {
                        Button("Terminal agent (CLI)") { add(.cli) }
                        Button("API model") { add(.api) }
                        Button("Custom script") { add(.script) }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .frame(width: 32)
                    Button {
                        guard let id = selectedID else { return }
                        state.updateConfig { $0.agents.removeAll { $0.id == id } }
                        selectedID = nil
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedID == nil)
                    Spacer()
                    Button("Restore Defaults") {
                        state.updateConfig { config in
                            let existing = Set(config.agents.map(\.id))
                            config.agents += AgentPresets.all.filter { !existing.contains($0.id) }
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Re-add any built-in agents you removed")
                }
                .padding(6)
            }
            .frame(minWidth: 200, maxWidth: 240)

            if let agent = state.config.agents.first(where: { $0.id == selectedID }) {
                AgentEditor(agent: agent) { updated in
                    state.updateConfig { config in
                        if let index = config.agents.firstIndex(where: { $0.id == updated.id }) {
                            config.agents[index] = updated
                        }
                    }
                }
                .id(agent.id)
            } else {
                Text("Select an agent").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func add(_ kind: AgentKind) {
        let agent: AgentDefinition
        switch kind {
        case .cli: agent = AgentDefinition(name: "New Agent", handle: "agent", kind: .cli, command: "my-agent", promptStyle: .positional)
        case .api: agent = AgentDefinition(name: "New Model", handle: "model", kind: .api, symbol: "bubble.left", provider: .openaiCompatible, model: "", baseURL: "http://localhost:11434/v1")
        case .script: agent = AgentDefinition(name: "New Script", handle: "script", kind: .script, symbol: "scroll", command: "./script.sh")
        }
        state.updateConfig { $0.agents.append(agent) }
        selectedID = agent.id
    }
}

private struct AgentEditor: View {
    @State private var draft: AgentDefinition
    @State private var argumentsText: String
    @State private var environmentText: String
    @State private var promptMode: Int
    @State private var promptFlag: String
    let onSave: (AgentDefinition) -> Void

    init(agent: AgentDefinition, onSave: @escaping (AgentDefinition) -> Void) {
        _draft = State(initialValue: agent)
        _argumentsText = State(initialValue: agent.arguments.joined(separator: "\n"))
        _environmentText = State(initialValue: KeyValueText.format(agent.environment))
        switch agent.promptStyle {
        case .positional: _promptMode = State(initialValue: 0); _promptFlag = State(initialValue: "")
        case let .flag(flag): _promptMode = State(initialValue: 1); _promptFlag = State(initialValue: flag)
        case .typeAfterLaunch: _promptMode = State(initialValue: 2); _promptFlag = State(initialValue: "")
        }
        self.onSave = onSave
    }

    var body: some View {
        Form {
            TextField("Name", text: $draft.name)
            TextField("Handle (for @mentions)", text: $draft.handle)
            TextField("SF Symbol", text: $draft.symbol)
            Picker("Kind", selection: $draft.kind) {
                Text("Terminal agent").tag(AgentKind.cli)
                Text("API model").tag(AgentKind.api)
                Text("Custom script").tag(AgentKind.script)
            }

            if draft.kind == .api {
                Picker("Provider", selection: Binding(get: { draft.provider ?? .anthropic }, set: { draft.provider = $0 })) {
                    ForEach(APIProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Model", text: optional($draft.model))
                TextField("Base URL (optional for Anthropic/OpenAI)", text: optional($draft.baseURL))
                TextField("System prompt", text: optional($draft.systemPrompt), axis: .vertical)
                    .lineLimit(3...6)
            } else {
                TextField("Command (empty = login shell)", text: $draft.command)
                LabeledContent("Arguments (one per line)") {
                    TextEditor(text: $argumentsText).font(.body.monospaced()).frame(height: 54)
                }
                LabeledContent("Environment (KEY=value)") {
                    TextEditor(text: $environmentText).font(.body.monospaced()).frame(height: 54)
                }
                TextField("Working directory", text: optional($draft.workingDirectory))
                Picker("Initial task is passed", selection: $promptMode) {
                    Text("As an argument").tag(0)
                    Text("After a flag").tag(1)
                    Text("Typed in after launch").tag(2)
                }
                if promptMode == 1 {
                    TextField("Flag", text: $promptFlag)
                }
                Picker("Shared MCP servers", selection: $draft.mcpInjection) {
                    Text("Don't pass").tag(MCPInjection.none)
                    Text("--mcp-config file (Claude Code)").tag(MCPInjection.claudeMCPConfigFlag)
                    Text("-c overrides (Codex)").tag(MCPInjection.codexConfigOverrides)
                }
            }

            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        var agent = draft
        agent.handle = agent.handle.lowercased().filter { !$0.isWhitespace && $0 != "@" }
        agent.arguments = argumentsText.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        agent.environment = KeyValueText.parse(environmentText)
        switch promptMode {
        case 0: agent.promptStyle = .positional
        case 1: agent.promptStyle = .flag(promptFlag.trimmingCharacters(in: .whitespaces))
        default: agent.promptStyle = .typeAfterLaunch
        }
        if agent.kind == .api, agent.provider == nil { agent.provider = .anthropic }
        onSave(agent)
    }
}

// MARK: - MCP servers

private struct MCPSettings: View {
    @Environment(AppState.self) private var state
    @State private var selectedID: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(state.config.mcpServers) { server in
                        HStack {
                            Text(server.name)
                            if !server.enabled { Text("off").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(server.id)
                    }
                }
                HStack {
                    Button {
                        let server = MCPServerConfig(name: "server", transport: .stdio(command: "npx", arguments: [], environment: [:]))
                        state.updateConfig { $0.mcpServers.append(server) }
                        selectedID = server.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        guard let id = selectedID else { return }
                        state.updateConfig { $0.mcpServers.removeAll { $0.id == id } }
                        selectedID = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selectedID == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 200, maxWidth: 240)

            if let server = state.config.mcpServers.first(where: { $0.id == selectedID }) {
                MCPEditor(server: server) { updated in
                    state.updateConfig { config in
                        if let index = config.mcpServers.firstIndex(where: { $0.id == updated.id }) {
                            config.mcpServers[index] = updated
                        }
                    }
                }
                .id(server.id)
            } else {
                VStack(spacing: 8) {
                    Text("MCP servers added here are shared with every agent that supports it.")
                    Text("Claude Code gets them via --mcp-config, Codex via -c overrides.")
                }
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct MCPEditor: View {
    let server: MCPServerConfig
    let onSave: (MCPServerConfig) -> Void
    @State private var name: String
    @State private var enabled: Bool
    @State private var isHTTP: Bool
    @State private var command: String
    @State private var argumentsText: String
    @State private var keyValuesText: String
    @State private var url: String

    init(server: MCPServerConfig, onSave: @escaping (MCPServerConfig) -> Void) {
        self.server = server
        self.onSave = onSave
        _name = State(initialValue: server.name)
        _enabled = State(initialValue: server.enabled)
        switch server.transport {
        case let .stdio(command, arguments, environment):
            _isHTTP = State(initialValue: false)
            _command = State(initialValue: command)
            _argumentsText = State(initialValue: arguments.joined(separator: "\n"))
            _keyValuesText = State(initialValue: KeyValueText.format(environment))
            _url = State(initialValue: "")
        case let .http(url, headers):
            _isHTTP = State(initialValue: true)
            _command = State(initialValue: "")
            _argumentsText = State(initialValue: "")
            _keyValuesText = State(initialValue: KeyValueText.format(headers, separator: ": "))
            _url = State(initialValue: url)
        }
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Toggle("Enabled", isOn: $enabled)
            Picker("Transport", selection: $isHTTP) {
                Text("Local command (stdio)").tag(false)
                Text("Remote (HTTP)").tag(true)
            }
            if isHTTP {
                TextField("URL", text: $url)
                LabeledContent("Headers (Name: value)") {
                    TextEditor(text: $keyValuesText).font(.body.monospaced()).frame(height: 70)
                }
            } else {
                TextField("Command", text: $command)
                LabeledContent("Arguments (one per line)") {
                    TextEditor(text: $argumentsText).font(.body.monospaced()).frame(height: 70)
                }
                LabeledContent("Environment (KEY=value)") {
                    TextEditor(text: $keyValuesText).font(.body.monospaced()).frame(height: 70)
                }
            }
            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        var updated = server
        updated.name = name
        updated.enabled = enabled
        if isHTTP {
            updated.transport = .http(url: url.trimmingCharacters(in: .whitespaces), headers: KeyValueText.parse(keyValuesText, separator: ":"))
        } else {
            updated.transport = .stdio(
                command: command.trimmingCharacters(in: .whitespaces),
                arguments: argumentsText.split(separator: "\n").map(String.init).filter { !$0.isEmpty },
                environment: KeyValueText.parse(keyValuesText)
            )
        }
        onSave(updated)
    }
}

// MARK: - API keys

private struct APIKeySettings: View {
    @Environment(AppState.self) private var state
    @State private var values: [String: String] = [:]
    @State private var savedNote: String?

    private struct KeyAccount: Identifiable {
        let account: String
        let label: String
        var id: String { account }
    }

    /// One key per provider, plus one per custom OpenAI-compatible endpoint.
    private var accounts: [KeyAccount] {
        var result = [KeyAccount(account: "anthropic", label: "Anthropic"), KeyAccount(account: "openai", label: "OpenAI")]
        for agent in state.config.agents {
            if let account = agent.apiKeyAccount, !result.contains(where: { $0.account == account }) {
                result.append(KeyAccount(account: account, label: "\(agent.name) (\(agent.baseURL ?? ""))"))
            }
        }
        return result
    }

    var body: some View {
        Form {
            Section {
                ForEach(accounts) { item in
                    SecureField(item.label, text: Binding(
                        get: { values[item.account] ?? "" },
                        set: { values[item.account] = $0 }
                    ))
                }
            } footer: {
                Text("Keys are stored in your login Keychain and sent only to the provider's API.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                if let savedNote { Text(savedNote).foregroundStyle(.secondary) }
                Spacer()
                Button("Save Keys") {
                    let failed = accounts.filter { !KeychainStore.write(account: $0.account, value: values[$0.account] ?? "") }
                    savedNote = failed.isEmpty ? "Saved." : "Couldn't save: \(failed.map(\.label).joined(separator: ", "))"
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            for item in accounts { values[item.account] = KeychainStore.read(account: item.account) ?? "" }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            TextField("Default working directory", text: Binding(
                get: { state.config.defaultWorkingDirectory ?? "" },
                set: { value in state.updateConfig { $0.defaultWorkingDirectory = value.isEmpty ? nil : value } }
            ))
            Text("Terminal agents start in this directory unless the agent or the new-session sheet sets one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Helpers

private func optional(_ binding: Binding<String?>) -> Binding<String> {
    Binding(
        get: { binding.wrappedValue ?? "" },
        set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
    )
}

enum KeyValueText {
    static func format(_ values: [String: String], separator: String = "=") -> String {
        values.keys.sorted().map { "\($0)\(separator)\(values[$0]!)" }.joined(separator: "\n")
    }

    static func parse(_ text: String, separator: Character = "=") -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let index = line.firstIndex(of: separator) else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
