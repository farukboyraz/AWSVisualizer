import AppKit

/// Builds NSAttributedString directly with NSColor, never through SwiftUI's
/// Color/AttributedString bridging. That bridging resolves semantic colors
/// (.primary, .secondary) at conversion time rather than at draw time, and
/// this runs inside a detached background Task - off the main thread, with
/// no window/appearance context - so it was silently baking in light-mode
/// black instead of tracking the current NSAppearance. NSColor.labelColor
/// et al. are true dynamic colors that AppKit re-resolves whenever the text
/// view actually draws, regardless of which thread created them.
enum SyntaxHighlighter {
    private static let keyColor = NSColor(red: 0.45, green: 0.62, blue: 1.0, alpha: 1)
    private static let stringColor = NSColor(red: 0.45, green: 0.8, blue: 0.5, alpha: 1)
    private static let numberColor = NSColor(red: 0.95, green: 0.65, blue: 0.3, alpha: 1)
    private static let keywordColor = NSColor(red: 0.75, green: 0.55, blue: 0.95, alpha: 1)
    private static let commentColor = NSColor.secondaryLabelColor

    static func highlightJSON(_ text: String) -> NSAttributedString {
        let pattern = #"(?<key>"(?:[^"\\]|\\.)*"(?=\s*:))|(?<string>"(?:[^"\\]|\\.)*")|(?<number>-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|(?<bool>\btrue\b|\bfalse\b|\bnull\b)"#
        return highlight(text, pattern: pattern) { match in
            if match.range(withName: "key").location != NSNotFound { return keyColor }
            if match.range(withName: "string").location != NSNotFound { return stringColor }
            if match.range(withName: "number").location != NSNotFound { return numberColor }
            return keywordColor
        }
    }

    static func highlightXML(_ text: String) -> NSAttributedString {
        let pattern = #"(?<comment><!--[\s\S]*?-->)|(?<tag></?[a-zA-Z][a-zA-Z0-9_:.-]*)|(?<attr>[a-zA-Z_:][a-zA-Z0-9_:.-]*(?=\s*=))|(?<value>"[^"]*")"#
        return highlight(text, pattern: pattern) { match in
            if match.range(withName: "comment").location != NSNotFound { return commentColor }
            if match.range(withName: "tag").location != NSNotFound { return keyColor }
            if match.range(withName: "attr").location != NSNotFound { return numberColor }
            return stringColor
        }
    }

    private static func highlight(
        _ text: String,
        pattern: String,
        color: (NSTextCheckingResult) -> NSColor
    ) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributed }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)

        regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
            guard let match else { return }
            attributed.addAttribute(.foregroundColor, value: color(match), range: match.range)
        }

        return attributed
    }
}
