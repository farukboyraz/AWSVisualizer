import SwiftUI

/// One editable row of the attribute form - a reference type so nested
/// rows can be added/removed without index-based bindings (an index into
/// an array that just shrank is exactly what crashed the Filter Builder).
@Observable
final class DdbFormNode: Identifiable {
    let id = UUID()
    var name: String
    var type: DdbType
    /// S / N / B value, or one element of a set.
    var text: String
    var bool: Bool
    var children: [DdbFormNode]
    var isExpanded = true
    /// Key attributes: name and type fixed, can't be removed.
    let keyRole: String?

    init(name: String = "", type: DdbType = .S, text: String = "", bool: Bool = false, children: [DdbFormNode] = [], keyRole: String? = nil) {
        self.name = name
        self.type = type
        self.text = text
        self.bool = bool
        self.children = children
        self.keyRole = keyRole
    }

    static func from(_ value: DdbTypedValue, name: String, keyRole: String? = nil) -> DdbFormNode {
        switch value {
        case .s(let v): return DdbFormNode(name: name, type: .S, text: v, keyRole: keyRole)
        case .n(let v): return DdbFormNode(name: name, type: .N, text: v, keyRole: keyRole)
        case .b(let v): return DdbFormNode(name: name, type: .B, text: v, keyRole: keyRole)
        case .bool(let v): return DdbFormNode(name: name, type: .BOOL, bool: v, keyRole: keyRole)
        case .null: return DdbFormNode(name: name, type: .NULL, keyRole: keyRole)
        case .ss(let v): return DdbFormNode(name: name, type: .SS, children: v.map { DdbFormNode(type: .S, text: $0) }, keyRole: keyRole)
        case .ns(let v): return DdbFormNode(name: name, type: .NS, children: v.map { DdbFormNode(type: .N, text: $0) }, keyRole: keyRole)
        case .bs(let v): return DdbFormNode(name: name, type: .BS, children: v.map { DdbFormNode(type: .B, text: $0) }, keyRole: keyRole)
        case .l(let v): return DdbFormNode(name: name, type: .L, children: v.map { from($0, name: "") }, keyRole: keyRole)
        case .m(let v): return DdbFormNode(name: name, type: .M, children: v.map { from($0.value, name: $0.name) }, keyRole: keyRole)
        }
    }

    /// Switching a row's type keeps whatever still makes sense (text for
    /// scalar ↔ scalar, the elements for set ↔ list) and resets the rest.
    func changeType(to newType: DdbType) {
        guard newType != type else { return }
        let old = type
        type = newType
        if newType.isSet, let element = newType.setElementType {
            let texts = old.isContainer ? children.map(\.text) : (text.isEmpty ? [] : [text])
            children = texts.map { DdbFormNode(type: element, text: $0) }
            if children.isEmpty { children = [DdbFormNode(type: element)] }
        } else if newType == .L {
            children = old.isSet ? children.map { DdbFormNode(type: $0.type, text: $0.text) } : []
        } else if newType == .M {
            children = []
        } else {
            children = []
            if newType == .BOOL { bool = text.lowercased() == "true" }
        }
        isExpanded = true
    }

    /// Validates and converts back to a typed value; `path` names the row in errors.
    func typedValue(path: String) throws -> DdbTypedValue {
        func number(_ s: String, _ p: String) throws -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, Decimal(string: t) != nil, Double(t) != nil else { throw DdbValueError(message: "\(p): \"\(s)\" is not a number") }
            return t
        }
        func binary(_ s: String, _ p: String) throws -> String {
            guard Data(base64Encoded: s) != nil else { throw DdbValueError(message: "\(p): binary values must be base64") }
            return s
        }
        func setElements(_ convert: (String, String) throws -> String) throws -> [String] {
            let values = try children.enumerated().map { try convert($0.element.text, "\(path)[\($0.offset)]") }
            guard !values.isEmpty else { throw DdbValueError(message: "\(path): a set can't be empty - remove the attribute or add a value") }
            guard Set(values).count == values.count else { throw DdbValueError(message: "\(path): a set can't contain duplicate values") }
            return values
        }
        switch type {
        case .S: return .s(text)
        case .N: return .n(try number(text, path))
        case .B: return .b(try binary(text, path))
        case .BOOL: return .bool(bool)
        case .NULL: return .null
        case .SS: return .ss(try setElements { s, _ in s })
        case .NS: return .ns(try setElements(number))
        case .BS: return .bs(try setElements(binary))
        case .L: return .l(try children.enumerated().map { try $0.element.typedValue(path: "\(path)[\($0.offset)]") })
        case .M: return .m(try DdbFormNode.namedValues(children, path: path))
        }
    }

    static func namedValues(_ nodes: [DdbFormNode], path: String) throws -> [DdbNamedValue] {
        var seen = Set<String>()
        return try nodes.map { node in
            let name = node.name.trimmingCharacters(in: .whitespaces)
            let p = path.isEmpty ? (name.isEmpty ? "(unnamed attribute)" : name) : "\(path).\(name)"
            guard !name.isEmpty else { throw DdbValueError(message: "\(p): every attribute needs a name") }
            guard seen.insert(name).inserted else { throw DdbValueError(message: "\(p): attribute name used twice") }
            return DdbNamedValue(name: name, value: try node.typedValue(path: p))
        }
    }
}

/// Console-style attribute form: name / value / type / remove per row,
/// nested Map/List/set rows indented under an expander, "Add new attribute"
/// at the top. Read-only when `isEditable` is false.
struct DynamoItemForm: View {
    @Binding var roots: [DdbFormNode]
    let isEditable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Attributes").font(.headline)
                Spacer()
                if isEditable {
                    Menu {
                        ForEach(DdbType.allCases) { type in
                            Button(type.label) {
                                roots.append(newNode(type: type))
                            }
                        }
                    } label: {
                        Label("Add new attribute", systemImage: "plus")
                    }
                    .fixedSize()
                }
            }
            .padding(.bottom, 10)

            header
            Divider()
            ForEach(roots) { node in
                DynamoFormRow(node: node, depth: 0, parentType: .M, isEditable: isEditable, onRemove: {
                    roots.removeAll { $0.id == node.id }
                })
            }
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Attribute name").frame(width: DynamoFormRow.nameWidth + DynamoFormRow.expanderWidth, alignment: .leading)
            Text("Value").frame(minWidth: DynamoFormRow.valueWidth, maxWidth: .infinity, alignment: .leading)
            Text("Type").frame(width: DynamoFormRow.typeWidth, alignment: .leading)
            Text("Remove").frame(width: DynamoFormRow.removeWidth, alignment: .leading)
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }
}

/// A blank row of the given type (sets start with one empty element).
func newNode(type: DdbType) -> DdbFormNode {
    let node = DdbFormNode(name: "", type: .S)
    node.changeType(to: type)
    return node
}

private struct DynamoFormRow: View {
    @Bindable var node: DdbFormNode
    let depth: Int
    /// Type of the container this row sits in (`.M` for top level) -
    /// decides whether the row has its own name and type picker.
    let parentType: DdbType
    let isEditable: Bool
    var onRemove: () -> Void
    var index: Int? = nil

    static let expanderWidth: CGFloat = 22
    static let nameWidth: CGFloat = 220
    static let valueWidth: CGFloat = 360
    static let typeWidth: CGFloat = 120
    static let removeWidth: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 4) {
                    Color.clear.frame(width: CGFloat(depth) * 16)
                    if node.type.isContainer {
                        Button {
                            node.isExpanded.toggle()
                        } label: {
                            Image(systemName: node.isExpanded ? "minus.square" : "plus.square")
                        }
                        .buttonStyle(.borderless)
                        .frame(width: Self.expanderWidth)
                    } else {
                        Color.clear.frame(width: Self.expanderWidth)
                    }
                    nameCell
                }
                .frame(width: Self.nameWidth + Self.expanderWidth + CGFloat(depth) * 16, alignment: .leading)

                valueCell
                    .frame(minWidth: Self.valueWidth, maxWidth: .infinity, alignment: .leading)

                typeCell
                    .frame(width: Self.typeWidth, alignment: .leading)

                Group {
                    if isEditable && node.keyRole == nil {
                        SecondaryButton("Remove", systemImage: "minus.circle", action: onRemove)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: Self.removeWidth, height: 22, alignment: .leading)
            }
            .padding(.vertical, 6)
            Divider()

            if node.type.isContainer && node.isExpanded {
                ForEach(Array(node.children.enumerated()), id: \.element.id) { offset, child in
                    DynamoFormRow(node: child, depth: depth + 1, parentType: node.type, isEditable: isEditable, onRemove: {
                        node.children.removeAll { $0.id == child.id }
                    }, index: offset)
                }
            }
        }
    }

    @ViewBuilder
    private var nameCell: some View {
        if let keyRole = node.keyRole {
            HStack(spacing: 4) {
                Text(node.name).font(.body.bold())
                Text("- \(keyRole)").font(.caption.italic()).foregroundStyle(.secondary)
            }
        } else if parentType == .M {
            TextField("Attribute name", text: $node.name)
                .textFieldStyle(.roundedBorder)
        } else {
            // List and set elements are positional, not named.
            Text("[\(index ?? 0)]")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var valueCell: some View {
        switch node.type {
        case .S, .N, .B:
            TextField(node.type == .N ? "0" : node.type == .B ? "base64" : "", text: $node.text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .font(node.type == .S ? .body : .body.monospaced())
        case .BOOL:
            Picker("", selection: $node.bool) {
                Text("True").tag(true)
                Text("False").tag(false)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
        case .NULL:
            Text("null").font(.body.monospaced()).foregroundStyle(.secondary)
        case .M, .L, .SS, .NS, .BS:
            HStack(spacing: 10) {
                if isEditable {
                    NewButton("Insert a field") {
                        insertChild()
                    }
                    .controlSize(.small)
                }
                Text("\(node.children.count) \(node.type == .M ? "attribute" : "item")\(node.children.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var typeCell: some View {
        if node.keyRole != nil || parentType.isSet || !isEditable {
            Text(node.type.label)
        } else {
            Picker("", selection: Binding(get: { node.type }, set: { node.changeType(to: $0) })) {
                ForEach(DdbType.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
        }
    }

    private func insertChild() {
        if let element = node.type.setElementType {
            node.children.append(DdbFormNode(type: element))
        } else {
            node.children.append(DdbFormNode(type: .S))
        }
        node.isExpanded = true
    }
}
