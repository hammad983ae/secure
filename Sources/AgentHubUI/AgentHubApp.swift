import AgentHubCore
import AppKit
import SwiftUI

/// The app's scenes. Launched by `main.swift` in the SwiftPM executable and
/// in the Xcode app target.
@MainActor
public struct AgentHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState(demo: Snapshot.isRequested)

    public init() {}

    public var body: some Scene {
        WindowGroup("Agent Hub", id: "main") {
            RootView()
                .environment(state)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { state.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Command Palette…") { state.showPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Mission Control") { state.selection = .board }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Usage") { state.selection = .usage }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Search Chats") { state.selection = .search }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Toggle Split View") {
                    if let session = state.selectedTerminal { state.toggleSplit(session) }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(state.selectedTerminal == nil)
                Button("Close Terminal") {
                    if let session = state.selectedTerminal { state.close(session) }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(state.selectedTerminal == nil)
            }
        }

        MenuBarExtra(isInserted: Binding(
            get: { state.config.showMenuBarWidget && !Snapshot.isRequested },
            set: { value in
                guard !Snapshot.isRequested, value != state.config.showMenuBarWidget else { return }
                state.updateConfig { $0.showMenuBarWidget = value }
            }
        )) {
            MenuBarPanel()
                .environment(state)
        } label: {
            MenuBarLabel()
                .environment(state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Under `swift run` the binary isn't a bundled app; make it a regular
        // foreground app with a Dock icon and keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Snapshot.isRequested {
            Task { @MainActor in await Snapshot.run() }
        }
    }

    /// Keep running in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
