import SwiftUI

/// Settings → Layout → File icons (persisted as `fileIconTheme` in
/// ~/.awsvisualizer): how files and folders look in every file list - S3,
/// archives opened from S3, CodeCommit, Lambda's code tree, diff file lists.
enum FileIconTheme: String, CaseIterable, Identifiable {
    /// A symbol per file type, each in its own color (default).
    case colorful
    /// The same per-type symbols, all in one neutral tone.
    case monochrome
    /// Just a folder and a page - the original look.
    case minimal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .colorful: "Colorful"
        case .monochrome: "Monochrome"
        case .minimal: "Minimal"
        }
    }
}

/// What a file list row holds, as far as its icon is concerned.
enum FileKind {
    case folder, archive, image, pdf, json, xml, markdown, yaml, code, shell, sql, table, config, text, other

    /// Classifies by extension (folders are passed in explicitly).
    init(name: String, isFolder: Bool) {
        if isFolder { self = .folder; return }
        let lower = name.lowercased()
        let ext = lower.split(separator: ".").last.map(String.init) ?? ""
        if lower.hasSuffix(".tar.gz") { self = .archive; return }
        switch ext {
        case "zip", "eff", "dat", "jar", "war", "ear", "apk", "aar", "nupkg", "vsix", "whl", "ipa", "epub", "gz", "tgz", "tar", "7z", "rar", "bz2", "xz":
            self = .archive
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "ico", "icns", "svg":
            self = .image
        case "pdf": self = .pdf
        case "json", "jsonl", "geojson": self = .json
        case "xml", "html", "htm", "xhtml", "plist", "csproj", "config", "resx", "xsd", "xsl": self = .xml
        case "md", "markdown": self = .markdown
        case "yml", "yaml": self = .yaml
        case "cs", "csx", "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "swift", "py", "java", "kt", "go", "rb", "php", "c", "h", "cpp", "hpp", "rs", "scala", "css", "scss":
            self = .code
        case "sh", "bash", "zsh", "ps1", "bat", "cmd": self = .shell
        case "sql": self = .sql
        case "csv", "tsv", "xls", "xlsx": self = .table
        case "env", "ini", "toml", "cfg", "conf", "properties", "editorconfig", "gitignore", "dockerfile": self = .config
        case "txt", "log", "out", "text": self = .text
        default: self = lower == "dockerfile" || lower == "makefile" ? .config : .other
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .archive: "doc.zipper"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .json: "curlybraces"
        case .xml: "chevron.left.forwardslash.chevron.right"
        case .markdown: "text.alignleft"
        case .yaml: "list.bullet.indent"
        case .code: "chevron.left.slash.chevron.right"
        case .shell: "terminal"
        case .sql: "cylinder"
        case .table: "tablecells"
        case .config: "gearshape"
        case .text: "doc.text"
        case .other: "doc"
        }
    }

    var color: Color {
        switch self {
        case .folder: Color(hex: "#3B82F6")
        case .archive: Color(hex: "#A16207")
        case .image: Color(hex: "#9333EA")
        case .pdf: Color(hex: "#DC2626")
        case .json: Color(hex: "#CA8A04")
        case .xml: Color(hex: "#EA580C")
        case .markdown: Color(hex: "#0D9488")
        case .yaml: Color(hex: "#DB2777")
        case .code: Color(hex: "#4F46E5")
        case .shell: Color(hex: "#16A34A")
        case .sql: Color(hex: "#0891B2")
        case .table: Color(hex: "#15803D")
        case .config: Color(hex: "#64748B")
        case .text, .other: .secondary
        }
    }
}

private struct FileIconThemeKey: EnvironmentKey {
    static let defaultValue: FileIconTheme = .colorful
}

extension EnvironmentValues {
    /// Injected at the app root from `AppState.fileIconTheme`.
    var fileIconTheme: FileIconTheme {
        get { self[FileIconThemeKey.self] }
        set { self[FileIconThemeKey.self] = newValue }
    }
}

/// The icon in front of a file or folder name, in the theme picked in
/// Settings. Every file list uses this instead of hard-coding a symbol.
struct FileIcon: View {
    let name: String
    var isFolder = false
    /// An archive currently opened like a folder (S3) - drawn as a folder
    /// in the archive's color.
    var isOpenArchive = false

    @Environment(\.fileIconTheme) private var theme

    var body: some View {
        let kind = FileKind(name: name, isFolder: isFolder)
        let symbol: String
        let color: Color
        switch theme {
        case .colorful:
            symbol = isOpenArchive ? "folder.fill" : kind.symbol
            color = isOpenArchive ? FileKind.archive.color : kind.color
        case .monochrome:
            symbol = isOpenArchive ? "folder.fill" : kind.symbol
            color = kind == .folder || isOpenArchive ? .accentColor : .secondary
        case .minimal:
            symbol = isFolder || isOpenArchive ? "folder.fill" : (kind == .archive ? "doc.zipper" : "doc")
            color = isFolder || isOpenArchive ? .accentColor : .secondary
        }
        return Image(systemName: symbol)
            .foregroundStyle(color)
            .frame(width: 16)
    }
}
