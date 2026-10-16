import AppKit
import AgentHubCore
import SwiftTerm

/// Terminal view that reports output so the hub can track agent activity.
final class HubTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?
    private var lastNotified = Date.distantPast

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        // Busy agents print thousands of chunks a second; status only needs a few updates.
        let now = Date()
        guard now.timeIntervalSince(lastNotified) > 0.25 else { return }
        lastNotified = now
        onOutput?()
    }
}

/// Owns one agent process running in a pseudo-terminal.
///
/// The terminal view lives as long as the session, not the SwiftUI view that
/// shows it, so switching between sessions never restarts an agent.
@MainActor
final class TerminalController: NSObject, LocalProcessTerminalViewDelegate {
    let view: HubTerminalView
    private(set) var tracker = ActivityTracker()
    private var pendingInput: String?
    private var timer: Timer?
    private var lastOutputHandled = Date.distantPast

    /// Called on the main thread whenever the inferred status changes.
    var onStatusChange: ((SessionStatus) -> Void)?
    /// Called on the main thread when the program sets the terminal title.
    var onTitleChange: ((String) -> Void)?

    init(spec: LaunchSpec) {
        view = HubTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.onOutput = { [weak self] in
            DispatchQueue.main.async { self?.handleOutput() }
        }
        pendingInput = spec.pendingInput

        view.startProcess(
            executable: spec.executable,
            args: spec.arguments,
            environment: Self.environment(adding: spec.environment),
            execName: nil
        )

        // Scheduled on the main run loop, so the block always runs on the main actor.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let status = self.tracker.tick(at: Date()) else { return }
                self.onStatusChange?(status)
            }
        }
    }

    /// Types text into the agent and presses Return.
    func send(_ text: String) {
        guard !tracker.isFinished else { return }
        view.send(txt: text)
        view.send(txt: "\r")
        if let status = tracker.inputSent(at: Date()) { onStatusChange?(status) }
    }

    func terminate() {
        timer?.invalidate()
        timer = nil
        view.process?.terminate()
    }

    private func handleOutput() {
        let now = Date()
        // Output arrives in many small chunks; status only needs coarse updates.
        guard now.timeIntervalSince(lastOutputHandled) > 0.25 else { return }
        lastOutputHandled = now
        if let status = tracker.outputReceived(at: now) { onStatusChange?(status) }

        // Agents that can't take the task as an argument get it typed in once
        // they have drawn their first screen.
        if let input = pendingInput {
            pendingInput = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.send(input)
            }
        }
    }

    /// The app's environment plus terminal settings and the agent's own variables.
    private static func environment(adding extra: [String: String]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["AGENT_HUB"] = "1"
        for (key, value) in extra { env[key] = value }
        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: LocalProcessTerminalViewDelegate
    //
    // Some SwiftTerm versions declare this protocol main-actor isolated and some
    // don't. `nonisolated` methods satisfy both; each hops to the main actor.

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in self?.onTitleChange?(title) }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = nil
            if let status = self.tracker.processExited(code: exitCode) { self.onStatusChange?(status) }
        }
    }
}
