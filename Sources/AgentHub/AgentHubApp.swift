import AppKit
import SwiftUI

@main
@MainActor
struct AgentHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Agent Hub") {
            ContentView()
                .environment(state)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session…") { state.showPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Task Board") { state.selection = .board }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Close Session") {
                    if let session = state.selectedSession { state.close(session) }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(state.selectedSession == nil)
            }
        }

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
