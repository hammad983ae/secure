import XCTest
@testable import AgentHubCore

final class LaunchPlannerTests: XCTestCase {
    func testPositionalTaskIsQuotedOnCommandLine() {
        let spec = LaunchPlanner.plan(agent: AgentPresets.claudeCode, task: "fix the bug in 'main.swift'")
        XCTAssertEqual(spec.executable, "/bin/zsh")
        XCTAssertEqual(spec.arguments.prefix(2), ["-l", "-c"])
        XCTAssertEqual(spec.commandLine, #"exec claude 'fix the bug in '\''main.swift'\'''"#)
        XCTAssertNil(spec.pendingInput)
    }

    func testFlagPromptStyle() {
        let spec = LaunchPlanner.plan(agent: AgentPresets.gemini, task: "hello")
        XCTAssertEqual(spec.commandLine, "exec gemini -i hello")
    }

    func testTypeAfterLaunchKeepsTaskForTerminal() {
        let spec = LaunchPlanner.plan(agent: AgentPresets.aider, task: "add tests")
        XCTAssertEqual(spec.commandLine, "exec aider")
        XCTAssertEqual(spec.pendingInput, "add tests")
    }

    func testEmptyTaskIsIgnored() {
        let spec = LaunchPlanner.plan(agent: AgentPresets.claudeCode, task: "   ")
        XCTAssertEqual(spec.commandLine, "exec claude")
    }

    func testWorkingDirectoryWithTilde() {
        var agent = AgentPresets.codex
        agent.workingDirectory = "~/My Projects/app"
        let spec = LaunchPlanner.plan(agent: agent, task: nil)
        XCTAssertEqual(spec.arguments[2], #"cd "$HOME"'/My Projects/app' && exec codex"#)
    }

    func testShellAgentStartsInteractiveShellAndTypesTask() {
        let spec = LaunchPlanner.plan(agent: AgentPresets.shell, task: "ls", shell: "/bin/bash")
        XCTAssertEqual(spec.executable, "/bin/bash")
        XCTAssertEqual(spec.commandLine, "exec /bin/bash -l")
        XCTAssertEqual(spec.pendingInput, "ls")
    }

    func testClaudeGetsMCPConfigFlagOnlyWhenServersEnabled() {
        let server = MCPServerConfig(name: "fs", transport: .stdio(command: "npx", arguments: [], environment: [:]))
        let with = LaunchPlanner.plan(agent: AgentPresets.claudeCode, task: nil, mcpServers: [server], mcpConfigPath: "/tmp/mcp.json")
        XCTAssertEqual(with.commandLine, "exec claude --mcp-config /tmp/mcp.json")

        var disabled = server
        disabled.enabled = false
        let without = LaunchPlanner.plan(agent: AgentPresets.claudeCode, task: nil, mcpServers: [disabled], mcpConfigPath: "/tmp/mcp.json")
        XCTAssertEqual(without.commandLine, "exec claude")
    }

    func testCodexGetsConfigOverrides() {
        let server = MCPServerConfig(
            name: "my files",
            transport: .stdio(command: "npx", arguments: ["-y", "@mcp/fs", "/tmp"], environment: ["TOKEN": "a\"b"])
        )
        let args = MCPConfigRenderer.codexOverrides([server])
        XCTAssertEqual(args, [
            "-c", #"mcp_servers.my_files.command="npx""#,
            "-c", #"mcp_servers.my_files.args=["-y","@mcp/fs","/tmp"]"#,
            "-c", #"mcp_servers.my_files.env={TOKEN="a\"b"}"#,
        ])
    }
}

final class MCPRendererTests: XCTestCase {
    func testClaudeJSON() throws {
        let servers = [
            MCPServerConfig(name: "fs", transport: .stdio(command: "npx", arguments: ["-y", "server"], environment: [:])),
            MCPServerConfig(name: "remote", transport: .http(url: "https://example.com/mcp", headers: ["Authorization": "Bearer x"])),
            MCPServerConfig(name: "off", transport: .http(url: "https://x", headers: [:]), enabled: false),
        ]
        let data = try MCPConfigRenderer.claudeJSON(servers)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(json["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(Set(entries.keys), ["fs", "remote"])
        XCTAssertEqual(entries["fs"]?["command"] as? String, "npx")
        XCTAssertEqual(entries["fs"]?["args"] as? [String], ["-y", "server"])
        XCTAssertEqual(entries["remote"]?["type"] as? String, "http")
        XCTAssertEqual((entries["remote"]?["headers"] as? [String: String])?["Authorization"], "Bearer x")
    }
}

final class CommandParserTests: XCTestCase {
    let handles: Set<String> = ["claude", "codex", "gemini"]

    func testLeadingMentionsRoute() {
        let parsed = CommandParser.parse("@claude @Codex @claude fix tests", knownHandles: handles)
        XCTAssertEqual(parsed.mentions, ["claude", "codex"])
        XCTAssertFalse(parsed.mentionsAll)
        XCTAssertEqual(parsed.task, "fix tests")
    }

    func testMidTextAtSignStaysInTask() {
        let parsed = CommandParser.parse("@claude add @MainActor to the view model", knownHandles: handles)
        XCTAssertEqual(parsed.mentions, ["claude"])
        XCTAssertEqual(parsed.task, "add @MainActor to the view model")
    }

    func testUnknownLeadingMentionStopsParsing() {
        let parsed = CommandParser.parse("@someone please review", knownHandles: handles)
        XCTAssertEqual(parsed.mentions, [])
        XCTAssertEqual(parsed.task, "@someone please review")
    }

    func testAll() {
        let parsed = CommandParser.parse("@all  run the tests", knownHandles: handles)
        XCTAssertTrue(parsed.mentionsAll)
        XCTAssertEqual(parsed.task, "run the tests")
    }

    func testCompletions() {
        XCTAssertEqual(CommandParser.completions(for: "@c", handles: ["claude", "codex", "gemini"]), ["claude", "codex"])
        XCTAssertEqual(CommandParser.completions(for: "fix it", handles: ["claude"]), [])
    }
}

final class ActivityTrackerTests: XCTestCase {
    func testIdleThenOutputThenExit() {
        let start = Date(timeIntervalSince1970: 0)
        var tracker = ActivityTracker(idleAfter: 4, now: start)
        XCTAssertEqual(tracker.status, .running)
        XCTAssertNil(tracker.tick(at: start.addingTimeInterval(3)))
        XCTAssertEqual(tracker.tick(at: start.addingTimeInterval(5)), .needsInput)
        XCTAssertEqual(tracker.outputReceived(at: start.addingTimeInterval(6)), .running)
        XCTAssertEqual(tracker.processExited(code: 0), .done)
        // Finished sessions stay finished.
        XCTAssertNil(tracker.outputReceived(at: start.addingTimeInterval(7)))
        XCTAssertEqual(tracker.status, .done)
    }

    func testNonZeroOrSignalExitFails() {
        var a = ActivityTracker()
        XCTAssertEqual(a.processExited(code: 2), .failed)
        var b = ActivityTracker()
        XCTAssertEqual(b.processExited(code: nil), .failed)
    }
}

final class SSEParserTests: XCTestCase {
    func testParsesEventsAndMultilineData() {
        let body = """
        : keep-alive
        event: content_block_delta
        data: {"a":1}

        data: line1
        data: line2

        data: tail
        """
        let events = SSEParser.parseAll(body)
        XCTAssertEqual(events, [
            SSEEvent(event: "content_block_delta", data: #"{"a":1}"#),
            SSEEvent(event: nil, data: "line1\nline2"),
            SSEEvent(event: nil, data: "tail"),
        ])
    }

    func testCRLF() {
        var parser = SSEParser()
        XCTAssertNil(parser.feed(line: "data: x\r"))
        XCTAssertEqual(parser.feed(line: "\r"), SSEEvent(event: nil, data: "x"))
    }
}

final class ChatProtocolTests: XCTestCase {
    let history = [
        ChatMessage(role: .assistant, text: "stray greeting"),
        ChatMessage(role: .user, text: "Hi"),
        ChatMessage(role: .assistant, text: ""),
        ChatMessage(role: .system, text: "Session started"),
    ]

    func testAnthropicRequest() throws {
        var agent = AgentPresets.claudeAPI
        agent.systemPrompt = "Be brief."
        let request = try ChatProtocol.makeRequest(agent: agent, history: history, apiKey: " sk-test ")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "Be brief.")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": "Hi"]])
    }

    func testAnthropicRequiresKey() {
        XCTAssertThrowsError(try ChatProtocol.makeRequest(agent: AgentPresets.claudeAPI, history: history, apiKey: nil)) {
            XCTAssertEqual($0 as? ChatAPIError, .missingAPIKey("Anthropic"))
        }
    }

    func testOpenAICompatibleNeedsBaseURLButNoKey() throws {
        var agent = AgentDefinition(name: "Local", handle: "local", kind: .api, provider: .openaiCompatible, model: "llama3")
        XCTAssertThrowsError(try ChatProtocol.makeRequest(agent: agent, history: history, apiKey: nil))
        agent.baseURL = "http://localhost:11434/v1/"
        let request = try ChatProtocol.makeRequest(agent: agent, history: history, apiKey: nil)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testDecodeAnthropic() throws {
        let delta = SSEEvent(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#)
        XCTAssertEqual(try ChatProtocol.decode(delta, provider: .anthropic), [.text("Hello")])

        let refusal = SSEEvent(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#)
        XCTAssertEqual(try ChatProtocol.decode(refusal, provider: .anthropic).count, 1)

        let error = SSEEvent(event: "error", data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        XCTAssertThrowsError(try ChatProtocol.decode(error, provider: .anthropic)) {
            XCTAssertEqual($0 as? ChatAPIError, .provider("Overloaded"))
        }
    }

    func testDecodeOpenAI() throws {
        let chunk = SSEEvent(event: nil, data: #"{"choices":[{"delta":{"content":"Hey"},"finish_reason":null}]}"#)
        XCTAssertEqual(try ChatProtocol.decode(chunk, provider: .openai), [.text("Hey")])
        XCTAssertEqual(try ChatProtocol.decode(SSEEvent(event: nil, data: "[DONE]"), provider: .openai), [])
    }

    func testErrorMessageExtraction() {
        XCTAssertEqual(ChatProtocol.errorMessage(from: #"{"error":{"message":"bad key"}}"#), "bad key")
        XCTAssertEqual(ChatProtocol.errorMessage(from: "  "), "No details.")
    }
}

final class HubStoreTests: XCTestCase {
    func testRoundTripAndMCPFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HubStore(directory: dir)
        XCTAssertEqual(store.load(), HubConfiguration()) // defaults when missing

        var config = HubConfiguration()
        config.mcpServers = [MCPServerConfig(name: "fs", transport: .stdio(command: "npx", arguments: [], environment: [:]))]
        config.agents.append(AgentDefinition(name: "Mine", handle: "mine", kind: .script, command: "./run.sh"))
        try store.save(config)

        XCTAssertEqual(store.load(), config)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.mcpConfigURL.path))
    }
}
