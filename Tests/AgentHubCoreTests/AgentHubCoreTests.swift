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

final class HeadlessTests: XCTestCase {
    func testClaudeHeadlessCommand() throws {
        var agent = AgentPresets.claudeCode
        agent.workingDirectory = "/tmp/proj"
        let server = MCPServerConfig(name: "fs", transport: .stdio(command: "npx", arguments: [], environment: [:]))
        let spec = try XCTUnwrap(LaunchPlanner.headless(agent: agent, prompt: "fix it", resumeID: "abc", mcpServers: [server], mcpConfigPath: "/tmp/m.json"))
        XCTAssertEqual(spec.commandLine, "exec claude -p --output-format stream-json --verbose --permission-mode acceptEdits --mcp-config /tmp/m.json --resume abc 'fix it'")
        XCTAssertEqual(spec.arguments.last, "cd /tmp/proj && " + spec.commandLine)
        XCTAssertEqual(spec.environment["NO_COLOR"], "1")
    }

    func testCodexHeadlessCommandAndPermissions() throws {
        var agent = AgentPresets.codex
        agent.headlessPermission = .readOnly
        let spec = try XCTUnwrap(LaunchPlanner.headless(agent: agent, prompt: "review", resumeID: "t-1"))
        XCTAssertEqual(spec.commandLine, "exec codex exec --json --skip-git-repo-check --sandbox read-only resume t-1 review")
        XCTAssertEqual(LaunchPlanner.interactiveResumeArguments(for: agent, resumeID: "t-1"), ["resume", "t-1"])
    }

    func testTextAgentsAndShell() throws {
        let gemini = try XCTUnwrap(LaunchPlanner.headless(agent: AgentPresets.gemini, prompt: "hi there"))
        XCTAssertEqual(gemini.commandLine, "exec gemini -p 'hi there'")
        let shell = try XCTUnwrap(LaunchPlanner.headless(agent: AgentPresets.shell, prompt: "ls -la | head"))
        XCTAssertEqual(shell.commandLine, "ls -la | head")
        var none = AgentPresets.claudeCode
        none.headless = .none
        XCTAssertNil(LaunchPlanner.headless(agent: none, prompt: "x"))
    }

    func testClaudeStreamParser() {
        var parser = ClaudeStreamParser()
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"s1","model":"claude-opus-5-5","tools":[]}"#,
            #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"Looking."}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100}}}"#,
            #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100}}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":[{"type":"text","text":"a.txt"}],"is_error":false}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.12,"session_id":"s1"}"#,
        ]
        let events = lines.flatMap { parser.parse(line: $0) }
        XCTAssertEqual(events, [
            .started(sessionID: "s1", model: "claude-opus-5-5"),
            .text("Looking."),
            .usage(TokenUsage(input: 10, output: 5, cacheRead: 100), model: "claude-opus-5-5"),
            .toolStarted(id: "tu1", name: "Bash", detail: "ls"),
            .toolFinished(id: "tu1", output: "a.txt", isError: false),
            .finished(isError: false, message: nil, costUSD: 0.12),
        ])
    }

    func testCodexStreamParser() {
        var parser = CodexStreamParser()
        let lines = [
            #"{"type":"thread.started","thread_id":"th1"}"#,
            #"{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"ls","status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"ls","aggregated_output":"a.txt\n","exit_code":0,"status":"completed"}}"#,
            #"{"type":"item.completed","item":{"id":"i2","type":"file_change","changes":[{"path":"a.txt","kind":"update"}],"status":"completed"}}"#,
            #"{"type":"item.completed","item":{"id":"i3","type":"agent_message","text":"Done."}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7}}"#,
        ]
        let events = lines.flatMap { parser.parse(line: $0) }
        XCTAssertEqual(events, [
            .started(sessionID: "th1", model: nil),
            .toolStarted(id: "i1", name: "shell", detail: "ls"),
            .toolFinished(id: "i1", output: "a.txt\n", isError: false),
            .toolStarted(id: "i2", name: "edit", detail: "update a.txt"),
            .toolFinished(id: "i2", output: "update a.txt", isError: false),
            .text("Done."),
            .usage(TokenUsage(input: 60, output: 7, cacheRead: 40), model: nil),
        ])
        XCTAssertEqual(parser.parse(line: #"{"type":"turn.failed","error":{"message":"boom"}}"#), [.finished(isError: true, message: "boom", costUSD: nil)])
    }

    func testANSIStripping() {
        XCTAssertEqual(TextOutputParser.stripANSI("\u{1B}[1;32mok\u{1B}[0m\r"), "ok")
    }

    /// Runs a real process through the headless runner.
    func testRunnerStreamsShellOutput() async throws {
        let spec = try XCTUnwrap(LaunchPlanner.headless(agent: AgentPresets.shell, prompt: "echo one; echo two", shell: "/bin/sh"))
        var outputs: [String] = []
        var finished: HeadlessEvent?
        for try await event in HeadlessRunner().run(spec, style: .textOutput(arguments: [])) {
            switch event {
            case let .output(text): outputs.append(text)
            case .finished: finished = event
            default: break
            }
        }
        XCTAssertEqual(outputs, ["one\n", "two\n"])
        XCTAssertEqual(finished, .finished(isError: false, message: nil, costUSD: nil))
    }

    func testRunnerReportsFailure() async throws {
        let spec = try XCTUnwrap(LaunchPlanner.headless(agent: AgentPresets.shell, prompt: "echo bad >&2; exit 3", shell: "/bin/sh"))
        var last: HeadlessEvent?
        for try await event in HeadlessRunner().run(spec, style: .textOutput(arguments: [])) { last = event }
        XCTAssertEqual(last, .finished(isError: true, message: "bad", costUSD: nil))
    }
}

final class ConversationTests: XCTestCase {
    func testChatCommandFindsInlineMentions() {
        let handles: Set<String> = ["claude", "codex"]
        XCTAssertEqual(CommandParser.chatCommand("can you @claude look at this?", knownHandles: handles).mentions, ["claude"])
        XCTAssertEqual(CommandParser.chatCommand("@codex review what @claude did", knownHandles: handles).mentions, ["codex"])
        XCTAssertEqual(CommandParser.chatCommand("@codex review what @claude did", knownHandles: handles).task, "review what @claude did")
    }

    func testContextSharesOtherAgentsReplies() {
        var conversation = Conversation()
        conversation.entries.append(.user("@claude find the bug"))
        var run = AgentRun(agent: AgentPresets.claudeCode)
        run.messages = [ChatMessage(role: .assistant, text: "The bug is in cart.ts")]
        run.status = .done
        conversation.entries.append(.run(run))

        let prompt = ConversationContext.prompt(task: "fix it", for: AgentPresets.codex.id, in: conversation)
        XCTAssertTrue(prompt.contains(#"<reply agent="Claude Code">"#))
        XCTAssertTrue(prompt.contains("The bug is in cart.ts"))
        XCTAssertTrue(prompt.hasSuffix("fix it"))

        // Claude itself doesn't get its own reply echoed back.
        XCTAssertEqual(ConversationContext.prompt(task: "more", for: AgentPresets.claudeCode.id, in: conversation), "more")

        // Once seen, it isn't repeated.
        let count = conversation.entries.count
        conversation.updateParticipant(AgentPresets.codex.id) { $0.seenEntryCount = count }
        XCTAssertEqual(ConversationContext.prompt(task: "next", for: AgentPresets.codex.id, in: conversation), "next")
    }

    func testTitleAndStoreRoundTrip() throws {
        XCTAssertEqual(Conversation.title(from: "@claude @codex fix the flaky tests"), "fix the flaky tests")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationStore(directory: dir)
        var conversation = Conversation(title: "t", createdAt: Date(timeIntervalSince1970: 1000))
        conversation.updatedAt = Date(timeIntervalSince1970: 2000)
        conversation.entries.append(.user("hi", date: Date(timeIntervalSince1970: 1000)))
        try store.save(conversation)
        XCTAssertEqual(store.loadAll(), [conversation])
    }
}

final class GitWorkspaceTests: XCTestCase {
    func git(_ args: String..., in dir: String) throws {
        let result = try GitWorkspace.run(Array(args), in: dir)
        XCTAssertEqual(result.status, 0, result.error)
    }

    func testSnapshotDiffAndUndoLeaveTheIndexAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gw-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func write(_ name: String, _ text: String) throws {
            try text.write(toFile: (dir as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func read(_ name: String) -> String? {
            try? String(contentsOfFile: (dir as NSString).appendingPathComponent(name), encoding: .utf8)
        }

        try git("init", "-q", in: dir)
        try git("config", "user.email", "t@example.com", in: dir)
        try git("config", "user.name", "Test", in: dir)
        try write("keep.txt", "a\nb\n")
        try write("gone.txt", "x\n")
        try git("add", ".", in: dir)
        try git("commit", "-qm", "init", in: dir)
        try write("staged.txt", "staged\n")
        try git("add", "staged.txt", in: dir)

        let root = try XCTUnwrap(GitWorkspace.root(of: dir))
        let before = try GitWorkspace.snapshot(root: root)

        // The "agent" edits, deletes, and creates files.
        try write("keep.txt", "a\nB\nc\n")
        try FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent("gone.txt"))
        try write("new.txt", "new\n")
        let after = try GitWorkspace.snapshot(root: root)

        let changes = try XCTUnwrap(GitWorkspace.changes(from: before, to: after, root: root))
        XCTAssertEqual(changes.files, [
            ChangedFile(path: "gone.txt", status: .deleted, additions: 0, deletions: 1),
            ChangedFile(path: "keep.txt", status: .modified, additions: 2, deletions: 1),
            ChangedFile(path: "new.txt", status: .added, additions: 1, deletions: 0),
        ])
        let diffs = FileDiff.parse(changes.diff)
        XCTAssertEqual(diffs.map(\.path), ["gone.txt", "keep.txt", "new.txt"])
        XCTAssertTrue(diffs[1].lines.contains(FileDiff.Line(kind: .added, text: "B")))
        XCTAssertTrue(diffs[1].lines.contains(FileDiff.Line(kind: .removed, text: "b")))
        XCTAssertEqual(try GitWorkspace.editedSinceRun(changes), [])

        // Editing again after the run is detected.
        try write("keep.txt", "edited later\n")
        XCTAssertEqual(try GitWorkspace.editedSinceRun(changes), ["keep.txt"])

        try GitWorkspace.undo(changes)
        XCTAssertEqual(read("keep.txt"), "a\nb\n")
        XCTAssertEqual(read("gone.txt"), "x\n")
        XCTAssertNil(read("new.txt"))
        // The user's staged file is still staged.
        let status = try GitWorkspace.run(["status", "--porcelain"], in: dir)
        XCTAssertEqual(status.output.trimmingCharacters(in: .whitespacesAndNewlines), "A  staged.txt")
    }

    func testNotARepository() {
        XCTAssertNil(GitWorkspace.root(of: FileManager.default.temporaryDirectory.path))
    }

    func testParseChangesHandlesBinaryFiles() {
        let files = GitWorkspace.parseChanges(nameStatus: "M\0img.png\0A\0a b.txt\0", numstat: "-\t-\timg.png\u{0}3\t0\ta b.txt\u{0}")
        XCTAssertEqual(files, [
            ChangedFile(path: "img.png", status: .modified, additions: nil, deletions: nil),
            ChangedFile(path: "a b.txt", status: .added, additions: 3, deletions: 0),
        ])
    }
}

final class BudgetAndPromptTests: XCTestCase {
    func testBudgetStatusPerAgentAndAll() {
        let now = Date()
        let records = [
            UsageRecord(source: "Claude Code", model: "claude-opus-5-5", date: now, usage: TokenUsage(input: 1_000_000)), // $4
            UsageRecord(source: "Codex", model: "gpt-5", date: now, usage: TokenUsage(output: 100_000)),                 // $1
            UsageRecord(source: "Claude Code", model: "claude-opus-5-5", date: now.addingTimeInterval(-40 * 86400), usage: TokenUsage(input: 9_000_000)),
        ]
        let claude = Budget(agentID: AgentPresets.claudeCode.id, period: .daily, limit: .dollars(5), hardStop: true)
        let all = Budget(agentID: nil, period: .monthly, limit: .tokens(1_000_000))
        let claudeStatus = BudgetEvaluator.status(of: claude, records: records, agents: AgentPresets.all, now: now)
        XCTAssertEqual(claudeStatus.used, 4, accuracy: 0.0001)
        XCTAssertTrue(claudeStatus.isWarning)
        XCTAssertFalse(claudeStatus.isExceeded)

        let allStatus = BudgetEvaluator.status(of: all, records: records, agents: AgentPresets.all, now: now)
        XCTAssertEqual(allStatus.used, 1_100_000)
        XCTAssertTrue(allStatus.isExceeded)

        XCTAssertNil(BudgetEvaluator.blockingBudget(for: AgentPresets.claudeCode, statuses: [claudeStatus, allStatus]))
        var stopped = allStatus
        stopped.budget.hardStop = true
        XCTAssertEqual(BudgetEvaluator.blockingBudget(for: AgentPresets.codex, statuses: [claudeStatus, stopped])?.id, all.id)
    }

    func testPromptExpansion() {
        let handles: Set<String> = ["claude", "codex"]
        let prompts = SavedPrompt.defaults
        let tests = PromptLibrary.expand("/tests the cart module", prompts: prompts, knownHandles: handles)
        XCTAssertEqual(tests, "@claude Write tests for the cart module. Follow the project's existing test style, run them, and fix anything that fails.")

        let review = PromptLibrary.expand("/review @codex focus on auth", prompts: prompts, knownHandles: handles)
        XCTAssertTrue(review?.hasPrefix("@codex Review the uncommitted changes") == true)
        XCTAssertTrue(review?.hasSuffix("focus on auth") == true)

        let custom = SavedPrompt(name: "summ", title: "Summarize", body: "Summarize this.", agents: [])
        XCTAssertEqual(PromptLibrary.expand("/summ the README", prompts: [custom], knownHandles: handles), "Summarize this.\n\nthe README")
        XCTAssertNil(PromptLibrary.expand("/nope x", prompts: prompts, knownHandles: handles))
        XCTAssertNil(PromptLibrary.expand("hello", prompts: prompts, knownHandles: handles))
        XCTAssertEqual(PromptLibrary.completions(for: "/re", prompts: prompts).map(\.name), ["review"])
        XCTAssertEqual(PromptLibrary.completions(for: "/review x", prompts: prompts), [])
    }

    func testWidgetSnapshotRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var snapshot = WidgetSnapshot.placeholder
        snapshot.updated = Date(timeIntervalSince1970: 1_800_000_000)
        try snapshot.save(to: url)
        XCTAssertEqual(WidgetSnapshot.load(from: url), snapshot)
    }

    func testConfigWithoutBudgetsGetsDefaultPrompts() throws {
        let config = try JSONDecoder().decode(HubConfiguration.self, from: Data(#"{"agents":[],"mcpServers":[]}"#.utf8))
        XCTAssertEqual(config.budgets, [])
        XCTAssertEqual(config.prompts.map(\.name), ["review", "tests", "explain", "fix"])
    }
}

final class ChatToolsTests: XCTestCase {
    let handles: Set<String> = ["claude", "codex"]

    func testPipelineParsing() {
        let steps = PipelineParser.parse("@claude implement login → @codex review it -> @claude address the review", knownHandles: handles)
        XCTAssertEqual(steps, [
            PipelineStep(handle: "claude", instruction: "implement login"),
            PipelineStep(handle: "codex", instruction: "review it"),
            PipelineStep(handle: "claude", instruction: "address the review"),
        ])
        // Arrows in ordinary text don't make a pipeline.
        XCTAssertNil(PipelineParser.parse("@claude change func f() -> Int to return 2", knownHandles: handles))
        XCTAssertNil(PipelineParser.parse("@claude just one step", knownHandles: handles))
        XCTAssertEqual(PipelineParser.parse("@claude write it => @codex", knownHandles: handles)?.last?.instruction,
                       "Continue from the previous step's result.")
    }

    func testSearchFindsMessagesAndToolOutput() {
        var conversation = Conversation(title: "Flaky tests")
        conversation.entries.append(.user("why is the checkout test flaky?"))
        var run = AgentRun(agent: AgentPresets.claudeCode)
        run.messages = [
            ChatMessage(role: .assistant, text: "The discount promise isn't awaited."),
            ChatMessage(role: .tool, text: "FAIL payment.test.ts", toolName: "Bash", toolCallID: "1", toolArguments: "npm test", toolState: .succeeded),
        ]
        conversation.entries.append(.run(run))

        XCTAssertEqual(ConversationSearch.search("checkout flaky", in: [conversation]).map(\.source), ["You"])
        let tool = ConversationSearch.search("payment.test", in: [conversation])
        XCTAssertEqual(tool.map(\.source), ["Claude Code · Bash"])
        XCTAssertEqual(ConversationSearch.search("AWAITED", in: [conversation]).count, 1)
        XCTAssertTrue(ConversationSearch.search("nothing-here", in: [conversation]).isEmpty)
        XCTAssertEqual(ConversationSearch.snippet(String(repeating: "x", count: 100) + "needle", around: "needle").first, "…")
    }

    func testMarkdownExport() {
        var conversation = Conversation(title: "Release notes")
        conversation.entries.append(.user("@claude draft notes", attachments: ["/tmp/CHANGELOG.md"]))
        var run = AgentRun(agent: AgentPresets.claudeCode)
        run.pipelineStep = "1/2"
        run.messages = [ChatMessage(role: .assistant, text: "## v2\\n- faster"), ChatMessage(role: .tool, text: "", toolName: "Read", toolArguments: "CHANGELOG.md")]
        run.changes = RunChanges(root: "/r", before: "a", after: "b", files: [ChangedFile(path: "NOTES.md", status: .added, additions: 3, deletions: 0)], diff: "", truncated: false, state: .kept)
        conversation.entries.append(.run(run))
        let markdown = ConversationExporter.markdown(conversation)
        XCTAssertTrue(markdown.hasPrefix("# Release notes"))
        XCTAssertTrue(markdown.contains("## You\n\n@claude draft notes"))
        XCTAssertTrue(markdown.contains("- Attached: `/tmp/CHANGELOG.md`"))
        XCTAssertTrue(markdown.contains("## Claude Code · step 1/2"))
        XCTAssertTrue(markdown.contains("> 🔧 `Read` CHANGELOG.md"))
        XCTAssertTrue(markdown.contains("- `NOTES.md` A +3 −0"))
    }

    func testAttachmentsBuildProviderMessages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("shot.png").path
        let notes = dir.appendingPathComponent("notes.md").path
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: image))
        try "hello".write(toFile: notes, atomically: true, encoding: .utf8)

        let anthropic = Attachments.userMessage(text: "look", attachments: [image, notes], provider: .anthropic)
        XCTAssertEqual(anthropic["content"]?[0]?["type"], "image")
        XCTAssertEqual(anthropic["content"]?[0]?["source"]?["media_type"], "image/png")
        XCTAssertTrue(anthropic["content"]?[1]?["text"]?.stringValue?.contains("hello") == true)

        let openai = Attachments.userMessage(text: "look", attachments: [image], provider: .openai)
        XCTAssertEqual(openai["content"]?[1]?["type"], "image_url")
        XCTAssertTrue(openai["content"]?[1]?["image_url"]?["url"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)

        XCTAssertEqual(Attachments.userMessage(text: "plain", attachments: [], provider: .anthropic), ChatProtocol.userMessage("plain"))
        XCTAssertEqual(Attachments.headlessPrompt(text: "fix", attachments: ["/a.png"]), "fix\n\nAttached files (read them as needed):\n- /a.png")
    }

    func testWorktreeIsolationAndApply() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)").path
        let repo = (base as NSString).appendingPathComponent("repo")
        let worktree = (base as NSString).appendingPathComponent("worktrees/claude")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        func git(_ args: String...) throws { XCTAssertEqual(try GitWorkspace.run(args, in: repo).status, 0) }
        try git("init", "-q")
        try git("config", "user.email", "t@example.com")
        try git("config", "user.name", "Test")
        try "a\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-qm", "init")
        try "wip\n".write(toFile: repo + "/wip.txt", atomically: true, encoding: .utf8)

        let start = try GitWorkspace.createWorktree(from: repo, at: worktree)
        // The worktree has the uncommitted file too.
        XCTAssertEqual(try String(contentsOfFile: worktree + "/wip.txt", encoding: .utf8), "wip\n")

        try "a\nagent\n".write(toFile: worktree + "/f.txt", atomically: true, encoding: .utf8)
        // The main folder is untouched until applied.
        XCTAssertEqual(try String(contentsOfFile: repo + "/f.txt", encoding: .utf8), "a\n")
        let changes = try XCTUnwrap(GitWorkspace.worktreeChanges(path: worktree, base: start))
        XCTAssertEqual(changes.files.map(\.path), ["f.txt"])

        try GitWorkspace.applyWorktree(path: worktree, base: start, into: repo)
        XCTAssertEqual(try String(contentsOfFile: repo + "/f.txt", encoding: .utf8), "a\nagent\n")
        try GitWorkspace.removeWorktree(path: worktree, root: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
    }

    func testOldConversationFilesStillDecode() throws {
        let old = #"{"id":"6C1A0C0D-0000-4000-8000-0000000000AA","title":"t","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","entries":[{"id":"6C1A0C0D-0000-4000-8000-0000000000AB","kind":"user","date":"2026-01-01T00:00:00Z","text":"hi"}],"participants":[{"agentID":"6C1A0C0D-0000-4000-8000-000000000001","transcript":[],"seenEntryCount":0}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let conversation = try decoder.decode(Conversation.self, from: Data(old.utf8))
        XCTAssertNil(conversation.isolateAgents)
        XCTAssertNil(conversation.entries[0].attachments)
        XCTAssertNil(conversation.participants[0].worktreePath)
    }
}

final class AutomationTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    func testScheduleParsing() {
        let weekday = ScheduleParser.parse("every weekday at 9 @codex run the tests")
        XCTAssertEqual(weekday?.rule, .weekdays(hour: 9, minute: 0))
        XCTAssertEqual(weekday?.message, "@codex run the tests")

        XCTAssertEqual(ScheduleParser.parse("every morning at 9:30 @claude hi")?.rule, .daily(hour: 9, minute: 30))
        XCTAssertEqual(ScheduleParser.parse("every evening at 7 @claude hi")?.rule, .daily(hour: 19, minute: 0))
        XCTAssertEqual(ScheduleParser.parse("every day at 6pm @claude hi")?.rule, .daily(hour: 18, minute: 0))
        XCTAssertEqual(ScheduleParser.parse("every day at 12 am @claude hi")?.rule, .daily(hour: 0, minute: 0))
        XCTAssertEqual(ScheduleParser.parse("daily at 8am @claude hi")?.rule, .daily(hour: 8, minute: 0))
        XCTAssertEqual(ScheduleParser.parse("every monday at 14:30 @claude hi")?.rule, .weekly(weekday: 2, hour: 14, minute: 30))
        XCTAssertEqual(ScheduleParser.parse("every 2 hours @claude hi")?.rule, .interval(minutes: 120))
        XCTAssertEqual(ScheduleParser.parse("every 15 minutes @claude hi")?.rule, .interval(minutes: 15))
        XCTAssertEqual(ScheduleParser.parse("hourly @claude hi")?.rule, .interval(minutes: 60))
        XCTAssertEqual(ScheduleParser.parse("every day @claude hi")?.rule, .daily(hour: 9, minute: 0))
        XCTAssertNil(ScheduleParser.parse("@claude every day"))
        XCTAssertNil(ScheduleParser.parse("every blursday at 9"))
        XCTAssertNil(ScheduleParser.parse("every day at 25"))
    }

    func testNextFire() {
        let friday = date("2026-10-16T10:00:00Z") // a Friday
        XCTAssertEqual(ScheduleRule.daily(hour: 9, minute: 0).nextFire(after: friday, calendar: calendar), date("2026-10-17T09:00:00Z"))
        XCTAssertEqual(ScheduleRule.weekdays(hour: 9, minute: 0).nextFire(after: friday, calendar: calendar), date("2026-10-19T09:00:00Z"))
        XCTAssertEqual(ScheduleRule.weekly(weekday: 4, hour: 8, minute: 15).nextFire(after: friday, calendar: calendar), date("2026-10-21T08:15:00Z"))
        XCTAssertEqual(ScheduleRule.interval(minutes: 30).nextFire(after: friday, calendar: calendar), date("2026-10-16T10:30:00Z"))
    }

    func testDueOnceAfterMissedRuns() {
        var task = ScheduledTask(name: "t", message: "@claude hi", rule: .daily(hour: 9, minute: 0), createdAt: date("2026-10-10T12:00:00Z"))
        let now = date("2026-10-16T12:00:00Z")
        XCTAssertTrue(task.isDue(at: now, calendar: calendar))
        task.lastRun = now
        XCTAssertFalse(task.isDue(at: now.addingTimeInterval(60), calendar: calendar))
        XCTAssertTrue(task.isDue(at: date("2026-10-17T09:00:00Z"), calendar: calendar))
        task.enabled = false
        XCTAssertFalse(task.isDue(at: date("2026-10-18T09:00:00Z"), calendar: calendar))
    }

    func testHTTPParsing() {
        let raw = "POST /api/send?x=1 HTTP/1.1\r\nHost: mac.local\r\nAuthorization: Bearer abc\r\nContent-Length: 5\r\n\r\nhello"
        guard case let .complete(request) = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/send")
        XCTAssertEqual(request.query["x"], "1")
        XCTAssertEqual(request.bearerToken, "abc")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "hello")

        XCTAssertEqual(HTTPRequest.parse(Data(raw.dropLast(2).utf8)), .incomplete)
        XCTAssertEqual(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: x".utf8)), .incomplete)
        XCTAssertEqual(HTTPRequest.parse(Data("NONSENSE\r\n\r\n".utf8)), .invalid)

        let response = String(decoding: HTTPResponse.error(401, "no").serialized(), as: UTF8.self)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(response.contains("Cache-Control: no-store"))
    }

    func testRemoteAuth() {
        let token = RemoteAuth.makeToken()
        XCTAssertGreaterThanOrEqual(token.count, 43)
        XCTAssertNotEqual(token, RemoteAuth.makeToken())
        XCTAssertTrue(RemoteAuth.matches(token, token))
        XCTAssertFalse(RemoteAuth.matches(String(token.dropLast()), token))
        XCTAssertFalse(RemoteAuth.matches(token + "x", token))
        XCTAssertFalse(RemoteAuth.matches(nil, token))
        XCTAssertFalse(RemoteAuth.matches("", ""))
    }

    func testRemoteSnapshot() {
        var conversation = Conversation(title: "Fix tests")
        conversation.entries.append(.user("@claude fix"))
        var run = AgentRun(agent: AgentPresets.claudeAPI)
        run.messages = [
            ChatMessage(role: .assistant, text: String(repeating: "a", count: 5000)),
            ChatMessage(role: .tool, text: "", toolName: "fs__read", toolCallID: "1", toolArguments: "{}", toolState: .awaitingApproval),
        ]
        conversation.entries.append(.run(run))
        let snapshot = RemoteSnapshot.make(conversations: [conversation, Conversation()], agents: ["claude"], host: "Mac")
        XCTAssertEqual(snapshot.chats.count, 1)
        XCTAssertTrue(snapshot.chats[0].busy)
        XCTAssertTrue(snapshot.chats[0].needsApproval)
        XCTAssertEqual(snapshot.chats[0].entries[1].run?.messages[0].text.count, 4001)
        XCTAssertEqual(snapshot.chats[0].entries[1].run?.messages[1].state, "awaitingApproval")
    }

    func testOldConfigDecodesWithoutAutomation() throws {
        let config = try JSONDecoder().decode(HubConfiguration.self, from: Data("{}".utf8))
        XCTAssertTrue(config.schedules.isEmpty)
        XCTAssertFalse(config.remoteAccess)
        XCTAssertEqual(config.remotePort, HubConfiguration.defaultRemotePort)
    }
}
