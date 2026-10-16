import AgentHubCore
import AppKit
import SwiftUI

/// `AgentHub --snapshot <folder>` renders the main screens with demo data to
/// PNG files and quits. CI uses it to produce screenshots of the design.
@MainActor
enum Snapshot {
    static var isRequested: Bool { CommandLine.arguments.contains("--snapshot") }

    static var outputDirectory: URL {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot"), args.indices.contains(index + 1) {
            return URL(fileURLWithPath: args[index + 1])
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("snapshots")
    }

    /// Builds its own window around `RootView` with demo data, so it doesn't
    /// depend on SwiftUI opening the main window.
    static func run() async {
        let directory = outputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log("starting, output \(directory.path)")

        let state = AppState(demo: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: RootView().environment(state).frame(width: 1440, height: 900))
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(2))

        let chats = state.sortedConversations.filter { !$0.conversation.entries.isEmpty }
        var screens: [(String, SidebarItem)] = []
        if let first = chats.first { screens.append(("chat", .chat(first.id))) }
        if chats.count > 1 { screens.append(("chat-tools", .chat(chats[1].id))) }
        screens += [("usage", .usage), ("board", .board)]

        for (name, item) in screens {
            state.selection = item
            try? await Task.sleep(for: .seconds(1.5))
            capture(window, to: directory.appendingPathComponent("\(name).png"))
        }

        state.newConversation()
        try? await Task.sleep(for: .seconds(1.5))
        capture(window, to: directory.appendingPathComponent("welcome.png"))

        // The menu bar panel, in its own window.
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: MenuBarPanel().environment(state))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.orderFront(nil)
        try? await Task.sleep(for: .seconds(1.5))
        capture(panel, to: directory.appendingPathComponent("menubar.png"))

        log("done")
        exit(0)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            log("\(url.lastPathComponent) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        } else {
            log("couldn't encode \(url.lastPathComponent)")
        }
    }
}

/// Sample conversations and usage for screenshots.
@MainActor
enum DemoData {
    static func populate(_ state: AppState) {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        // 1. Two coding agents on the same problem.
        var tests = Conversation(title: "Fix the flaky checkout tests", workingDirectory: "/Users/you/code/storefront", createdAt: ago(14))
        tests.entries.append(.user("@claude @codex the checkout tests are flaky on CI — can you each take a look?", date: ago(14)))

        var claude = AgentRun(agent: AgentPresets.claudeCode, startedAt: ago(14))
        claude.model = "claude-opus-5-5"
        claude.messages = [
            ChatMessage(role: .assistant, text: "I'll reproduce it first by running the checkout suite a few times."),
            ChatMessage(role: .tool, text: "PASS  cart.test.ts\nFAIL  payment.test.ts (1 of 5 runs)\n  ● applies discount before tax\n    Expected: 90.00  Received: 100.00",
                        toolName: "Bash", toolCallID: "t1", toolArguments: "npm test -- checkout --runInBand --repeat 5", toolState: .succeeded),
            ChatMessage(role: .tool, text: "", toolName: "Read", toolCallID: "t2", toolArguments: "src/checkout/payment.ts", toolState: .succeeded),
            ChatMessage(role: .tool, text: "", toolName: "Edit", toolCallID: "t3", toolArguments: "src/checkout/payment.ts", toolState: .succeeded),
            ChatMessage(role: .assistant, text: """
            Found it. `applyDiscount` reads the cart total **before** the discount promise resolves, so the result depends on timing.

            ```ts
            const discount = await discounts.forCart(cart)   // was: not awaited
            return applyTax(cart.total - discount.amount)
            ```

            The suite now passes 20/20 runs locally.
            """),
        ]
        claude.usage = TokenUsage(input: 4_210, output: 2_830, cacheRead: 61_400, cacheWrite: 8_200)
        claude.reportedCost = 0.19
        claude.status = .done
        claude.finishedAt = ago(11)
        tests.entries.append(.run(claude))

        var codex = AgentRun(agent: AgentPresets.codex, startedAt: ago(14))
        codex.model = "gpt-5-codex"
        codex.messages = [
            ChatMessage(role: .tool, text: "src/checkout/payment.ts:42:  setTimeout(resolve, 0)\nsrc/checkout/cart.ts:17:  await sleep(10)",
                        toolName: "shell", toolCallID: "c1", toolArguments: "rg -n \"setTimeout|sleep\" src/checkout", toolState: .succeeded),
            ChatMessage(role: .tool, text: "", toolName: "shell", toolCallID: "c2", toolArguments: "npm test -- checkout --repeat 20", toolState: .running),
        ]
        codex.usage = TokenUsage(input: 3_100, output: 640, cacheRead: 18_000)
        tests.entries.append(.run(codex))
        tests.participants = [Participant(agentID: AgentPresets.claudeCode.id), Participant(agentID: AgentPresets.codex.id)]
        tests.updatedAt = ago(1)

        // 2. An API model using an MCP tool, waiting for approval.
        var planning = Conversation(title: "Plan the Q4 launch checklist", createdAt: ago(40))
        planning.entries.append(.user("@claude-api pull the open launch issues from Linear and turn them into a checklist", date: ago(40)))
        var api = AgentRun(agent: AgentPresets.claudeAPI, startedAt: ago(40))
        api.messages = [
            ChatMessage(role: .assistant, text: "I'll fetch the open issues labelled **launch** first."),
            ChatMessage(role: .tool, text: "", toolName: "linear__search_issues", toolCallID: "a1",
                        toolArguments: #"{"label":"launch","state":"open"}"#, toolState: .awaitingApproval),
        ]
        api.usage = TokenUsage(input: 1_850, output: 210, cacheRead: 3_200)
        api.status = .needsInput
        planning.entries.append(.run(api))
        planning.participants = [Participant(agentID: AgentPresets.claudeAPI.id)]
        planning.updatedAt = ago(3)

        var notes = Conversation(title: "Release notes for v2.4", createdAt: ago(300))
        notes.entries.append(.user("@openai draft release notes from the changelog", date: ago(300)))
        var openai = AgentRun(agent: AgentPresets.openAI, startedAt: ago(300))
        openai.messages = [ChatMessage(role: .assistant, text: "## v2.4\n- Faster checkout\n- Dark mode for receipts")]
        openai.status = .done
        openai.finishedAt = ago(299)
        notes.entries.append(.run(openai))
        notes.updatedAt = ago(299)

        // A week of usage.
        var usage: [UsageRecord] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let pattern: [(String, String, Double)] = [
            ("Claude Code", "claude-opus-5-5", 1.0), ("Codex", "gpt-5-codex", 0.55), ("Claude (API)", "claude-opus-5-5", 0.2),
        ]
        for dayOffset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let wave = 0.6 + 0.4 * sin(Double(dayOffset) * 1.3)
            for (source, model, weight) in pattern {
                let scale = weight * wave
                usage.append(UsageRecord(
                    source: source, model: model, date: day.addingTimeInterval(10 * 3600),
                    usage: TokenUsage(input: Int(42_000 * scale), output: Int(26_000 * scale), cacheRead: Int(380_000 * scale), cacheWrite: Int(31_000 * scale))
                ))
            }
        }

        state.seedDemo(conversations: [tests, planning, notes], usage: usage)
    }
}
