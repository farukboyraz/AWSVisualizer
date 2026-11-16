import AppKit
import SwiftUI

/// What a highlighter can color. Split the way VS Code's themes split it:
/// control-flow keywords (`if`, `return`, `await`, `import`) apart from
/// declaration keywords (`public`, `class`, `var`), function/method names
/// apart from types, and XML tag / attribute names apart from code.
enum CodeToken: String, CaseIterable {
    case comment, string, preprocessor, attribute, control, keyword, function, type, number
    case key, tag, attrName, heading, emphasis, link, code
    /// Lower-case identifiers (locals, parameters) - VS Code's light blue.
    case variable
}

/// Settings → Code theme (persisted as `codeTheme` in ~/.awsvisualizer).
enum CodeThemeID: String, CaseIterable, Identifiable {
    /// VS Code's default themes - Light+ in light mode, Dark+ in dark mode.
    case vscode = "vscode"
    case vscodeDark = "vscode-dark"
    case vscodeLight = "vscode-light"
    case github = "github"
    case monokai = "monokai"
    case xcode = "xcode"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vscode: "VS Code (follows light/dark mode)"
        case .vscodeDark: "VS Code Dark+"
        case .vscodeLight: "VS Code Light+"
        case .github: "GitHub"
        case .monokai: "Monokai"
        case .xcode: "Xcode"
        }
    }

    var theme: CodeTheme { CodeTheme.make(self) }
}

/// A full color scheme for code: token colors plus the editor's own text,
/// background and line-number colors. Adaptive themes use dynamic NSColors
/// (resolved at draw time), so highlighting can still run off the main
/// thread and follow light/dark mode.
struct CodeTheme: @unchecked Sendable {
    let id: CodeThemeID
    let foreground: NSColor
    /// nil = transparent (the surrounding view's background shows through).
    let background: NSColor?
    let lineNumber: NSColor
    let colors: [CodeToken: NSColor]
    let boldTokens: Set<CodeToken>

    func color(_ token: CodeToken) -> NSColor { colors[token] ?? foreground }

    var swiftUIBackground: Color { background.map { Color(nsColor: $0) } ?? Color.secondary.opacity(0.06) }

    // MARK: - Definitions

    private static func hex(_ value: String) -> NSColor {
        let v = UInt64(value.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Light/dark pair resolved against the drawing appearance.
    private static func adaptive(_ light: String, _ dark: String) -> NSColor {
        let l = hex(light), d = hex(dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
        }
    }

    private typealias Palette = (fg: String, bg: String, line: String, colors: [CodeToken: String])

    /// VS Code "Dark+ (default dark)" token colors.
    private static let darkPlus: Palette = ("#D4D4D4", "#1E1E1E", "#858585", [
        .comment: "#6A9955", .string: "#CE9178", .preprocessor: "#569CD6", .attribute: "#4EC9B0",
        .control: "#C586C0", .keyword: "#569CD6", .function: "#DCDCAA", .type: "#4EC9B0",
        .number: "#B5CEA8", .key: "#9CDCFE", .tag: "#569CD6", .attrName: "#9CDCFE",
        .heading: "#569CD6", .emphasis: "#D4D4D4", .link: "#3794FF", .code: "#CE9178",
        .variable: "#9CDCFE",
    ])

    /// VS Code "Light+ (default light)" token colors.
    private static let lightPlus: Palette = ("#000000", "#FFFFFF", "#237893", [
        .comment: "#008000", .string: "#A31515", .preprocessor: "#0000FF", .attribute: "#267F99",
        .control: "#AF00DB", .keyword: "#0000FF", .function: "#795E26", .type: "#267F99",
        .number: "#098658", .key: "#0451A5", .tag: "#800000", .attrName: "#E50000",
        .heading: "#800000", .emphasis: "#000000", .link: "#006AB1", .code: "#A31515",
        .variable: "#001080",
    ])

    private static let githubLight: Palette = ("#24292F", "#FFFFFF", "#8C959F", [
        .comment: "#6E7781", .string: "#0A3069", .preprocessor: "#CF222E", .attribute: "#8250DF",
        .control: "#CF222E", .keyword: "#CF222E", .function: "#8250DF", .type: "#953800",
        .number: "#0550AE", .key: "#0550AE", .tag: "#116329", .attrName: "#0550AE",
        .heading: "#0550AE", .emphasis: "#24292F", .link: "#0969DA", .code: "#0A3069",
    ])

    private static let githubDark: Palette = ("#E6EDF3", "#0D1117", "#6E7681", [
        .comment: "#8B949E", .string: "#A5D6FF", .preprocessor: "#FF7B72", .attribute: "#D2A8FF",
        .control: "#FF7B72", .keyword: "#FF7B72", .function: "#D2A8FF", .type: "#FFA657",
        .number: "#79C0FF", .key: "#79C0FF", .tag: "#7EE787", .attrName: "#79C0FF",
        .heading: "#79C0FF", .emphasis: "#E6EDF3", .link: "#58A6FF", .code: "#A5D6FF",
    ])

    private static let monokai: Palette = ("#F8F8F2", "#272822", "#90908A", [
        .comment: "#88846F", .string: "#E6DB74", .preprocessor: "#F92672", .attribute: "#A6E22E",
        .control: "#F92672", .keyword: "#66D9EF", .function: "#A6E22E", .type: "#66D9EF",
        .number: "#AE81FF", .key: "#A6E22E", .tag: "#F92672", .attrName: "#A6E22E",
        .heading: "#A6E22E", .emphasis: "#F8F8F2", .link: "#66D9EF", .code: "#E6DB74",
    ])

    private static func fixed(_ id: CodeThemeID, _ p: Palette) -> CodeTheme {
        CodeTheme(id: id, foreground: hex(p.fg), background: hex(p.bg), lineNumber: hex(p.line),
                  colors: p.colors.mapValues(hex), boldTokens: [.heading, .emphasis])
    }

    private static func pair(_ id: CodeThemeID, light: Palette, dark: Palette) -> CodeTheme {
        var colors: [CodeToken: NSColor] = [:]
        for token in CodeToken.allCases {
            colors[token] = adaptive(light.colors[token] ?? light.fg, dark.colors[token] ?? dark.fg)
        }
        return CodeTheme(id: id, foreground: adaptive(light.fg, dark.fg), background: adaptive(light.bg, dark.bg),
                         lineNumber: adaptive(light.line, dark.line), colors: colors, boldTokens: [.heading, .emphasis])
    }

    static func make(_ id: CodeThemeID) -> CodeTheme {
        switch id {
        case .vscode: pair(id, light: lightPlus, dark: darkPlus)
        case .vscodeDark: fixed(id, darkPlus)
        case .vscodeLight: fixed(id, lightPlus)
        case .github: pair(id, light: githubLight, dark: githubDark)
        case .monokai: fixed(id, monokai)
        case .xcode:
            // The app's original look: system colors, no editor background.
            CodeTheme(id: id, foreground: .labelColor, background: nil, lineNumber: .tertiaryLabelColor, colors: [
                .comment: .secondaryLabelColor, .string: .systemRed, .preprocessor: .systemOrange, .attribute: .systemBrown,
                .control: .systemPink, .keyword: .systemPink, .function: .systemIndigo, .type: .systemTeal,
                .number: .systemBlue, .key: .systemPurple, .tag: .systemPink, .attrName: .systemBrown,
                .heading: .systemBlue, .emphasis: .labelColor, .link: .linkColor, .code: .systemOrange,
            ], boldTokens: [.keyword, .control, .heading, .emphasis])
        }
    }
}

// MARK: - Environment

private struct CodeThemeKey: EnvironmentKey {
    static let defaultValue: CodeTheme = CodeThemeID.vscode.theme
}

extension EnvironmentValues {
    /// The code theme picked in Settings - injected at the app root so the
    /// viewers don't need `AppState` (and stay renderable on their own).
    var codeTheme: CodeTheme {
        get { self[CodeThemeKey.self] }
        set { self[CodeThemeKey.self] = newValue }
    }
}
