import SwiftUI
import AppKit

/// GitHub-style Markdown rendering for README / docs files. Block structure
/// comes from `MarkdownParser` (headings, nested and task lists, quotes,
/// fenced code, GFM tables, images, rules); inline emphasis / code spans /
/// links / strikethrough come from `AttributedString(markdown:)`.
///
/// Visual choices follow GitHub's README look: H1/H2 underlined, inline
/// code on a tinted chip, code blocks in a card with the language, syntax
/// colors (`CodeHighlighter`) and a copy button, bordered zebra-striped
/// tables, task-list checkboxes, GitHub alert callouts (`> [!NOTE]` ...).
struct MarkdownView: View {
    let text: String
    private let blocks: [MarkdownBlock]

    init(text: String) {
        self.text = text
        self.blocks = MarkdownParser.parse(text)
    }

    var body: some View {
        MarkdownBlocksView(blocks: blocks)
            .textSelection(.enabled)
    }
}

// MARK: - Block list

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    var spacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            MarkdownHeading(level: level, text: text)
        case .paragraph(let text):
            MarkdownInline.text(text, size: MarkdownStyle.bodySize)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            AnyView(MarkdownListView(ordered: ordered, start: start, items: items, depth: 0))
        case .quote(let blocks):
            AnyView(MarkdownQuote(blocks: blocks))
        case .code(let language, let code):
            MarkdownCodeBlock(language: language, code: code)
        case .table(let header, let alignments, let rows):
            MarkdownTable(header: header, alignments: alignments, rows: rows)
        case .image(let alt, let url):
            MarkdownImage(alt: alt, url: url)
        case .rule:
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 3)
                .clipShape(Capsule())
                .padding(.vertical, 6)
        }
    }
}

enum MarkdownStyle {
    static let bodySize: CGFloat = 14
    static let border = Color.secondary.opacity(0.25)
    static let subtleFill = Color.secondary.opacity(0.08)
}

// MARK: - Inline

enum MarkdownInline {
    /// Inline Markdown → `Text`: code spans get a monospaced font on a
    /// tinted chip, links the accent color (and stay clickable).
    static func text(_ raw: String, size: CGFloat, weight: Font.Weight = .regular) -> Text {
        guard var attributed = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return Text(raw).font(.system(size: size, weight: weight))
        }
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = Font.system(size: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight)
            if intent.contains(.emphasized) { font = font.italic() }
            if intent.contains(.code) {
                font = .system(size: size * 0.9, design: .monospaced)
                attributed[run.range].backgroundColor = Color.secondary.opacity(0.16)
                attributed[run.range].foregroundColor = Color(nsColor: .systemPink)
            }
            attributed[run.range].font = font
            if run.link != nil {
                attributed[run.range].foregroundColor = .accentColor
                attributed[run.range].underlineStyle = .single
            }
        }
        return Text(attributed)
    }
}

// MARK: - Headings

private struct MarkdownHeading: View {
    let level: Int
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownInline.text(text, size: size, weight: level <= 2 ? .bold : .semibold)
                .foregroundStyle(level == 6 ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if level <= 2 {
                Rectangle().fill(MarkdownStyle.border).frame(height: 1)
            }
        }
        .padding(.top, level <= 2 ? 10 : 4)
    }

    private var size: CGFloat {
        switch level {
        case 1: 28
        case 2: 22
        case 3: 18
        case 4: 16
        case 5: 14
        default: 13
        }
    }
}

// MARK: - Lists

private struct MarkdownListView: View {
    let ordered: Bool
    let start: Int
    let items: [MarkdownListItem]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(index: index, item: item)
                    VStack(alignment: .leading, spacing: 6) {
                        MarkdownInline.text(item.text, size: MarkdownStyle.bodySize)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            if case .list(let o, let s, let nested) = child {
                                AnyView(MarkdownListView(ordered: o, start: s, items: nested, depth: depth + 1))
                            } else {
                                AnyView(MarkdownBlockView(block: child))
                            }
                        }
                    }
                }
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func marker(index: Int, item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                .font(.system(size: 13))
                .frame(width: 18)
        } else if ordered {
            Text("\(start + index).")
                .font(.system(size: MarkdownStyle.bodySize).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
        } else {
            Text(["•", "◦", "▪"][depth % 3])
                .font(.system(size: MarkdownStyle.bodySize, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
    }
}

// MARK: - Quotes and GitHub alerts

private struct MarkdownQuote: View {
    let blocks: [MarkdownBlock]

    /// GitHub alert syntax: a quote whose first line is `[!NOTE]` etc.
    private var alert: (title: String, icon: String, color: Color, rest: [MarkdownBlock])? {
        guard case .paragraph(let first)? = blocks.first else { return nil }
        let kinds: [(String, String, String, Color)] = [
            ("[!NOTE]", "Note", "info.circle", .blue),
            ("[!TIP]", "Tip", "lightbulb", .green),
            ("[!IMPORTANT]", "Important", "exclamationmark.bubble", .purple),
            ("[!WARNING]", "Warning", "exclamationmark.triangle", .orange),
            ("[!CAUTION]", "Caution", "exclamationmark.octagon", .red),
        ]
        for (tag, title, icon, color) in kinds where first.uppercased().hasPrefix(tag) {
            let remainder = String(first.dropFirst(tag.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = (remainder.isEmpty ? [] : [MarkdownBlock.paragraph(remainder)]) + blocks.dropFirst()
            return (title, icon, color, rest)
        }
        return nil
    }

    var body: some View {
        let accent = alert?.color ?? Color.secondary.opacity(0.6)
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                if let alert {
                    Label(alert.title, systemImage: alert.icon)
                        .font(.system(size: MarkdownStyle.bodySize, weight: .semibold))
                        .foregroundStyle(alert.color)
                    MarkdownBlocksView(blocks: alert.rest, spacing: 8)
                } else {
                    MarkdownBlocksView(blocks: blocks, spacing: 8)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .padding(alert == nil ? 0 : 10)
        .background(alert.map { $0.color.opacity(0.07) } ?? .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Code blocks

private struct MarkdownCodeBlock: View {
    let language: String
    let code: String

    @State private var copied = false
    @Environment(\.codeTheme) private var theme

    private var codeLanguage: CodeLanguage { CodeLanguage.fromFenceInfo(language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : (codeLanguage == .plain ? language : codeLanguage.displayName))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            Rectangle().fill(MarkdownStyle.border).frame(height: 1)
            ScrollView(.horizontal) {
                Text(highlighted)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .background(theme.swiftUIBackground)
        }
        .background(MarkdownStyle.subtleFill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(MarkdownStyle.border, lineWidth: 1))
    }

    /// Highlighted with the Settings code theme (same colors as the file viewers).
    private var highlighted: AttributedString {
        CodeHighlighter.highlightForText(code, language: codeLanguage, theme: theme, fontSize: 12.5)
    }
}

extension CodeLanguage {
    /// Language from a fenced code block's info string (```cs, ```bash ...).
    static func fromFenceInfo(_ info: String) -> CodeLanguage {
        switch info.lowercased() {
        case "cs", "csharp", "c#": .csharp
        case "js", "javascript", "jsx", "node": .javascript
        case "ts", "typescript", "tsx": .typescript
        case "json", "jsonc": .json
        case "xml", "csproj", "svg": .xml
        case "html", "htm", "cshtml", "razor", "vue": .html
        case "md", "markdown": .markdown
        case "yml", "yaml": .yaml
        case "py", "python": .python
        case "sql", "mysql", "postgresql", "tsql": .sql
        case "sh", "bash", "shell", "zsh", "console", "powershell", "ps1", "cmd": .shell
        case "dockerfile", "docker": .dockerfile
        case "css", "scss", "less": .css
        case "java": .java
        case "kt", "kotlin": .kotlin
        case "go", "golang": .go
        default: .plain
        }
    }
}

// MARK: - Tables

private struct MarkdownTable: View {
    let header: [String]
    let alignments: [MarkdownAlignment]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], column: column, isHeader: true)
                            .gridColumnAlignment(horizontal(column))
                    }
                }
                .background(Color.secondary.opacity(0.12))
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            cell(column < rows[row].count ? rows[row][column] : "", column: column, isHeader: false)
                        }
                    }
                    .background(row % 2 == 1 ? Color.secondary.opacity(0.05) : Color.clear)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(MarkdownStyle.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(1)
        }
    }

    private func cell(_ text: String, column: Int, isHeader: Bool) -> some View {
        MarkdownInline.text(text, size: 13, weight: isHeader ? .semibold : .regular)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 60, maxWidth: 380, alignment: frameAlignment(column))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .overlay(alignment: .trailing) {
                if column < header.count - 1 {
                    Rectangle().fill(MarkdownStyle.border).frame(width: 1)
                }
            }
            .overlay(alignment: .top) {
                if !isHeader { Rectangle().fill(MarkdownStyle.border).frame(height: 1) }
            }
    }

    private func horizontal(_ column: Int) -> HorizontalAlignment {
        switch column < alignments.count ? alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch column < alignments.count ? alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

// MARK: - Images

private struct MarkdownImage: View {
    let alt: String
    let url: String

    var body: some View {
        if let remote = URL(string: url), remote.scheme == "http" || remote.scheme == "https" {
            AsyncImage(url: remote) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 720, alignment: .leading)
                case .failure:
                    placeholder(note: "couldn't load")
                default:
                    ProgressView().controlSize(.small)
                }
            }
        } else {
            // Repo-relative images live in CodeCommit, not on the web.
            placeholder(note: url)
        }
    }

    private func placeholder(note: String) -> some View {
        Label("\(alt.isEmpty ? "Image" : alt) (\(note))", systemImage: "photo")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
            .background(MarkdownStyle.subtleFill)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
