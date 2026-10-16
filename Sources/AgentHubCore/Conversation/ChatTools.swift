import Foundation

// MARK: - Pipelines

/// One step of `@claude implement → @codex review → @claude fix`.
public struct PipelineStep: Equatable, Sendable {
    public var handle: String
    public var instruction: String

    public init(handle: String, instruction: String) {
        self.handle = handle
        self.instruction = instruction
    }
}

public enum PipelineParser {
    /// Splits a message into pipeline steps, or returns nil if it isn't a
    /// pipeline. Steps are separated by `→`, `->`, or `=>`, and every step
    /// must start with an agent mention, so arrows inside ordinary text
    /// (`func f() -> Int`) don't turn a message into a pipeline.
    public static func parse(_ text: String, knownHandles: Set<String>) -> [PipelineStep]? {
        let normalized = text.replacingOccurrences(of: "→", with: "->").replacingOccurrences(of: "=>", with: "->")
        let parts = normalized.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2 else { return nil }

        var steps: [PipelineStep] = []
        for part in parts {
            let command = CommandParser.parse(part, knownHandles: knownHandles)
            guard let handle = command.mentions.first, !command.mentionsAll else { return nil }
            let instruction = command.task.isEmpty ? "Continue from the previous step's result." : command.task
            steps.append(PipelineStep(handle: handle, instruction: instruction))
        }
        return steps
    }

    /// What a step's agent is asked. The previous steps' replies reach it
    /// through the conversation context.
    public static func prompt(for step: PipelineStep, index: Int, total: Int) -> String {
        "(Step \(index + 1) of \(total) in a pipeline. Build on the previous steps' results.)\n\n\(step.instruction)"
    }
}

// MARK: - Search

/// A match in a saved chat.
public struct SearchHit: Identifiable, Hashable, Sendable {
    public var id: String
    public var conversationID: UUID
    public var entryID: UUID
    public var conversationTitle: String
    /// "You", an agent's name, or "Agent · tool" for tool calls.
    public var source: String
    public var snippet: String
    public var date: Date
}

public enum ConversationSearch {
    /// Finds messages, replies, tool commands, and tool output containing
    /// every word of `query` (case- and diacritic-insensitive), newest first.
    public static func search(_ query: String, in conversations: [Conversation], limit: Int = 200) -> [SearchHit] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }

        func matches(_ text: String) -> Bool {
            words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }

        var hits: [SearchHit] = []
        for conversation in conversations {
            for entry in conversation.entries {
                if entry.kind == .user, matches(entry.text) {
                    hits.append(hit(conversation, entry, source: "You", text: entry.text, words: words, key: "u"))
                }
                guard let run = entry.run else { continue }
                for message in run.messages {
                    let text = [message.toolArguments, message.text].compactMap { $0 }.joined(separator: "\n")
                    guard !text.isEmpty, matches(text) else { continue }
                    let source = message.role == .tool ? "\(run.agentName) · \(message.toolName ?? "tool")" : run.agentName
                    hits.append(hit(conversation, entry, source: source, text: text, words: words, key: message.id.uuidString))
                }
            }
        }
        return Array(hits.sorted { $0.date > $1.date }.prefix(limit))
    }

    private static func hit(_ conversation: Conversation, _ entry: ConversationEntry, source: String, text: String,
                            words: [String], key: String) -> SearchHit {
        SearchHit(
            id: "\(conversation.id)-\(entry.id)-\(key)",
            conversationID: conversation.id,
            entryID: entry.id,
            conversationTitle: conversation.title,
            source: source,
            snippet: snippet(text, around: words[0]),
            date: entry.date
        )
    }

    /// About 160 characters around the first match, on one line.
    static func snippet(_ text: String, around word: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(flat.prefix(160))
        }
        let start = flat.index(range.lowerBound, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 100, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}

// MARK: - Export

public enum ConversationExporter {
    /// The chat as Markdown: your messages, each agent's replies, and a short
    /// line per tool call and changed file.
    public static func markdown(_ conversation: Conversation) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        var lines = ["# \(conversation.title)", ""]
        var meta = ["_Exported from Agent Hub · \(dateFormatter.string(from: conversation.createdAt))_"]
        if let folder = conversation.workingDirectory { meta.append("_Folder: `\(folder)`_") }
        lines += meta + [""]

        for entry in conversation.entries {
            if entry.kind == .user {
                lines += ["## You", "", entry.text, ""]
                for path in entry.attachments ?? [] { lines.append("- Attached: `\(path)`") }
                if !(entry.attachments ?? []).isEmpty { lines.append("") }
                continue
            }
            guard let run = entry.run else { continue }
            var heading = "## \(run.agentName)"
            if let step = run.pipelineStep { heading += " · step \(step)" }
            if run.compareGroup != nil { heading += run.picked == true ? " · picked" : " · compared" }
            lines += [heading, ""]
            for message in run.messages {
                switch message.role {
                case .assistant:
                    lines += [message.text, ""]
                case .output:
                    lines += ["```", message.text.trimmingCharacters(in: .newlines), "```", ""]
                case .tool:
                    let detail = (message.toolArguments ?? "").replacingOccurrences(of: "\n", with: " ")
                    lines.append("> 🔧 `\(message.toolName ?? "tool")` \(detail.prefix(200))")
                    lines.append("")
                case .system:
                    lines += ["> \(message.text)", ""]
                case .user:
                    lines += [message.text, ""]
                }
            }
            if let changes = run.changes {
                lines.append("**Changed \(changes.files.count) file\(changes.files.count == 1 ? "" : "s")** (\(changes.state.rawValue)):")
                for file in changes.files {
                    let counts = file.additions.map { "+\($0) −\(file.deletions ?? 0)" } ?? "binary"
                    lines.append("- `\(file.path)` \(file.status.rawValue) \(counts)")
                }
                lines.append("")
            }
            if !run.usage.isEmpty {
                lines += ["_\(run.usage.total) tokens\(run.model.map { " · \($0)" } ?? "")_", ""]
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Attachments

/// Files attached to a chat message.
public enum Attachments {
    public static let maxImageBytes = 5_000_000
    public static let maxTextBytes = 200_000

    static let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "yaml", "yml", "toml", "csv", "tsv", "xml", "html", "css", "js", "ts", "tsx", "jsx",
        "swift", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "zsh", "sql", "log",
    ]

    public static func isImage(_ path: String) -> Bool {
        imageTypes[(path as NSString).pathExtension.lowercased()] != nil
    }

    /// Provider-native user message with attachments: images as image blocks
    /// and small text files inlined; other files are listed by path.
    public static func userMessage(text: String, attachments: [String], provider: APIProvider) -> JSONValue {
        guard !attachments.isEmpty else { return ChatProtocol.userMessage(text) }
        var images: [(mediaType: String, base64: String)] = []
        var extraText: [String] = []

        for path in attachments {
            let ext = (path as NSString).pathExtension.lowercased()
            let name = (path as NSString).lastPathComponent
            if let mediaType = imageTypes[ext],
               let data = FileManager.default.contents(atPath: path), data.count <= maxImageBytes {
                images.append((mediaType, data.base64EncodedString()))
            } else if textExtensions.contains(ext),
                      let data = FileManager.default.contents(atPath: path), data.count <= maxTextBytes {
                extraText.append("File `\(name)` (\(path)):\n```\(ext)\n\(String(decoding: data, as: UTF8.self))\n```")
            } else {
                extraText.append("Attached file (not included, too large or not text): \(path)")
            }
        }

        let fullText = ([text] + extraText).joined(separator: "\n\n")
        var content: [JSONValue] = []
        switch provider {
        case .anthropic:
            for image in images {
                content.append(["type": "image", "source": ["type": "base64", "media_type": .string(image.mediaType), "data": .string(image.base64)]])
            }
            content.append(["type": "text", "text": .string(fullText)])
        case .openai, .openaiCompatible:
            content.append(["type": "text", "text": .string(fullText)])
            for image in images {
                content.append(["type": "image_url", "image_url": ["url": .string("data:\(image.mediaType);base64,\(image.base64)")]])
            }
        }
        return ["role": "user", "content": .array(content)]
    }

    /// For terminal agents: the task plus the attached paths, which the agent can open itself.
    public static func headlessPrompt(text: String, attachments: [String]) -> String {
        guard !attachments.isEmpty else { return text }
        let list = attachments.map { "- \($0)" }.joined(separator: "\n")
        return "\(text)\n\nAttached files (read them as needed):\n\(list)"
    }
}
