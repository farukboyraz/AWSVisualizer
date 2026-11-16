import AppKit
import SwiftUI

/// Regex-based syntax highlighting for the file viewers. Not a parser - a
/// single alternation of named groups per language, scanned left to right,
/// so whichever token starts first wins (a quote inside a comment stays
/// comment-colored, a `//` inside a string stays string-colored). Good
/// enough for reading code; no semantic analysis.
///
/// Colors are AppKit's dynamic system colors, resolved at draw time - so
/// they follow light/dark mode even though highlighting runs on a
/// background thread (see `SyntaxHighlighter`'s note on why SwiftUI's
/// `Color` bridging can't be used here).
enum CodeHighlighter {
    /// Files above this size are shown uncolored - regex highlighting of
    /// multi-megabyte files (minified bundles, generated code) costs more
    /// than it's worth to read them.
    static let maxHighlightBytes = 600_000

    /// Order matters only for picking which named group matched; the regex
    /// alternation itself decides precedence (earlier alternative wins).
    private static let tokens = CodeToken.allCases

    static func highlight(_ text: String, language: CodeLanguage, theme: CodeTheme = CodeThemeID.vscode.theme, fontSize: CGFloat = 12) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: theme.foreground])
        guard text.utf8.count <= maxHighlightBytes, let regex = regex(for: language) else { return attributed }

        let bold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let full = NSRange(location: 0, length: (text as NSString).length)
        regex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            for token in tokens {
                let range = match.range(withName: token.rawValue)
                guard range.location != NSNotFound else { continue }
                attributed.addAttribute(.foregroundColor, value: theme.color(token), range: range)
                if theme.boldTokens.contains(token) {
                    attributed.addAttribute(.font, value: bold, range: range)
                }
                break
            }
        }
        return attributed
    }

    /// Same highlighting as a SwiftUI `AttributedString` - for `Text`
    /// (Markdown code blocks, the Settings preview). Keeps the dynamic
    /// NSColors, so adaptive themes still follow light/dark mode.
    static func highlightForText(_ text: String, language: CodeLanguage, theme: CodeTheme, fontSize: CGFloat) -> AttributedString {
        let ns = highlight(text, language: language, theme: theme, fontSize: fontSize)
        var result = AttributedString()
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attributes, range, _ in
            var piece = AttributedString(ns.attributedSubstring(from: range).string)
            if let color = attributes[.foregroundColor] as? NSColor {
                piece.foregroundColor = Color(nsColor: color)
            }
            let isBold = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            piece.font = .system(size: fontSize, weight: isBold ? .semibold : .regular, design: .monospaced)
            result += piece
        }
        return result
    }

    // MARK: - Language rules

    private static let cache = NSCache<NSString, NSRegularExpression>()

    private static func regex(for language: CodeLanguage) -> NSRegularExpression? {
        if let cached = cache.object(forKey: language.rawValue as NSString) { return cached }
        guard let pattern = pattern(for: language) else { return nil }
        let options: NSRegularExpression.Options = language == .sql ? [.anchorsMatchLines, .caseInsensitive] : [.anchorsMatchLines]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        cache.setObject(regex, forKey: language.rawValue as NSString)
        return regex
    }

    /// Control-flow keywords - VS Code colors these apart from the
    /// declaration keywords (purple vs. blue in Dark+).
    private static let controlWords = "if else elif for foreach while do switch case default return break continue try catch except finally throw throws raise await yield goto import export from when match with pass in of"
    /// Lower-case identifiers - last alternative, so only what no other rule claimed.
    private static let variable = #"\b[a-z_][A-Za-z0-9_]*\b"#
    private static let functionCall = #"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#

    private static func words(_ list: String) -> String {
        #"\b(?:"# + list.split(separator: " ").joined(separator: "|") + #")\b"#
    }

    private static let cComment = #"//[^\n]*|/\*[\s\S]*?\*/"#
    private static let dqString = #""(?:[^"\\\n]|\\.)*""#
    private static let sqString = #"'(?:[^'\\\n]|\\.)*'"#
    private static let number = #"\b0[xX][0-9a-fA-F_]+\b|\b\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?[fFdDmMuUlLn]*\b"#
    private static let pascalType = #"\b[A-Z][A-Za-z0-9_]*\b"#

    private static func group(_ name: CodeToken, _ body: String) -> String { "(?<\(name.rawValue)>\(body))" }

    private static func pattern(for language: CodeLanguage) -> String? {
        switch language {
        case .csharp:
            let keywords = words("abstract as async await base bool break byte case catch char checked class const continue decimal default delegate do double dynamic else enum event explicit extern false finally fixed float for foreach get global goto if implicit in init int interface internal is lock long nameof namespace new null object operator out override params partial private protected public readonly record ref required return sbyte sealed set short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using value var virtual void volatile when where while with yield")
            return [
                group(.comment, cComment),
                group(.string, #"@"(?:[^"]|"")*"|\$@?"(?:[^"\\\n]|\\.)*"|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)'"#),
                group(.preprocessor, #"^[ \t]*#[a-z]+[^\n]*"#),
                group(.attribute, #"(?<=\[)[A-Z]\w*(?=[\](,])"#),
                group(.control, words(controlWords)),
                group(.keyword, keywords),
                group(.function, functionCall),
                group(.type, pascalType),
                group(.number, number),
                group(.variable, variable),
            ].joined(separator: "|")
        case .javascript, .typescript:
            var list = "async await break case catch class const continue debugger default delete do else export extends false finally for from function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined var void while with yield"
            if language == .typescript {
                list += " abstract any as boolean declare enum implements interface keyof namespace never number private protected public readonly string type unknown satisfies"
            }
            return [
                group(.comment, cComment),
                group(.string, #"`(?:[^`\\]|\\.)*`|"# + dqString + "|" + sqString),
                group(.attribute, #"@[A-Za-z_]\w*"#),
                group(.control, words(controlWords)),
                group(.keyword, words(list)),
                group(.function, functionCall),
                group(.type, pascalType),
                group(.number, number),
                group(.variable, variable),
            ].joined(separator: "|")
        case .java, .kotlin, .go:
            let list: String
            switch language {
            case .java: list = "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for if implements import instanceof int interface long native new null package private protected public return short static super switch synchronized this throw throws transient true false try var void volatile while record sealed permits yield"
            case .kotlin: list = "as break class continue do else false for fun if in interface is null object package return super this throw true try typealias val var when while by companion data enum import internal open override private protected public sealed suspend lateinit inline"
            default: list = "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota"
            }
            return [
                group(.comment, cComment),
                group(.string, #"`[^`]*`|"# + dqString + "|" + sqString),
                group(.attribute, #"@[A-Za-z_]\w*"#),
                group(.control, words(controlWords)),
                group(.keyword, words(list)),
                group(.function, functionCall),
                group(.type, pascalType),
                group(.number, number),
                group(.variable, variable),
            ].joined(separator: "|")
        case .json:
            return [
                group(.key, #""(?:[^"\\]|\\.)*"(?=\s*:)"#),
                group(.string, #""(?:[^"\\]|\\.)*""#),
                group(.keyword, words("true false null")),
                group(.number, #"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#),
                group(.comment, cComment),
            ].joined(separator: "|")
        case .xml, .html:
            return [
                group(.comment, #"<!--[\s\S]*?-->"#),
                group(.preprocessor, #"<\?[\s\S]*?\?>|<!DOCTYPE[^>]*>|<!\[CDATA\[[\s\S]*?\]\]>"#),
                group(.tag, #"</?[A-Za-z][\w:.-]*|/?>"#),
                group(.attrName, #"\b[A-Za-z_:@][\w:.-]*(?=\s*=)"#),
                group(.string, #""[^"]*"|'[^']*'"#),
            ].joined(separator: "|")
        case .yaml:
            return [
                group(.comment, #"#[^\n]*"#),
                group(.key, #"^[ \t]*(?:-[ \t]+)?[\w.\-/"' ]+?(?=:(?:\s|$))"#),
                group(.string, dqString + "|" + sqString),
                group(.keyword, words("true false null yes no on off") + "|~"),
                group(.preprocessor, #"^---$|^\.\.\.$|[&*][\w-]+|!![\w]+"#),
                group(.number, #"(?<=[:\-\s])-?\d+(?:\.\d+)?\b"#),
            ].joined(separator: "|")
        case .markdown:
            return [
                group(.code, #"```[\s\S]*?```|`[^`\n]+`"#),
                group(.heading, #"^#{1,6}[ \t][^\n]*"#),
                group(.comment, #"^>[^\n]*|<!--[\s\S]*?-->"#),
                group(.link, #"!?\[[^\]\n]*\]\([^)\n]*\)"#),
                group(.emphasis, #"\*\*[^*\n]+\*\*|__[^_\n]+__"#),
                group(.keyword, #"^[ \t]*(?:[-*+]|\d+\.)(?=[ \t])"#),
            ].joined(separator: "|")
        case .python:
            let keywords = words("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return self True try while with yield match case")
            return [
                group(.comment, #"#[^\n]*"#),
                group(.string, #"[rbfuRBFU]{0,2}(?:"""[\s\S]*?"""|'''[\s\S]*?'''|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')"#),
                group(.attribute, #"^[ \t]*@[\w.]+"#),
                group(.control, words(controlWords)),
                group(.keyword, keywords),
                group(.function, functionCall),
                group(.type, pascalType),
                group(.number, number),
                group(.variable, variable),
            ].joined(separator: "|")
        case .sql:
            let keywords = words("select from where and or not in is null like between join inner left right outer full on as group by order having limit offset insert into values update set delete create table alter drop index view primary key foreign references unique default distinct union all case when then else end exists count sum avg min max with returning top asc desc begin commit rollback transaction declare exec procedure function trigger")
            return [
                group(.comment, #"--[^\n]*|/\*[\s\S]*?\*/"#),
                group(.string, #"'(?:[^']|'')*'"#),
                group(.keyword, keywords),
                group(.number, #"\b\d+(?:\.\d+)?\b"#),
            ].joined(separator: "|")
        case .shell, .dockerfile:
            var list = "if then else elif fi for while until do done case esac in function return export local readonly set unset echo exit source alias"
            if language == .dockerfile {
                list += " FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS"
            }
            return [
                group(.comment, #"#[^\n]*"#),
                group(.string, dqString + "|" + sqString),
                group(.attribute, #"\$\{[^}\n]*\}|\$[A-Za-z_]\w*|\$[0-9@#?*!$-]"#),
                group(.control, words("if then else elif fi for while until do done case esac in return")),
                group(.keyword, words(list)),
                group(.number, #"\b\d+\b"#),
            ].joined(separator: "|")
        case .css:
            return [
                group(.comment, #"/\*[\s\S]*?\*/|//[^\n]*"#),
                group(.string, dqString + "|" + sqString),
                group(.preprocessor, #"@[\w-]+"#),
                group(.key, #"[\w-]+(?=\s*:[^{]*;)"#),
                group(.number, #"#[0-9a-fA-F]{3,8}\b|-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr)?\b"#),
                group(.type, #"[.#][A-Za-z_][\w-]*"#),
            ].joined(separator: "|")
        case .plain:
            return nil
        }
    }
}
