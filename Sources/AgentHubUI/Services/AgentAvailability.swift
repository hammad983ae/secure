import Foundation

/// Checks which agent commands are installed, using the user's login-shell PATH.
enum AgentAvailability {
    /// Returns the subset of `commands` that resolve in the user's shell.
    static func installed(_ commands: [String]) async -> Set<String> {
        let names = Set(commands.filter { !$0.isEmpty }.compactMap { $0.split(separator: " ").first.map(String.init) })
        guard !names.isEmpty else { return [] }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Prints each name that `command -v` can resolve.
        let script = names.map { name in
            let quoted = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return "command -v \(quoted) >/dev/null 2>&1 && echo \(quoted)"
        }.joined(separator: "; ")

        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-l", "-c", script]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(decoding: data, as: UTF8.self)
                    let found = output.split(separator: "\n").map(String.init)
                    continuation.resume(returning: Set(found).intersection(names))
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }
}
