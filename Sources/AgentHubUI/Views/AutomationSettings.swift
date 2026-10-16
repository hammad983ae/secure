import AgentHubCore
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Schedules

struct ScheduleSettings: View {
    @Environment(AppState.self) private var state
    @State private var name = ""
    @State private var message = ""
    @State private var when = "every weekday at 9"
    @State private var folder = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section("Scheduled tasks") {
                if state.config.schedules.isEmpty {
                    Text("Nothing scheduled. Add one below, or type /schedule in a chat, e.g. “/schedule every weekday at 9 @codex run the tests and summarize failures”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(state.config.schedules) { task in
                    ScheduleRow(task: task)
                }
            }

            Section("Add a schedule") {
                TextField("Name", text: $name, prompt: Text("Morning test run"))
                TextField("Message", text: $message, prompt: Text("@codex run the tests and summarize failures"), axis: .vertical)
                    .lineLimit(2...4)
                TextField("When", text: $when, prompt: Text("every weekday at 9"))
                Text(whenPreview)
                    .font(.caption)
                    .foregroundStyle(ScheduleParser.parse(when) == nil ? Color.red : Color.secondary)
                HStack {
                    TextField("Folder (optional)", text: $folder, prompt: Text(state.config.defaultWorkingDirectory ?? "Default folder"))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                    }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Add Schedule", action: add)
                        .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || ScheduleParser.parse(when) == nil)
                }
            }

            Section {
                Text("Schedules run while Agent Hub is open (it keeps running in the menu bar when you close the window). If the Mac was asleep or the app was closed at the scheduled time, the task runs once as soon as it can. Each schedule posts to its own chat and sends a notification when the agents finish. Turn on Launch at Login in General so schedules keep working after a restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var whenPreview: String {
        guard let parsed = ScheduleParser.parse(when) else {
            return "Try “every day at 9”, “every weekday at 6pm”, “every monday at 14:30”, or “every 2 hours”."
        }
        let next = parsed.rule.nextFire(after: Date()).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
        return "\(parsed.rule.summary) · next: \(next)"
    }

    private func add() {
        guard let parsed = ScheduleParser.parse(when) else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let handles = Set(state.chatAgents.map { $0.handle.lowercased() })
        let command = CommandParser.chatCommand(text, knownHandles: handles)
        guard !command.mentions.isEmpty || PipelineParser.parse(text, knownHandles: handles) != nil else {
            error = "Mention the agent that should do it, like @codex."
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let task = ScheduledTask(
            name: trimmedName.isEmpty ? Conversation.title(from: command.task) : trimmedName,
            message: text,
            rule: parsed.rule,
            workingDirectory: folder.trimmingCharacters(in: .whitespaces).isEmpty ? nil : folder
        )
        state.updateConfig { $0.schedules.append(task) }
        name = ""
        message = ""
        folder = ""
        error = nil
    }
}

private struct ScheduleRow: View {
    @Environment(AppState.self) private var state
    let task: ScheduledTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { task.enabled },
                set: { value in update { $0.enabled = value } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.name).font(.headline)
                Text(task.message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Run Now") { state.runSchedule(task.id) }
            if task.conversationID.flatMap(state.conversation(id:)) != nil {
                Button("Open Chat") {
                    if let id = task.conversationID { state.selection = .chat(id) }
                }
            }
            Button(role: .destructive) {
                state.updateConfig { $0.schedules.removeAll { $0.id == task.id } }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private var detail: String {
        var parts = [task.rule.summary]
        if task.enabled, let next = task.nextRun() {
            parts.append("next " + (next < Date() ? "now" : next.formatted(date: .abbreviated, time: .shortened)))
        }
        if let last = task.lastRun { parts.append("last " + last.formatted(date: .abbreviated, time: .shortened)) }
        if let folder = task.workingDirectory { parts.append((folder as NSString).lastPathComponent) }
        return parts.joined(separator: " · ")
    }

    private func update(_ change: @escaping (inout ScheduledTask) -> Void) {
        state.updateConfig { config in
            if let index = config.schedules.firstIndex(where: { $0.id == task.id }) { change(&config.schedules[index]) }
        }
    }
}

// MARK: - Remote access

struct RemoteSettings: View {
    @Environment(AppState.self) private var state
    @State private var port = ""
    @State private var selectedLink = 0
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Phone access") {
                Toggle("Let my phone watch and control Agent Hub over the local network", isOn: Binding(
                    get: { state.config.remoteAccess },
                    set: { value in state.updateConfig { $0.remoteAccess = value } }
                ))
                HStack {
                    TextField("Port", text: $port)
                        .frame(width: 140)
                        .onSubmit(savePort)
                    Button("Save", action: savePort)
                    Spacer()
                    status
                }
            }

            if state.config.remoteAccess, !state.remoteToken.isEmpty {
                let links = state.remotePairingLinks
                Section("Pair your phone") {
                    if links.isEmpty {
                        Text("This Mac has no Wi-Fi or Ethernet address right now.").foregroundStyle(.secondary)
                    } else {
                        HStack(alignment: .top, spacing: 18) {
                            QRCodeView(text: links[min(selectedLink, links.count - 1)])
                                .frame(width: 168, height: 168)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Scan with your phone's camera, on the same Wi-Fi. Then use Share → Add to Home Screen for an app-like icon.")
                                    .font(.callout)
                                if links.count > 1 {
                                    Picker("Address", selection: $selectedLink) {
                                        ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                                            Text(Self.hostPart(of: link)).tag(index)
                                        }
                                    }
                                }
                                HStack {
                                    Button("Copy Link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(links[min(selectedLink, links.count - 1)], forType: .string)
                                    }
                                    Button("New Pairing Code…") { confirmReset = true }
                                }
                            }
                        }
                    }
                }
            }

            Section("What your phone can do") {
                Label("See every chat and live run: replies, tool steps, command output, and tokens.", systemImage: "eye")
                Label("Allow or deny tool calls from API agents that ask first.", systemImage: "hand.raised")
                Label("Stop runs and send messages, including @mentions, pipelines, and /prompts.", systemImage: "paperplane")
            }
            .font(.callout)

            Section("Security") {
                Text("The pairing link holds a random 256-bit key that's stored in your Keychain. Anyone with the link can control your agents, so don't share it; New Pairing Code signs out every paired phone. The connection is plain HTTP on your local network, so use it on networks you trust. To reach your Mac away from home, use a private network such as Tailscale and open the link with your Mac's Tailscale address, rather than forwarding the port on your router.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { port = String(state.config.remotePort) }
        .confirmationDialog("Make a new pairing code?", isPresented: $confirmReset) {
            Button("New Pairing Code", role: .destructive) { state.resetRemoteToken() }
        } message: {
            Text("Phones paired with the current code will need to scan the new one.")
        }
    }

    @ViewBuilder
    private var status: some View {
        if let error = state.remoteError {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        } else if state.isRemoteRunning {
            Label("On", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green).font(.caption)
        } else {
            Text("Off").foregroundStyle(.secondary).font(.caption)
        }
    }

    private func savePort() {
        guard let value = Int(port.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(value) else {
            port = String(state.config.remotePort)
            return
        }
        state.updateConfig { $0.remotePort = value }
    }

    static func hostPart(of link: String) -> String {
        URL(string: link)?.host ?? link
    }
}

/// A QR code for a string, drawn crisp at any size.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white))
        } else {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
        }
    }

    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
