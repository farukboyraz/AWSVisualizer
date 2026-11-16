import SwiftUI
import AppKit

// Secret value display + editing, modelled on how other secret managers do
// it: the AWS console shows a revealed secret as a "Key/value" table or as
// "Plaintext" and edits it the same two ways; HashiCorp Vault's UI does
// Key/value ⇄ JSON with values masked until an eye icon is clicked. This
// adds JSON / XML views for structured values on top.

/// What a secret string turned out to contain.
enum SecretFormat: Equatable {
    /// A JSON object - the shape the console's Key/value tab reads/writes.
    case jsonObject
    /// Valid JSON, but not an object (array, string, number, ...).
    case json
    case xml
    case plain

    static func detect(_ text: String) -> SecretFormat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            // A bare word like `hunter2` isn't JSON, but `"hunter2"` or `42`
            // is - only treat it as JSON when it looks structured.
            if parsed is [String: Any] { return .jsonObject }
            if parsed is [Any] { return .json }
        }
        if trimmed.hasPrefix("<"), (try? XMLDocument(xmlString: trimmed, options: [])) != nil {
            return .xml
        }
        return .plain
    }
}

enum SecretViewMode: String, CaseIterable, Identifiable {
    case keyValue = "Key/value"
    case json = "JSON"
    case xml = "XML"
    case plaintext = "Plaintext"

    var id: String { rawValue }

    static func available(for format: SecretFormat) -> [SecretViewMode] {
        switch format {
        case .jsonObject: return [.keyValue, .json, .plaintext]
        case .json: return [.json, .plaintext]
        case .xml: return [.xml, .plaintext]
        case .plain: return [.plaintext]
        }
    }
}

/// JSON type of a key/value row's value, so editing as Key/value doesn't
/// turn `"port": 5432` into `"port": "5432"` or `true` into `"true"`.
enum SecretValueKind {
    case string, number, bool, null, nested
}

/// One Key/value row - a reference type so rows can be removed without
/// index-based bindings (an index binding into a list that shrinks crashes,
/// as the Filter Builder once did).
@Observable
final class SecretKVRow: Identifiable {
    let id = UUID()
    var key: String
    var value: String
    var kind: SecretValueKind

    init(key: String = "", value: String = "", kind: SecretValueKind = .string) {
        self.key = key
        self.value = value
        self.kind = kind
    }

    /// Value as JSON. A row that was a number/bool/null/object keeps that
    /// type while its text still parses as one; anything else is a string.
    var jsonNode: OrderedJSON {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .number where Double(trimmed) != nil: return .number(trimmed)
        case .bool where trimmed == "true" || trimmed == "false": return .bool(trimmed == "true")
        case .null where trimmed == "null": return .null
        case .nested:
            if let data = value.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                return OrderedJSON.from(any)
            }
            return .string(value)
        default: return .string(value)
        }
    }
}

enum SecretKV {
    /// Rows of a JSON-object secret, in the order the keys appear in the text.
    static func rows(from text: String) -> [SecretKVRow] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        // JSONSerialization drops key order - recover it from where each
        // key first appears in the original text (secrets are usually
        // written username-then-password; alphabetical would reshuffle).
        let ordered = object.keys.sorted { a, b in
            position(of: a, in: text) < position(of: b, in: text)
        }
        return ordered.map { key in
            let any = object[key]!
            if any is NSNull { return SecretKVRow(key: key, value: "null", kind: .null) }
            if let n = any as? NSNumber {
                return n.isBool ? SecretKVRow(key: key, value: n.boolValue ? "true" : "false", kind: .bool)
                                : SecretKVRow(key: key, value: n.stringValue, kind: .number)
            }
            if let s = any as? String { return SecretKVRow(key: key, value: s, kind: .string) }
            return SecretKVRow(key: key, value: OrderedJSON.from(any).compact(), kind: .nested)
        }
    }

    private static func position(of key: String, in text: String) -> Int {
        let quoted = OrderedJSON.string(key).compact()
        guard let range = text.range(of: quoted) else { return Int.max }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    /// Compact JSON object, keys in row order - same shape the console's
    /// Key/value editor writes.
    static func serialize(_ rows: [SecretKVRow]) throws -> String {
        var seen = Set<String>()
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw DdbValueError(message: "Every row needs a key") }
            guard seen.insert(key).inserted else { throw DdbValueError(message: "Key \"\(key)\" is used twice") }
        }
        return OrderedJSON.object(rows.map { ($0.key.trimmingCharacters(in: .whitespaces), $0.jsonNode) }).compact()
    }
}

extension OrderedJSON {
    /// From a `JSONSerialization` value (object keys sorted - only used for
    /// nested values, where the original order isn't recoverable anyway).
    static func from(_ any: Any) -> OrderedJSON {
        if any is NSNull { return .null }
        if let n = any as? NSNumber { return n.isBool ? .bool(n.boolValue) : .number(n.stringValue) }
        if let s = any as? String { return .string(s) }
        if let a = any as? [Any] { return .array(a.map(from)) }
        if let d = any as? [String: Any] { return .object(d.keys.sorted().map { ($0, from(d[$0]!)) }) }
        return .string(String(describing: any))
    }

    /// Single-line JSON.
    func compact() -> String {
        switch self {
        case .object(let members):
            return "{" + members.map { "\(OrderedJSON.string($0.0).compact()):\($0.1.compact())" }.joined(separator: ",") + "}"
        case .array(let elements):
            return "[" + elements.map { $0.compact() }.joined(separator: ",") + "]"
        case .string(let s):
            let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
            return String((String(data: data, encoding: .utf8) ?? "[\"\"]").dropFirst().dropLast())
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }
}

// MARK: - Display

/// A revealed secret: format-aware views (Key/value with per-row masking,
/// JSON, XML, Plaintext), copy, and an Edit mode that saves a new version.
struct SecretValuePanel: View {
    let secretString: String
    /// Saves a new version; returns the stored string. Nil = read-only.
    var save: ((String) async throws -> String)?
    var onHide: () -> Void

    @State private var current = ""
    @State private var mode: SecretViewMode = .plaintext
    @State private var revealedKeys: Set<String> = []
    @State private var showAllValues = false
    @State private var copiedKey: String?
    @State private var isEditing = false

    private var format: SecretFormat { SecretFormat.detect(current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isEditing, let save {
                SecretValueEditor(initialText: current, originalFormat: format, saveTitle: "Save New Version", onCancel: { isEditing = false }) { newText in
                    current = try await save(newText)
                    isEditing = false
                    mode = SecretViewMode.available(for: SecretFormat.detect(current)).first ?? .plaintext
                }
            } else {
                HStack(spacing: 10) {
                    let modes = SecretViewMode.available(for: format)
                    if modes.count > 1 {
                        TabBar(tabs: modes, selection: $mode, style: .pills, title: { $0.rawValue })
                    }
                    Text(formatLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    SecondaryButton(copiedKey == "*" ? "Copied" : "Copy", systemImage: copiedKey == "*" ? "checkmark" : "doc.on.doc") {
                        copy(current, key: "*")
                    }
                    if save != nil {
                        EditButton("Edit") { isEditing = true }
                    }
                    SecondaryButton("Hide", systemImage: "eye.slash", action: onHide)
                }

                content
            }
        }
        .onAppear {
            current = secretString
            mode = SecretViewMode.available(for: format).first ?? .plaintext
        }
    }

    private var formatLabel: String {
        switch format {
        case .jsonObject: return "JSON object · \(SecretKV.rows(from: current).count) keys"
        case .json: return "JSON"
        case .xml: return "XML"
        case .plain: return "Plain text"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .keyValue:
            keyValueTable
        case .json:
            StructuredContentView(text: current, kind: .json)
                .frame(minHeight: 220, maxHeight: 420)
        case .xml:
            StructuredContentView(text: current, kind: .xml)
                .frame(minHeight: 220, maxHeight: 420)
        case .plaintext:
            ScrollView([.horizontal, .vertical]) {
                Text(current)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: 320)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var keyValueTable: some View {
        let rows = SecretKV.rows(from: current)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Secret key").frame(width: 200, alignment: .leading)
                Text("Secret value")
                Spacer()
                Toggle("Show values", isOn: $showAllValues)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            Divider()
            ForEach(rows) { row in
                let visible = showAllValues || revealedKeys.contains(row.key)
                HStack(spacing: 8) {
                    Text(row.key)
                        .font(.caption.monospaced().bold())
                        .textSelection(.enabled)
                        .frame(width: 200, alignment: .leading)
                    Text(visible ? row.value : String(repeating: "•", count: 12))
                        .font(.caption.monospaced())
                        .foregroundStyle(visible ? Color.primary : Color.secondary)
                        .textSelection(.enabled)
                        .lineLimit(visible ? nil : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if row.kind != .string {
                        Text(kindLabel(row.kind)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button {
                        if revealedKeys.contains(row.key) { revealedKeys.remove(row.key) } else { revealedKeys.insert(row.key) }
                    } label: {
                        Image(systemName: visible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .disabled(showAllValues)
                    .help(visible ? "Hide value" : "Show value")
                    Button {
                        copy(row.value, key: row.key)
                    } label: {
                        Image(systemName: copiedKey == row.key ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy value")
                }
                .padding(.vertical, 5)
                Divider()
            }
        }
        .padding(.horizontal, 8)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func kindLabel(_ kind: SecretValueKind) -> String {
        switch kind {
        case .string: return ""
        case .number: return "number"
        case .bool: return "boolean"
        case .null: return "null"
        case .nested: return "JSON"
        }
    }

    private func copy(_ text: String, key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedKey = key
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedKey == key { copiedKey = nil }
        }
    }
}

// MARK: - Editing

/// Key/value ⇄ Plaintext editor - the console's two "Edit secret value"
/// tabs. Used for editing an existing secret (saves a new version) and for
/// the New Secret sheet. Switching tabs carries the content over; Key/value
/// is only offered while the text is a JSON object (or empty).
struct SecretValueEditor: View {
    let initialText: String
    let originalFormat: SecretFormat
    var saveTitle: String = "Save"
    /// Hide the editor's own Save/Cancel row (the New Secret sheet drives saving itself via `onChange`).
    var embedded = false
    var onCancel: (() -> Void)?
    /// Embedded mode: reports the serialized value (nil while invalid) on every change.
    var onChange: ((String?) -> Void)?
    var onSave: ((String) async throws -> Void)?

    private enum EditMode: String, CaseIterable, Identifiable {
        case keyValue = "Key/value"
        case plaintext = "Plaintext"
        var id: String { rawValue }
    }

    @State private var editMode: EditMode = .plaintext
    @State private var rows: [SecretKVRow] = []
    @State private var plaintext = ""
    @State private var switchError: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showConfirm = false

    init(initialText: String, originalFormat: SecretFormat, saveTitle: String = "Save", embedded: Bool = false,
         onCancel: (() -> Void)? = nil, onChange: ((String?) -> Void)? = nil, onSave: ((String) async throws -> Void)? = nil) {
        self.initialText = initialText
        self.originalFormat = originalFormat
        self.saveTitle = saveTitle
        self.embedded = embedded
        self.onCancel = onCancel
        self.onChange = onChange
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabBar(tabs: EditMode.allCases, selection: Binding(get: { editMode }, set: { switchMode($0) }), style: .pills, title: { $0.rawValue })

            if let switchError {
                Text(switchError).font(.caption).foregroundStyle(.red)
            }

            switch editMode {
            case .keyValue: keyValueEditor
            case .plaintext:
                CodeTextEditor(text: $plaintext)
                    .frame(minHeight: 140, maxHeight: 300)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            }

            if let problem = validationError {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if let warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }

            if !embedded {
                HStack {
                    if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
                    Spacer()
                    if let onCancel { SecondaryButton("Cancel", action: onCancel) }
                    SaveButton(saveTitle, isLoading: isSaving, isDisabled: validationError != nil) {
                        showConfirm = true
                    }
                }
                .confirmationDialog("Save a new version of this secret?", isPresented: $showConfirm, titleVisibility: .visible) {
                    Button("Save New Version") { Task { await runSave() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Applications reading this secret get the new value from now on. The current value stays available as the AWSPREVIOUS version.")
                }
            }
        }
        .onAppear {
            plaintext = initialText
            let canKV = originalFormat == .jsonObject || initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if canKV {
                rows = SecretKV.rows(from: initialText)
                if rows.isEmpty { rows = [SecretKVRow()] }
                editMode = .keyValue
            } else {
                editMode = .plaintext
            }
            report()
        }
        .onChange(of: plaintext) { _, _ in report() }
    }

    private var keyValueEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Key").frame(width: 200, alignment: .leading)
                Text("Value")
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            ForEach(rows) { row in
                SecretKVEditorRow(row: row, onRemove: {
                    rows.removeAll { $0.id == row.id }
                    report()
                }, onEdit: report)
            }
            Button {
                rows.append(SecretKVRow())
                report()
            } label: {
                Label("Add row", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    /// Serialized value for the active tab, or the reason it can't be saved.
    private func serialized() throws -> String {
        switch editMode {
        case .keyValue:
            guard !rows.isEmpty else { throw DdbValueError(message: "Add at least one key/value pair") }
            return try SecretKV.serialize(rows)
        case .plaintext:
            guard !plaintext.isEmpty else { throw DdbValueError(message: "The secret value can't be empty") }
            return plaintext
        }
    }

    private var validationError: String? {
        do { _ = try serialized(); return nil } catch { return error.localizedDescription }
    }

    /// The secret used to be structured but the new plaintext no longer
    /// parses as that - allowed, but worth a heads-up since whatever reads
    /// this secret probably parses it.
    private var warning: String? {
        guard editMode == .plaintext, !plaintext.isEmpty else { return nil }
        let now = SecretFormat.detect(plaintext)
        let wasJSON = originalFormat == .jsonObject || originalFormat == .json
        if wasJSON && now != .jsonObject && now != .json {
            return "This secret was JSON and the new value isn't valid JSON - applications that parse it may break."
        }
        if originalFormat == .xml && now != .xml {
            return "This secret was XML and the new value isn't well-formed XML."
        }
        return nil
    }

    private func switchMode(_ newMode: EditMode) {
        guard newMode != editMode else { return }
        switchError = nil
        switch newMode {
        case .plaintext:
            if let text = try? SecretKV.serialize(rows) {
                plaintext = prettyIfJSON(text)
            }
        case .keyValue:
            let trimmed = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                rows = [SecretKVRow()]
            } else if SecretFormat.detect(trimmed) == .jsonObject {
                rows = SecretKV.rows(from: trimmed)
            } else {
                switchError = "Key/value needs the value to be a JSON object like {\"username\": \"...\"}."
                return
            }
        }
        editMode = newMode
        report()
    }

    private func prettyIfJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8) else { return text }
        // Pretty-printing would lose key order; keep the compact form when
        // the order differs from what the rows had.
        return (try? SecretKV.serialize(SecretKV.rows(from: string))) == text ? string : text
    }

    private func report() {
        onChange?(try? serialized())
    }

    private func runSave() async {
        guard let onSave, let value = try? serialized() else { return }
        isSaving = true
        saveError = nil
        do {
            try await onSave(value)
        } catch {
            saveError = error.friendlyMessage
        }
        isSaving = false
    }
}

private struct SecretKVEditorRow: View {
    @Bindable var row: SecretKVRow
    var onRemove: () -> Void
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("key", text: $row.key)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .frame(width: 200)
            TextField("value", text: $row.value, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .lineLimit(1...4)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove row")
        }
        .onChange(of: row.key) { _, _ in onEdit() }
        .onChange(of: row.value) { _, _ in onEdit() }
    }
}
