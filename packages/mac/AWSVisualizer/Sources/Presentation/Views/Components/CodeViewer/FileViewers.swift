import SwiftUI

// MARK: - Entry point

/// Picks the viewer for a file from its extension (`CodeLanguage.detect`)
/// and shows it. Each language has its own small viewer component below so
/// a screen can also call one directly (e.g. `CSharpFileViewer(text:)`);
/// they all share `CodeFileViewer` (highlighted code, line numbers, word
/// wrap) and add their own extra modes where the format has one
/// (JSON/XML tree, Markdown preview).
struct FileContentViewer: View {
    let path: String
    let text: String

    var body: some View {
        let language = CodeLanguage.detect(path: path)
        Group {
            switch language {
            case .csharp: CSharpFileViewer(text: text)
            case .javascript: JavaScriptFileViewer(text: text)
            case .typescript: TypeScriptFileViewer(text: text)
            case .json: JsonFileViewer(text: text)
            case .xml, .html: XmlFileViewer(text: text, language: language)
            case .markdown: MarkdownFileViewer(text: text)
            case .yaml: YamlFileViewer(text: text)
            default: CodeFileViewer(text: text, language: language)
            }
        }
        .id(path)
    }
}

// MARK: - Language viewers

struct CSharpFileViewer: View {
    let text: String
    var body: some View { CodeFileViewer(text: text, language: .csharp) }
}

struct JavaScriptFileViewer: View {
    let text: String
    var body: some View { CodeFileViewer(text: text, language: .javascript) }
}

struct TypeScriptFileViewer: View {
    let text: String
    var body: some View { CodeFileViewer(text: text, language: .typescript) }
}

struct YamlFileViewer: View {
    let text: String
    var body: some View { CodeFileViewer(text: text, language: .yaml) }
}

/// JSON: the file as written (highlighted, line numbers) or as a
/// collapsible tree.
struct JsonFileViewer: View {
    let text: String
    private enum Mode: String, CaseIterable { case code = "Code", tree = "Tree" }
    @State private var mode: Mode = .code

    var body: some View {
        CodeFileViewer(text: text, language: .json, modes: {
            TabBar(selection: $mode, style: .pills)
        }, alternate: mode == .tree ? AnyView(tree) : nil)
    }

    private var tree: some View {
        Group {
            if let parsed = JSONValue.parse(text) {
                ScrollView([.vertical, .horizontal]) {
                    JSONTreeView(value: parsed, key: nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                EmptyStateView(message: "Not valid JSON - showing it as code is the only option")
            }
        }
    }
}

/// XML / HTML: the file as written or as an element tree.
struct XmlFileViewer: View {
    let text: String
    var language: CodeLanguage = .xml
    private enum Mode: String, CaseIterable { case code = "Code", tree = "Tree" }
    @State private var mode: Mode = .code

    var body: some View {
        CodeFileViewer(text: text, language: language, modes: {
            TabBar(selection: $mode, style: .pills)
        }, alternate: mode == .tree ? AnyView(tree) : nil)
    }

    private var tree: some View {
        Group {
            if let parsed = XMLFormatter.parseTree(text) {
                ScrollView([.vertical, .horizontal]) {
                    XMLTreeView(element: parsed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                EmptyStateView(message: "Not well-formed XML - the tree view needs a valid document")
            }
        }
    }
}

/// Markdown: rendered preview (default) or the highlighted source.
struct MarkdownFileViewer: View {
    let text: String
    private enum Mode: String, CaseIterable { case preview = "Preview", source = "Source" }
    @State private var mode: Mode = .preview

    var body: some View {
        CodeFileViewer(text: text, language: .markdown, modes: {
            TabBar(selection: $mode, style: .pills, icon: { $0 == .preview ? "eye" : "chevron.left.forwardslash.chevron.right" })
        }, alternate: mode == .preview ? AnyView(preview) : nil, showsWrapToggle: mode == .source)
    }

    private var preview: some View {
        ScrollView {
            MarkdownView(text: text)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared code viewer

/// Highlighted code with a line-number gutter and a toolbar: language,
/// line count and the viewer's own mode switch (if any). Word wrap follows
/// the app-wide setting (Settings default, View → Word Wrap ⌥Z to flip it)
/// instead of a toggle in every viewer.
struct CodeFileViewer<Modes: View>: View {
    let text: String
    let language: CodeLanguage
    @ViewBuilder var modes: () -> Modes
    /// When set, shown instead of the code (a viewer's other mode).
    var alternate: AnyView?
    var showsWrapToggle = true

    @Environment(\.wordWrap) private var wordWrap
    @Environment(\.codeViewerShowsLanguage) private var showsLanguage
    @Environment(\.codeTheme) private var theme
    @State private var highlighted: NSAttributedString?

    init(text: String, language: CodeLanguage, @ViewBuilder modes: @escaping () -> Modes, alternate: AnyView? = nil, showsWrapToggle: Bool = true) {
        self.text = text
        self.language = language
        self.modes = modes
        self.alternate = alternate
        self.showsWrapToggle = showsWrapToggle
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if showsLanguage {
                    Label(language.displayName, systemImage: language.systemImage)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                Text("\(lineCount) line\(lineCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                if text.utf8.count > CodeHighlighter.maxHighlightBytes {
                    Text("large file - shown without colors")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                modes()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            if let alternate {
                alternate
            } else if let highlighted {
                CodeTextView(attributedText: highlighted, wordWrap: wordWrap, theme: theme)
            } else {
                BrandedLoader(message: "Highlighting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Re-highlight when the file or the Settings theme changes.
        .task(id: "\(theme.id.rawValue)|\(text.hashValue)") {
            let source = text
            let lang = language
            let currentTheme = theme
            let result = await Task.detached(priority: .userInitiated) {
                SendableText(value: CodeHighlighter.highlight(source, language: lang, theme: currentTheme))
            }.value
            guard !Task.isCancelled else { return }
            highlighted = result.value
        }
    }

    private var lineCount: Int {
        text.isEmpty ? 0 : text.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
    }
}

extension CodeFileViewer where Modes == EmptyView {
    init(text: String, language: CodeLanguage) {
        self.init(text: text, language: language, modes: { EmptyView() })
    }
}

private struct SendableText: @unchecked Sendable {
    let value: NSAttributedString
}

private struct CodeViewerShowsLanguageKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Off where the screen already shows the file type next to the file
    /// name (CodeCommit's preview toolbar), so the viewer doesn't repeat it.
    var codeViewerShowsLanguage: Bool {
        get { self[CodeViewerShowsLanguageKey.self] }
        set { self[CodeViewerShowsLanguageKey.self] = newValue }
    }
}
