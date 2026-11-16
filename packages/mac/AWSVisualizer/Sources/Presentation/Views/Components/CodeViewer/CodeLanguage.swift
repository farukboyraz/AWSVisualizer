import Foundation

/// Which viewer / highlighter a file gets, decided from its name. Used by
/// `FileContentViewer` to route a file to its language-specific viewer.
enum CodeLanguage: String, CaseIterable {
    case csharp, javascript, typescript, json, xml, html, markdown, yaml
    case python, sql, shell, css, java, kotlin, go, dockerfile, plain

    var displayName: String {
        switch self {
        case .csharp: "C#"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .json: "JSON"
        case .xml: "XML"
        case .html: "HTML"
        case .markdown: "Markdown"
        case .yaml: "YAML"
        case .python: "Python"
        case .sql: "SQL"
        case .shell: "Shell"
        case .css: "CSS"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .go: "Go"
        case .dockerfile: "Dockerfile"
        case .plain: "Plain text"
        }
    }

    var systemImage: String {
        switch self {
        case .json: "curlybraces"
        case .xml, .html: "chevron.left.forwardslash.chevron.right"
        case .markdown: "text.document"
        case .yaml: "list.bullet.indent"
        case .sql: "cylinder"
        case .shell, .dockerfile: "terminal"
        case .plain: "doc.plaintext"
        default: "chevron.left.slash.chevron.right"
        }
    }

    /// From a path or file name - by extension, plus a few well-known
    /// extension-less names (Dockerfile, .gitignore, ...).
    static func detect(path: String) -> CodeLanguage {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") { return .dockerfile }
        if name == "makefile" || name.hasSuffix(".env") || name == ".gitignore" || name == ".dockerignore" { return .shell }
        let ext = (name as NSString).pathExtension
        switch ext {
        case "cs", "csx": return .csharp
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "json", "jsonc", "json5", "map", "babelrc", "eslintrc": return .json
        case "xml", "csproj", "fsproj", "vbproj", "props", "targets", "config", "resx", "xaml", "xsd", "xsl", "xslt", "svg", "plist", "nuspec", "wsdl": return .xml
        case "html", "htm", "cshtml", "razor", "vue": return .html
        case "md", "markdown", "mdx": return .markdown
        case "yml", "yaml": return .yaml
        case "py", "pyw": return .python
        case "sql": return .sql
        case "sh", "bash", "zsh", "ps1", "cmd", "bat": return .shell
        case "css", "scss", "sass", "less": return .css
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "go": return .go
        default: return .plain
        }
    }
}
