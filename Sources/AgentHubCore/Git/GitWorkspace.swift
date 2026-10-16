import Foundation

/// A file changed by an agent run.
public struct ChangedFile: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case added = "A", modified = "M", deleted = "D"
    }

    public var path: String
    public var status: Status
    /// nil for binary files.
    public var additions: Int?
    public var deletions: Int?
    public var id: String { path }

    public init(path: String, status: Status, additions: Int?, deletions: Int?) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

/// What an agent run changed in a git working tree, and whether the user kept it.
public struct RunChanges: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        case pending, kept, undone
    }

    /// Repository root.
    public var root: String
    /// Tree object ids of the working tree before and after the run.
    public var before: String
    public var after: String
    public var files: [ChangedFile]
    /// Unified diff, cut at `GitWorkspace.maxDiffBytes`.
    public var diff: String
    public var truncated: Bool
    public var state: State

    public var additions: Int { files.compactMap(\.additions).reduce(0, +) }
    public var deletions: Int { files.compactMap(\.deletions).reduce(0, +) }
}

public enum GitError: Error, LocalizedError, Equatable {
    case failed(command: String, message: String)

    public var errorDescription: String? {
        switch self {
        case let .failed(command, message): return "git \(command) failed: \(message)"
        }
    }
}

/// Snapshots, diffs, and restores a working tree with plain git commands.
///
/// Snapshots are git tree objects written through a temporary index, so the
/// user's index, branches, and stash are never touched. (The blobs land in the
/// object database as unreferenced objects; `git gc` cleans them up.)
/// Blocking calls: use off the main thread.
public enum GitWorkspace {
    public static let maxDiffBytes = 400_000

    /// The repository root containing `directory`, or nil if it isn't in a git repo.
    public static func root(of directory: String) -> String? {
        guard let result = try? run(["rev-parse", "--show-toplevel"], in: directory), result.status == 0 else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Tree id of the current working tree: tracked and untracked files, minus ignored ones.
    public static func snapshot(root: String) throws -> String {
        let fm = FileManager.default
        let tempIndex = fm.temporaryDirectory.appendingPathComponent("agenthub-index-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: tempIndex) }

        // Start from a copy of the real index so unchanged files aren't re-hashed.
        if let indexPath = try? run(["rev-parse", "--git-path", "index"], in: root), indexPath.status == 0 {
            let relative = indexPath.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let absolute = relative.hasPrefix("/") ? relative : (root as NSString).appendingPathComponent(relative)
            try? fm.copyItem(atPath: absolute, toPath: tempIndex)
        }
        let env = ["GIT_INDEX_FILE": tempIndex]
        try check(run(["add", "-A", "--", "."], in: root, environment: env), "add")
        let tree = try check(run(["write-tree"], in: root, environment: env), "write-tree")
        return tree.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Files that differ between two trees.
    public static func changedFiles(from before: String, to after: String, root: String) throws -> [ChangedFile] {
        let statusText = try check(run(["diff", "--no-renames", "--name-status", "-z", before, after], in: root), "diff")
        let numstatText = try check(run(["diff", "--no-renames", "--numstat", "-z", before, after], in: root), "diff")
        return parseChanges(nameStatus: statusText, numstat: numstatText)
    }

    /// Unified diff between two trees, cut at `maxDiffBytes`.
    public static func diff(from before: String, to after: String, root: String) throws -> (text: String, truncated: Bool) {
        let text = try check(run(["diff", "--no-renames", "--no-color", "--no-ext-diff", before, after], in: root), "diff")
        guard text.utf8.count > maxDiffBytes else { return (text, false) }
        return (String(decoding: Array(text.utf8.prefix(maxDiffBytes)), as: UTF8.self), true)
    }

    /// Everything about a run's changes, or nil if nothing changed.
    public static func changes(from before: String, to after: String, root: String) throws -> RunChanges? {
        guard before != after else { return nil }
        let files = try changedFiles(from: before, to: after, root: root)
        guard !files.isEmpty else { return nil }
        let diff = try diff(from: before, to: after, root: root)
        return RunChanges(root: root, before: before, after: after, files: files, diff: diff.text, truncated: diff.truncated, state: .pending)
    }

    /// Paths from `changes` that were modified again after the run ended.
    public static func editedSinceRun(_ changes: RunChanges) throws -> [String] {
        let now = try snapshot(root: changes.root)
        guard now != changes.after else { return [] }
        let touched = Set(changes.files.map(\.path))
        return try changedFiles(from: changes.after, to: now, root: changes.root).map(\.path).filter(touched.contains)
    }

    /// Puts the run's files back the way they were before it: restores modified
    /// and deleted files from the "before" tree and removes files it created.
    public static func undo(_ changes: RunChanges) throws {
        let restore = changes.files.filter { $0.status != .added }.map(\.path)
        if !restore.isEmpty {
            // Worktree only: the user's index is left alone.
            try check(run(["restore", "--source=\(changes.before)", "--worktree", "--"] + restore, in: changes.root), "restore")
        }
        for file in changes.files where file.status == .added {
            let url = URL(fileURLWithPath: changes.root).appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Worktrees

    /// Creates a detached worktree at `path` holding the repository's current
    /// files, including uncommitted and untracked ones (but not ignored ones).
    /// Returns the tree id it started from.
    public static func createWorktree(from root: String, at path: String) throws -> String {
        let tree = try snapshot(root: root)
        var commitArgs = ["commit-tree", tree, "-m", "Agent Hub worktree snapshot"]
        if let head = try? run(["rev-parse", "--verify", "-q", "HEAD"], in: root), head.status == 0 {
            commitArgs += ["-p", head.output.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        let identity = [
            "GIT_AUTHOR_NAME": "Agent Hub", "GIT_AUTHOR_EMAIL": "agenthub@localhost",
            "GIT_COMMITTER_NAME": "Agent Hub", "GIT_COMMITTER_EMAIL": "agenthub@localhost",
        ]
        let commit = try check(run(commitArgs, in: root, environment: identity), "commit-tree")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try check(run(["worktree", "add", "--detach", path, commit], in: root), "worktree add")
        return tree
    }

    /// Everything changed in a worktree since it was created.
    public static func worktreeChanges(path: String, base: String) throws -> RunChanges? {
        try changes(from: base, to: snapshot(root: path), root: path)
    }

    /// Applies a worktree's changes to the main working tree as a patch.
    /// Fails without changing anything if the patch doesn't apply cleanly.
    public static func applyWorktree(path: String, base: String, into root: String) throws {
        let current = try snapshot(root: path)
        guard current != base else { return }
        let patch = try check(run(["diff", "--binary", "--no-color", "--no-ext-diff", base, current], in: path), "diff")
        try check(run(["apply", "--whitespace=nowarn", "-"], in: root, input: Data(patch.utf8)), "apply")
    }

    /// Removes a worktree and its folder.
    public static func removeWorktree(path: String, root: String) throws {
        let result = try run(["worktree", "remove", "--force", path], in: root)
        if result.status != 0, FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        _ = try? run(["worktree", "prune"], in: root)
    }

    // MARK: Parsing

    static func parseChanges(nameStatus: String, numstat: String) -> [ChangedFile] {
        // numstat -z: "<add>\t<del>\t<path>\0" ("-" for binary files)
        var counts: [String: (Int?, Int?)] = [:]
        for record in numstat.split(separator: "\0", omittingEmptySubsequences: true) {
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            counts[String(parts[2])] = (Int(parts[0]), Int(parts[1]))
        }
        // name-status -z: "<status>\0<path>\0" pairs
        let fields = nameStatus.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var files: [ChangedFile] = []
        var index = 0
        while index + 1 < fields.count {
            let code = fields[index].prefix(1)
            let path = fields[index + 1]
            index += 2
            let status: ChangedFile.Status
            switch code {
            case "A": status = .added
            case "D": status = .deleted
            default: status = .modified // M, T (type change)
            }
            let count = counts[path]
            files.append(ChangedFile(path: path, status: status, additions: count?.0, deletions: count?.1))
        }
        return files
    }

    // MARK: Running git

    struct Result {
        var status: Int32
        var output: String
        var error: String
    }

    static func run(_ arguments: [String], in directory: String, environment: [String: String] = [:], input: Data? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0" // don't take index locks just to refresh stat info
        env["GIT_TERMINAL_PROMPT"] = "0"
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            // Write from another thread so a full stdout pipe can't block us.
            DispatchQueue.global().async {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        // Read before waiting so a large diff can't fill the pipe and deadlock.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: outData, as: UTF8.self),
            error: String(decoding: errData, as: UTF8.self)
        )
    }

    @discardableResult
    private static func check(_ result: Result, _ command: String) throws -> String {
        guard result.status == 0 else {
            throw GitError.failed(command: command, message: result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output
    }
}

/// A unified diff split into files and hunks for display.
public struct FileDiff: Hashable, Sendable, Identifiable {
    public struct Line: Hashable, Sendable {
        public enum Kind: Sendable { case context, added, removed, hunk, note }
        public var kind: Kind
        public var text: String
    }

    public var path: String
    public var lines: [Line]
    public var id: String { path }

    public static func parse(_ diff: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var inHunk = false

        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                if let current { files.append(current) }
                // "diff --git a/path b/path": take the b/ side.
                let path = line.components(separatedBy: " b/").last ?? line
                current = FileDiff(path: path, lines: [])
                inHunk = false
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("@@") {
                inHunk = true
                current?.lines.append(Line(kind: .hunk, text: line))
            } else if !inHunk {
                if line.hasPrefix("Binary files") { current?.lines.append(Line(kind: .note, text: "Binary file changed")) }
            } else if line.hasPrefix("+") {
                current?.lines.append(Line(kind: .added, text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                current?.lines.append(Line(kind: .removed, text: String(line.dropFirst())))
            } else if line.hasPrefix("\\") {
                current?.lines.append(Line(kind: .note, text: line))
            } else if !line.isEmpty || inHunk {
                current?.lines.append(Line(kind: .context, text: line.isEmpty ? "" : String(line.dropFirst())))
            }
        }
        if let current { files.append(current) }
        // Trailing empty context line from the final newline.
        return files.map { file in
            var file = file
            if file.lines.last?.kind == .context, file.lines.last?.text.isEmpty == true { file.lines.removeLast() }
            return file
        }
    }
}
