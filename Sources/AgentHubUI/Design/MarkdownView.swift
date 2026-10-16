import AppKit
import SwiftUI

/// Renders agent replies: paragraphs with inline Markdown, headings, lists,
/// and fenced code blocks.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .code(language, code):
                    CodeBlock(language: language, code: code)
                case let .heading(level, content):
                    Text(inline(content))
                        .font(.system(size: level == 1 ? 18 : level == 2 ? 15.5 : 14, weight: .semibold, design: .rounded))
                        .padding(.top, 4)
                case let .paragraph(content):
                    Text(inline(content))
                        .font(Theme.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        // Style inline code spans.
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].swiftUI.font = .system(size: 12.5, design: .monospaced)
            result[run.range].swiftUI.foregroundColor = Theme.cyan
        }
        return result
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, String)
    case code(language: String, String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var language = ""

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(language: language, lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    language = String(trimmed.dropFirst(3))
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6, trimmed.dropFirst(level).hasPrefix(" ") {
                    flushParagraph()
                    blocks.append(.heading(level: level, String(trimmed.dropFirst(level + 1))))
                    continue
                }
            }
            if trimmed.isEmpty {
                flushParagraph()
            } else {
                // Render list bullets as a dot.
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    paragraph.append("• " + trimmed.dropFirst(2))
                } else {
                    paragraph.append(line)
                }
            }
        }
        if let lines = code { blocks.append(.code(language: language, lines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).hudLabel()
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.03))
            ScrollView(.horizontal) {
                Text(code)
                    .font(Theme.mono)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
