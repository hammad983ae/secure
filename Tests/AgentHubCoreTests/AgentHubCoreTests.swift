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
    let transcript: [JSONValue] = [ChatProtocol.userMessage("Hi")]
    let tool = ToolSpec(name: "fs__read", description: "Read a file", inputSchema: ["type": "object", "required": ["path"]])

    func body(_ request: URLRequest) throws -> JSONValue {
        try JSONValue.parse(XCTUnwrap(request.httpBody))
    }

    func testAnthropicRequest() throws {
        var agent = AgentPresets.claudeAPI
        agent.systemPrompt = "Be brief."
        let request = try ChatProtocol.makeRequest(agent: agent, transcript: transcript, tools: [tool], apiKey: " sk-test ")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")

        let json = try body(request)
        XCTAssertEqual(json["model"], "claude-opus-5-5")
        XCTAssertEqual(json["max_tokens"], 64000)
        XCTAssertEqual(json["stream"], true)
        XCTAssertEqual(json["system"], "Be brief.")
        XCTAssertEqual(json["fallbacks"], "default")
        XCTAssertEqual(json["messages"], [["role": "user", "content": "Hi"]])
        XCTAssertEqual(json["tools"]?[0]?["name"], "fs__read")
        XCTAssertEqual(json["tools"]?[0]?["eager_input_streaming"], true)
        XCTAssertEqual(json["tools"]?[0]?["input_schema"]?["required"], ["path"])
        // max_tokens must be an integer on the wire.
        XCTAssertTrue(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self).contains("\"max_tokens\":64000"))
    }

    func testAnthropicRequiresKey() {
        XCTAssertThrowsError(try ChatProtocol.makeRequest(agent: AgentPresets.claudeAPI, transcript: transcript, apiKey: nil)) {
            XCTAssertEqual($0 as? ChatAPIError, .missingAPIKey("Anthropic"))
        }
    }

    func testOpenAIRequestWithTools() throws {
        var agent = AgentPresets.openAI
        agent.systemPrompt = "sys"
        let request = try ChatProtocol.makeRequest(agent: agent, transcript: transcript, tools: [tool], apiKey: "k")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let json = try body(request)
        XCTAssertEqual(json["messages"]?[0], ["role": "system", "content": "sys"])
        XCTAssertEqual(json["stream_options"]?["include_usage"], true)
        XCTAssertEqual(json["tools"]?[0]?["function"]?["name"], "fs__read")
    }

    func testOpenAICompatibleNeedsBaseURLButNoKey() throws {
        var agent = AgentDefinition(name: "Local", handle: "local", kind: .api, provider: .openaiCompatible, model: "llama3")
        XCTAssertThrowsError(try ChatProtocol.makeRequest(agent: agent, transcript: transcript, apiKey: nil))
        agent.baseURL = "http://localhost:11434/v1/"
        let request = try ChatProtocol.makeRequest(agent: agent, transcript: transcript, apiKey: nil)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testErrorMessageExtraction() {
        XCTAssertEqual(ChatProtocol.errorMessage(from: #"{"error":{"message":"bad key"}}"#), "bad key")
        XCTAssertEqual(ChatProtocol.errorMessage(from: "  "), "No details.")
    }
}

final class AccumulatorTests: XCTestCase {
    func event(_ data: String) -> SSEEvent { SSEEvent(event: nil, data: data) }

    func testAnthropicTextThinkingAndToolUse() throws {
        var acc = AnthropicTurnAccumulator()
        let events = [
            #"{"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":100,"cache_read_input_tokens":20,"cache_creation_input_tokens":5,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me look."}}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tu_1","name":"fs__read","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"a.txt\"}"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#,
        ]
        var text: [StreamOutput] = []
        for e in events { text += try acc.consume(event(e)) }
        XCTAssertEqual(text, [.text("Let me look.")])

        let result = acc.result()
        XCTAssertEqual(result.stopReason, "tool_use")
        XCTAssertEqual(result.model, "claude-opus-5-5")
        XCTAssertEqual(result.usage, TokenUsage(input: 100, output: 42, cacheRead: 20, cacheWrite: 5))
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls[0].id, "tu_1")
        XCTAssertEqual(result.toolCalls[0].arguments, ["path": "a.txt"])

        let content = try XCTUnwrap(result.assistantMessage["content"]?.arrayValue)
        XCTAssertEqual(content[0], ["type": "thinking", "thinking": "hmm", "signature": "sig"])
        XCTAssertEqual(content[1], ["type": "text", "text": "Let me look."])
        XCTAssertEqual(content[2]["input"], ["path": "a.txt"])
    }

    func testAnthropicBrokenToolJSONStillProducesValidTranscript() throws {
        var acc = AnthropicTurnAccumulator()
        _ = try acc.consume(event(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"x","input":{}}}"#))
        _ = try acc.consume(event(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\": "}}"#))
        let result = acc.result()
        XCTAssertNil(result.toolCalls[0].arguments)
        XCTAssertEqual(result.assistantMessage["content"]?[0]?["input"], [:])
    }

    func testAnthropicErrorEventThrows() {
        var acc = AnthropicTurnAccumulator()
        XCTAssertThrowsError(try acc.consume(event(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))) {
            XCTAssertEqual($0 as? ChatAPIError, .provider("Overloaded"))
        }
    }

    func testOpenAIToolCallsAndUsage() throws {
        var acc = OpenAITurnAccumulator()
        let chunks = [
            #"{"model":"gpt-5","choices":[{"delta":{"content":"Sure"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"fs__read","arguments":"{\"pa"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a\"}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":50,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":10}}}"#,
            "[DONE]",
        ]
        var out: [StreamOutput] = []
        for c in chunks { out += try acc.consume(event(c)) }
        XCTAssertEqual(out, [.text("Sure")])
        let result = acc.result()
        XCTAssertEqual(result.stopReason, "tool_use")
        XCTAssertEqual(result.usage, TokenUsage(input: 40, output: 7, cacheRead: 10))
        XCTAssertEqual(result.toolCalls[0].arguments, ["path": "a"])
        XCTAssertEqual(result.assistantMessage["tool_calls"]?[0]?["function"]?["arguments"], #"{"path":"a"}"#)

        let toolMessages = OpenAITurnAccumulator.toolResultMessages([(id: "call_1", result: ToolResult(text: "hello"))])
        XCTAssertEqual(toolMessages[0], ["role": "tool", "tool_call_id": "call_1", "content": "hello"])
    }

    func testToolInputValidator() {
        let schema: JSONValue = ["type": "object", "required": ["path"]]
        XCTAssertNil(ToolInputValidator.problem(with: ["path": "x"], schema: schema))
        XCTAssertNotNil(ToolInputValidator.problem(with: [:], schema: schema))
        XCTAssertNotNil(ToolInputValidator.problem(with: nil, schema: schema))
    }

    func testAssistantText() {
        let message: JSONValue = ["role": "assistant", "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": "Hi"]]]
        XCTAssertEqual(AgentRunner.text(of: message), "Hi")
    }
}

final class JSONValueTests: XCTestCase {
    func testRoundTripAndIntegers() throws {
        let value: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": 1.5]
        let data = try value.data(sortedKeys: true)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"a":1,"b":[true,null,"x"],"c":1.5}"#)
        XCTAssertEqual(try JSONValue.parse(data), value)
    }
}

final class UsageTests: XCTestCase {
    func testClaudeCodeLogDedupesRepeatedMessages() {
        let line = #"{"type":"assistant","timestamp":"2026-10-01T10:00:00.000Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}"#
        let user = #"{"type":"user","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"hi"}}"#
        let synthetic = #"{"type":"assistant","timestamp":"2026-10-01T10:00:00Z","message":{"id":"m2","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#
        let parsed = ClaudeCodeLogParser.parse([user, line, line, synthetic].joined(separator: "\n"))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].record.usage, TokenUsage(input: 10, output: 20, cacheRead: 30, cacheWrite: 40))
        XCTAssertEqual(parsed[0].record.model, "claude-opus-5-5")
        XCTAssertEqual(parsed[0].record.source, "Claude Code")
    }

    func testCodexLogUsesDeltasOfRunningTotals() {
        let lines = [
            #"{"timestamp":"2026-10-01T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}"#,
            #"{"timestamp":"2026-10-01T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
            #"{"timestamp":"2026-10-01T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10}}}}"#,
            #"{"timestamp":"2026-10-01T10:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10}}}}"#,
            #"{"timestamp":"2026-10-01T10:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":140,"output_tokens":30}}}}"#,
        ]
        let parsed = CodexLogParser.parse(lines.joined(separator: "\n"), fileKey: "f")
        XCTAssertEqual(parsed.map(\.record.usage), [
            TokenUsage(input: 60, output: 10, cacheRead: 40),
            TokenUsage(input: 50, output: 20, cacheRead: 100),
        ])
        XCTAssertEqual(parsed.first?.record.model, "gpt-5-codex")
    }

    func testScannerReadsFilesAndDedupesAcrossFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("claude/proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","timestamp":"2026-10-01T10:00:00Z","requestId":"r","message":{"id":"m","model":"claude-sonnet-5-5","usage":{"input_tokens":1,"output_tokens":2}}}"#
        try line.write(to: project.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        try line.write(to: project.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)

        let scanner = AgentLogScanner(roots: .init(claudeProjects: [root.appendingPathComponent("claude")], codexSessions: []))
        let records = scanner.scan(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(scanner.scan(since: Date(timeIntervalSince1970: 0)).count, 1) // cached path
    }

    func testPricingAndSummary() throws {
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-1-20250805")?.input, 15)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-5-20251101")?.input, 5)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-5-5")?.input, 4)
        XCTAssertEqual(ModelPricing.price(for: "gpt-5-mini")?.input, 0.25)
        XCTAssertNil(ModelPricing.price(for: "llama3"))

        let cost = try XCTUnwrap(ModelPricing.cost(model: "claude-opus-5-5", usage: TokenUsage(input: 1_000_000, output: 1_000_000)))
        XCTAssertEqual(cost, 24, accuracy: 0.0001)

        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let records = [
            UsageRecord(source: "Claude Code", model: "claude-opus-5-5", date: day, usage: TokenUsage(input: 1_000_000)),
            UsageRecord(source: "Claude Code", model: "claude-opus-5-5", date: day, usage: TokenUsage(output: 1_000_000)),
            UsageRecord(source: "Local", model: "llama3", date: day, usage: TokenUsage(input: 500)),
            UsageRecord(source: "Old", model: "claude-opus-5-5", date: Date(timeIntervalSince1970: 0), usage: TokenUsage(input: 9)),
        ]
        let summary = UsageSummary(records: records, from: day.addingTimeInterval(-3600))
        XCTAssertEqual(summary.calls, 3)
        XCTAssertEqual(summary.knownCost, 24, accuracy: 0.0001)
        XCTAssertEqual(summary.unpricedTokens, 500)
        XCTAssertEqual(summary.rows.first?.calls, 2)
        XCTAssertNil(summary.rows.first { $0.source == "Local" }?.cost)
    }
}

final class RouterTests: XCTestCase {
    func testParseKeepsKnownHandles() {
        let agents = AgentPresets.all
        let decision = AutoRouter.parse("Sure:\n{\"handles\": [\"@Claude\", \"nope\"], \"reason\": \"code change\"}", candidates: agents)
        XCTAssertEqual(decision, RouteDecision(handles: ["claude"], reason: "code change"))
        XCTAssertNil(AutoRouter.parse("no json here", candidates: agents))
        XCTAssertNil(AutoRouter.parse(#"{"handles": ["unknown"]}"#, candidates: agents))
    }

    func testPromptListsAgentsAndTask() {
        let prompt = AutoRouter.prompt(task: "fix tests", candidates: [AgentPresets.claudeCode])
        XCTAssertTrue(prompt.contains("- claude (Claude Code, terminal coding agent)"))
        XCTAssertTrue(prompt.contains("fix tests"))
    }

    func testRouterAgentDefaultsToHaiku() {
        let config = HubConfiguration()
        XCTAssertEqual(config.routerAgent?.model, "claude-haiku-5-5")
    }
}

final class MCPTests: XCTestCase {
    func testExposedNamesAreUniqueAndValid() {
        let long = String(repeating: "x", count: 80)
        let first = MCPToolbox.exposedName(server: "my server", tool: long, taken: [])
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.hasPrefix("my_server__"))
        let second = MCPToolbox.exposedName(server: "my server", tool: long, taken: [first])
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.count, 64)
    }

    func testToolResultFlattening() {
        let result = MCPClient.toolResult(from: ["content": [["type": "text", "text": "a"], ["type": "image", "mimeType": "image/png"]], "isError": true])
        XCTAssertEqual(result, ToolResult(text: "a\n[image: image/png]", isError: true))
    }

    /// End-to-end over stdio against a tiny MCP server written in Python.
    func testStdioRoundTrip() async throws {
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { throw XCTSkip("python3 not available") }

        let script = FileManager.default.temporaryDirectory.appendingPathComponent("fake_mcp_\(UUID().uuidString).py")
        try Self.fakeServer.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }

        let client = try await MCPClient.connectStdio(name: "fake", executable: python, arguments: [script.path])
        defer { client.close() }
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo"])
        let result = try await client.callTool("echo", arguments: ["text": "hello"])
        XCTAssertEqual(result, ToolResult(text: "echo: hello"))
    }

    static let fakeServer = """
    import json, sys
    for line in sys.stdin:
        msg = json.loads(line)
        if "id" not in msg:
            continue
        method = msg.get("method")
        if method == "initialize":
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "echo", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}]}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": "echo: " + msg["params"]["arguments"]["text"]}]}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "nope"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}), flush=True)
    """
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

    func testOldConfigWithoutNewFieldsStillLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = """
        {"agents":[{"id":"6C1A0C0D-0000-4000-8000-000000000001","name":"Claude Code","handle":"claude","kind":"cli",
        "symbol":"sparkle","command":"claude","arguments":[],"environment":{},"promptStyle":{"positional":{}},
        "mcpInjection":"claudeMCPConfigFlag"}],"mcpServers":[]}
        """
        try old.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let config = HubStore(directory: dir).load()
        XCTAssertEqual(config.agents.count, 1)
        XCTAssertEqual(config.agents[0].promptStyle, .positional)
        XCTAssertTrue(config.autoRoute)
        XCTAssertTrue(config.agents[0].useTools)
        XCTAssertEqual(config.agents[0].summary, AgentPresets.claudeCode.summary)
    }

    func testHistoryAndUsageStores() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = HistoryStore(directory: dir)
        let record = SessionRecord(
            id: UUID(), agentID: AgentPresets.claudeAPI.id, agentName: "Claude (API)", agentSymbol: "bubble.left",
            kind: .chat, title: "t", createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200),
            status: .done, messages: [ChatMessage(role: .user, text: "hi", date: Date(timeIntervalSince1970: 100))],
            transcript: [ChatProtocol.userMessage("hi")], usage: TokenUsage(input: 1)
        )
        try history.save(record)
        XCTAssertEqual(history.loadAll(), [record])
        history.delete(record.id)
        XCTAssertEqual(history.loadAll(), [])

        let usage = UsageStore(directory: dir)
        let entry = UsageRecord(source: "Claude (API)", model: "claude-opus-5-5", date: Date(timeIntervalSince1970: 300), usage: TokenUsage(output: 5))
        try usage.append(entry)
        try usage.append(entry)
        XCTAssertEqual(usage.load(), [entry, entry])
    }
}
