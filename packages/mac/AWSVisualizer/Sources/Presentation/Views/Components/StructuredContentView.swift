import SwiftUI
import Foundation
import AppKit

enum StructuredKind {
    case json
    case xml
    case plain

    static func classify(path: String, contentType: String? = nil) -> StructuredKind {
        let lower = path.lowercased()
        if lower.hasSuffix(".json") || (contentType?.contains("json") ?? false) {
            return .json
        }
        if lower.hasSuffix(".xml") || (contentType?.contains("xml") ?? false) {
            return .xml
        }
        return .plain
    }
}

private struct ProcessedJSON: @unchecked Sendable {
    let formatted: NSAttributedString
    let tree: JSONValue?
}

private struct ProcessedXML: @unchecked Sendable {
    let formatted: NSAttributedString
    let tree: XMLElement?
}

private struct SendableAttributedString: @unchecked Sendable {
    let value: NSAttributedString
}

struct StructuredContentView: View {
    let text: String
    let kind: StructuredKind

    private enum ViewMode: String, CaseIterable {
        case formatted = "Formatted"
        case tree = "Tree"
    }

    @State private var mode: ViewMode = .formatted
    @State private var processedJSON: ProcessedJSON?
    @State private var processedXML: ProcessedXML?
    @State private var plainFormatted: NSAttributedString?
    @State private var isProcessing = false

    var body: some View {
        VStack(spacing: 0) {
            if kind != .plain {
                HStack {
                    TabBar(selection: $mode, style: .pills)
                    Spacer()
                }
                .padding(8)
                Divider()
            }
            Group {
                if isProcessing {
                    BrandedLoader(message: "Formatting…")
                        .frame(height: 200)
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: text) {
            await process()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .plain:
            if let plainFormatted {
                SelectableTextView(attributedString: plainFormatted)
            }
        case .json:
            jsonContent
        case .xml:
            xmlContent
        }
    }

    @ViewBuilder
    private var jsonContent: some View {
        if let processedJSON {
            switch mode {
            case .formatted:
                SelectableTextView(attributedString: processedJSON.formatted)
            case .tree:
                if let tree = processedJSON.tree {
                    // Both directions - deep trees / long values scroll sideways.
                    ScrollView([.vertical, .horizontal]) {
                        JSONTreeView(value: tree, key: nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else {
                    Text("Could not parse this as JSON")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var xmlContent: some View {
        if let processedXML {
            switch mode {
            case .formatted:
                SelectableTextView(attributedString: processedXML.formatted)
            case .tree:
                if let tree = processedXML.tree {
                    ScrollView([.vertical, .horizontal]) {
                        XMLTreeView(element: tree)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else {
                    Text("Could not parse this as XML")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func process() async {
        isProcessing = true
        processedJSON = nil
        processedXML = nil
        plainFormatted = nil

        let capturedText = text

        switch kind {
        case .json:
            let result = await Task.detached(priority: .userInitiated) { () -> ProcessedJSON in
                let parsed = JSONValue.parse(capturedText)
                let formatted = SyntaxHighlighter.highlightJSON(parsed?.prettyPrinted() ?? capturedText)
                return ProcessedJSON(formatted: formatted, tree: parsed)
            }.value
            guard !Task.isCancelled else { return }
            processedJSON = result
        case .xml:
            let result = await Task.detached(priority: .userInitiated) { () -> ProcessedXML in
                let pretty = XMLFormatter.prettyPrint(capturedText) ?? capturedText
                let formatted = SyntaxHighlighter.highlightXML(pretty)
                let tree = XMLFormatter.parseTree(capturedText)
                return ProcessedXML(formatted: formatted, tree: tree)
            }.value
            guard !Task.isCancelled else { return }
            processedXML = result
        case .plain:
            let result = await Task.detached(priority: .userInitiated) { () -> SendableAttributedString in
                SendableAttributedString(value: NSAttributedString(
                    string: capturedText,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                        .foregroundColor: NSColor.labelColor,
                    ]
                ))
            }.value
            guard !Task.isCancelled else { return }
            plainFormatted = result.value
        }

        isProcessing = false
    }
}

// MARK: - JSON model, order-preserving parser and pretty-printer

indirect enum JSONValue {
    case string(String)
    case number(String)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    static func parse(_ text: String) -> JSONValue? {
        var parser = JSONValueParser(text)
        return parser.parseTopLevel()
    }

    func prettyPrinted(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let childPad = String(repeating: "  ", count: indent + 1)
        switch self {
        case .string(let s):
            return "\"\(JSONValue.escape(s))\""
        case .number(let n):
            return n
        case .bool(let b):
            return b ? "true" : "false"
        case .null:
            return "null"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let body = items.map { childPad + $0.prettyPrinted(indent: indent + 1) }.joined(separator: ",\n")
            return "[\n\(body)\n\(pad)]"
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            let body = pairs
                .map { childPad + "\"\(JSONValue.escape($0.key))\": " + $0.value.prettyPrinted(indent: indent + 1) }
                .joined(separator: ",\n")
            return "{\n\(body)\n\(pad)}"
        }
    }

    private static func escape(_ s: String) -> String {
        var result = ""
        for c in s {
            switch c {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default: result.append(c)
            }
        }
        return result
    }
}

private struct JSONValueParser {
    private let chars: [Character]
    private var index = 0

    init(_ text: String) {
        chars = Array(text)
    }

    mutating func parseTopLevel() -> JSONValue? {
        skipWhitespace()
        return try? parseValue()
    }

    private mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard let c = peek() else { throw JSONParseError.invalid }
        switch c {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t", "f": return try parseBool()
        case "n": try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        index += 1
        var pairs: [(String, JSONValue)] = []
        skipWhitespace()
        if peek() == "}" { index += 1; return .object(pairs) }
        while true {
            skipWhitespace()
            let key = try parseString()
            skipWhitespace()
            guard peek() == ":" else { throw JSONParseError.invalid }
            index += 1
            let value = try parseValue()
            pairs.append((key, value))
            skipWhitespace()
            if peek() == "," { index += 1; continue }
            if peek() == "}" { index += 1; break }
            throw JSONParseError.invalid
        }
        return .object(pairs)
    }

    private mutating func parseArray() throws -> JSONValue {
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if peek() == "]" { index += 1; return .array(items) }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            if peek() == "," { index += 1; continue }
            if peek() == "]" { index += 1; break }
            throw JSONParseError.invalid
        }
        return .array(items)
    }

    private mutating func parseString() throws -> String {
        guard peek() == "\"" else { throw JSONParseError.invalid }
        index += 1
        var result = ""
        while index < chars.count {
            let c = chars[index]
            if c == "\"" { index += 1; return result }
            if c == "\\" {
                index += 1
                guard index < chars.count else { throw JSONParseError.invalid }
                switch chars[index] {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "b": result.append("\u{8}")
                case "f": result.append("\u{c}")
                case "u":
                    let hexStart = index + 1
                    guard hexStart + 4 <= chars.count else { throw JSONParseError.invalid }
                    let hex = String(chars[hexStart..<hexStart + 4])
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        result.append(Character(scalar))
                    }
                    index += 4
                default: break
                }
                index += 1
            } else {
                result.append(c)
                index += 1
            }
        }
        throw JSONParseError.invalid
    }

    private mutating func parseBool() throws -> JSONValue {
        if peek() == "t" { try expect("true"); return .bool(true) }
        try expect("false")
        return .bool(false)
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        while index < chars.count, "0123456789+-.eE".contains(chars[index]) {
            index += 1
        }
        guard index > start else { throw JSONParseError.invalid }
        return .number(String(chars[start..<index]))
    }

    private mutating func expect(_ literal: String) throws {
        for ch in literal {
            guard index < chars.count, chars[index] == ch else { throw JSONParseError.invalid }
            index += 1
        }
    }

    private func peek() -> Character? {
        index < chars.count ? chars[index] : nil
    }

    private mutating func skipWhitespace() {
        while index < chars.count, chars[index].isWhitespace {
            index += 1
        }
    }
}

private enum JSONParseError: Error {
    case invalid
}

struct JSONTreeView: View {
    let value: JSONValue
    let key: String?

    @State private var isExpanded = true

    var body: some View {
        switch value {
        case .object(let pairs):
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    JSONTreeView(value: pair.value, key: pair.key)
                }
            } label: {
                header(summary: "{ \(pairs.count) }")
            }
        case .array(let items):
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    JSONTreeView(value: item, key: "[\(index)]")
                }
            } label: {
                header(summary: "[ \(items.count) ]")
            }
        default:
            HStack(spacing: 4) {
                keyLabel
                leafValue
            }
        }
    }

    private func header(summary: String) -> some View {
        HStack(spacing: 4) {
            keyLabel
            Text(summary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var keyLabel: some View {
        if let key {
            Text(key + ":")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(.blue)
        }
    }

    @ViewBuilder
    private var leafValue: some View {
        switch value {
        case .string(let s):
            Text("\"\(s)\"")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.green)
        case .number(let n):
            Text(n)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.orange)
        case .bool(let b):
            Text(b ? "true" : "false")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.purple)
        case .null:
            Text("null")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        case .array, .object:
            EmptyView()
        }
    }
}

// MARK: - XML pretty-printing and tree, backed by Foundation's XMLDocument

enum XMLFormatter {
    static func prettyPrint(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let doc = try? XMLDocument(data: data, options: [.nodePrettyPrint, .nodeCompactEmptyElement]) else { return nil }
        return doc.xmlString(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
    }

    static func parseTree(_ text: String) -> XMLElement? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let doc = try? XMLDocument(data: data, options: []) else { return nil }
        return doc.rootElement()
    }
}

struct XMLTreeView: View {
    let element: XMLElement

    @State private var isExpanded = true

    var body: some View {
        if childElements.isEmpty && directText == nil {
            headerLabel
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(Array(childElements.enumerated()), id: \.offset) { _, child in
                    XMLTreeView(element: child)
                }
                if let directText {
                    Text(directText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                }
            } label: {
                headerLabel
            }
        }
    }

    private var headerLabel: some View {
        HStack(spacing: 6) {
            Text("<\(element.name ?? "?")>")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(.blue)
            ForEach(Array(attributePairs.enumerated()), id: \.offset) { _, attr in
                Text("\(attr.0)=\"\(attr.1)\"")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var attributePairs: [(String, String)] {
        (element.attributes ?? []).map { ($0.name ?? "", $0.stringValue ?? "") }
    }

    private var childElements: [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }
    }

    private var directText: String? {
        let text = (element.children ?? [])
            .filter { $0.kind == .text }
            .compactMap { $0.stringValue }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
