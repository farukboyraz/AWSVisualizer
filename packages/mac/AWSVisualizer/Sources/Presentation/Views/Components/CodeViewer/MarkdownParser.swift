import Foundation

/// Block structure of a Markdown document - GitHub-flavored where it
/// matters for READMEs: ATX + setext headings, paragraphs with hard
/// breaks, nested ordered/unordered/task lists, block quotes (containing
/// blocks), fenced code with a language, GFM tables, rules, images.
/// Inline syntax (emphasis, code spans, links) is left in the text and
/// rendered by `MarkdownView` via `AttributedString(markdown:)`.
/// Foundation-only, so it can be unit-tested without SwiftUI.
indirect enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case quote([MarkdownBlock])
    case code(language: String, code: String)
    case table(header: [String], alignments: [MarkdownAlignment], rows: [[String]])
    case image(alt: String, url: String)
    case rule
}

struct MarkdownListItem: Equatable {
    var text: String
    /// nil = plain item; true/false = task list `[x]` / `[ ]`.
    var checked: Bool?
    var children: [MarkdownBlock]
}

enum MarkdownAlignment: Equatable {
    case leading, center, trailing
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let cleaned = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        return parseBlocks(cleaned.components(separatedBy: "\n"))
    }

    // MARK: - Blocks

    private static func parseBlocks(_ lines: [String]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = joinParagraph(paragraph)
            paragraph = []
            if let image = standaloneImage(text) {
                blocks.append(image)
            } else {
                blocks.append(.paragraph(text))
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if let fence = fenceMarker(trimmed) {
                flushParagraph()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: language.components(separatedBy: " ").first ?? "", code: code.joined(separator: "\n")))
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Setext heading: a paragraph line followed by === or ---
            if !paragraph.isEmpty, isSetextUnderline(trimmed) {
                let text = joinParagraph(paragraph)
                paragraph = []
                blocks.append(.heading(level: trimmed.hasPrefix("=") ? 1 : 2, text: text))
                i += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            if let heading = atxHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                i += 1
                continue
            }

            // Block quote: collect consecutive ">" lines (plus lazy continuations)
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var content = String(t.dropFirst())
                        if content.hasPrefix(" ") { content.removeFirst() }
                        inner.append(content)
                    } else if !t.isEmpty, !inner.isEmpty, inner.last?.isEmpty == false {
                        inner.append(t)
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.quote(parseBlocks(inner)))
                continue
            }

            // GFM table: header row + delimiter row
            if line.contains("|"), i + 1 < lines.count, let alignments = tableDelimiter(lines[i + 1]) {
                flushParagraph()
                let header = tableCells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    var cells = tableCells(lines[i])
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(header.count)))
                    i += 1
                }
                let aligned = alignments.count >= header.count ? Array(alignments.prefix(header.count)) : alignments + Array(repeating: .leading, count: header.count - alignments.count)
                blocks.append(.table(header: header, alignments: aligned, rows: rows))
                continue
            }

            // List
            if let firstMarker = listMarker(line) {
                flushParagraph()
                var listLines: [String] = []
                /// A marker at this list's own level but of the other kind
                /// (bullet vs number) starts a new list, as on GitHub.
                func startsOtherList(_ l: String) -> Bool {
                    guard let m = listMarker(l), m.indent <= firstMarker.indent + 1 else { return false }
                    return m.ordered != firstMarker.ordered
                }
                while i < lines.count {
                    let l = lines[i]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if !listLines.isEmpty, startsOtherList(l) { break }
                    if t.isEmpty {
                        // A blank line ends the list unless an indented or list line follows.
                        if i + 1 < lines.count, !startsOtherList(lines[i + 1]), listMarker(lines[i + 1]) != nil || leadingSpaces(lines[i + 1]) >= 2 {
                            listLines.append(l)
                            i += 1
                            continue
                        }
                        break
                    }
                    if listMarker(l) == nil, leadingSpaces(l) == 0, !listLines.isEmpty, fenceMarker(t) == nil {
                        // Lazy continuation of the previous item's text.
                        if listLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false {
                            listLines.append("  " + t)
                            i += 1
                            continue
                        }
                        break
                    }
                    listLines.append(l)
                    i += 1
                }
                blocks.append(parseList(listLines))
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Lists

    private struct Marker {
        let indent: Int
        let ordered: Bool
        let number: Int
        let contentOffset: Int
    }

    private static func listMarker(_ line: String) -> Marker? {
        let indent = leadingSpaces(line)
        let rest = line.drop(while: { $0 == " " || $0 == "\t" })
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            // "---" / "* * *" are rules, not lists
            if isRule(String(rest)) { return nil }
            return Marker(indent: indent, ordered: false, number: 0, contentOffset: indent + 2)
        }
        let digits = rest.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 9 {
            let after = rest.dropFirst(digits.count)
            if let punct = after.first, punct == "." || punct == ")", after.dropFirst().first == " " {
                return Marker(indent: indent, ordered: true, number: Int(digits) ?? 1, contentOffset: indent + digits.count + 2)
            }
        }
        return nil
    }

    /// Builds one list from its lines; deeper-indented markers become nested
    /// lists of the item above them, other indented lines continue it.
    private static func parseList(_ lines: [String]) -> MarkdownBlock {
        guard let first = lines.first, let firstMarker = listMarker(first) else { return .paragraph(lines.joined(separator: " ")) }
        var items: [MarkdownListItem] = []
        var currentText: [String] = []
        var childLines: [String] = []
        var currentChecked: Bool?

        func flush() {
            guard !currentText.isEmpty || !childLines.isEmpty else { return }
            let children = childLines.isEmpty ? [] : parseBlocks(dedent(childLines))
            items.append(MarkdownListItem(text: joinParagraph(currentText), checked: currentChecked, children: children))
            currentText = []
            childLines = []
            currentChecked = nil
        }

        for line in lines {
            if let marker = listMarker(line), marker.indent <= firstMarker.indent + 1 {
                flush()
                var content = String(line.dropFirst(min(marker.contentOffset, line.count)))
                if content.hasPrefix("[ ] ") || content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
                    currentChecked = content.hasPrefix("[ ]") == false
                    content = String(content.dropFirst(4))
                }
                currentText = [content]
            } else if childLines.isEmpty, listMarker(line) == nil, !line.trimmingCharacters(in: .whitespaces).isEmpty, !currentText.isEmpty, fenceMarker(line.trimmingCharacters(in: .whitespaces)) == nil {
                currentText.append(line.trimmingCharacters(in: .whitespaces))
            } else {
                childLines.append(line)
            }
        }
        flush()
        return .list(ordered: firstMarker.ordered, start: firstMarker.number, items: items)
    }

    private static func dedent(_ lines: [String]) -> [String] {
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(leadingSpaces)
        let minimum = indents.min() ?? 0
        return lines.map { line in
            var l = Substring(line)
            var removed = 0
            while removed < minimum, let c = l.first, c == " " || c == "\t" {
                l = l.dropFirst()
                removed += c == "\t" ? 4 : 1
            }
            return String(l)
        }
    }

    // MARK: - Helpers

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for c in line {
            if c == " " { count += 1 } else if c == "\t" { count += 4 } else { break }
        }
        return count
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isSetextUnderline(_ trimmed: String) -> Bool {
        guard trimmed.count >= 2 else { return false }
        return trimmed.allSatisfy { $0 == "=" } || trimmed.allSatisfy { $0 == "-" }
    }

    private static func atxHeading(_ trimmed: String) -> MarkdownBlock? {
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing #'s
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
    }

    /// Lines joined with spaces; "two trailing spaces" or a trailing
    /// backslash (and `<br>`) mean a hard line break.
    private static func joinParagraph(_ lines: [String]) -> String {
        var result = ""
        for (index, line) in lines.enumerated() {
            var l = line.trimmingCharacters(in: .whitespaces)
            let hardBreak = line.hasSuffix("  ") || l.hasSuffix("\\")
            if l.hasSuffix("\\") { l.removeLast() }
            result += l
            if index < lines.count - 1 { result += hardBreak ? "\n" : " " }
        }
        return result.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
    }

    private static func standaloneImage(_ text: String) -> MarkdownBlock? {
        let pattern = #"^!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let alt = Range(match.range(at: 1), in: text), let url = Range(match.range(at: 2), in: text) else { return nil }
        return .image(alt: String(text[alt]), url: String(text[url]))
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        // Split on unescaped pipes.
        var cells: [String] = []
        var current = ""
        var previous: Character?
        for c in t {
            if c == "|" && previous != "\\" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
            previous = c
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    private static func tableDelimiter(_ line: String) -> [MarkdownAlignment]? {
        let cells = tableCells(line)
        guard !cells.isEmpty, line.contains("-") else { return nil }
        var alignments: [MarkdownAlignment] = []
        for cell in cells {
            let c = cell.replacingOccurrences(of: " ", with: "")
            guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else { return nil }
            if c.hasPrefix(":") && c.hasSuffix(":") { alignments.append(.center) }
            else if c.hasSuffix(":") { alignments.append(.trailing) }
            else { alignments.append(.leading) }
        }
        return alignments
    }
}
