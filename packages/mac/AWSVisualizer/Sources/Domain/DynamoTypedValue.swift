import Foundation

/// Which view DynamoDB's item popup opens in (Settings → DynamoDB → Item
/// view; persisted as `dynamoDbItemView` in ~/.awsvisualizer).
enum DynamoItemViewMode: String, CaseIterable, Identifiable {
    /// Plain JSON, like the grid (`{"ApiUrl": "https://..."}`).
    case json = "json"
    /// Typed DynamoDB JSON (`{"ApiUrl": {"S": "https://..."}}`).
    case dynamoDbJson = "dynamodb-json"
    /// Console-style attribute form.
    case form = "form"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .json: return "JSON"
        case .dynamoDbJson: return "DynamoDB JSON"
        case .form: return "Form"
        }
    }
}

/// DynamoDB's attribute types, in the order the console's type menus list them.
enum DdbType: String, CaseIterable, Identifiable {
    case S, N, B, BOOL, NULL, M, L, SS, NS, BS

    var id: String { rawValue }

    var label: String {
        switch self {
        case .S: return "String"
        case .N: return "Number"
        case .B: return "Binary"
        case .BOOL: return "Boolean"
        case .NULL: return "Null"
        case .M: return "Map"
        case .L: return "List"
        case .SS: return "String set"
        case .NS: return "Number set"
        case .BS: return "Binary set"
        }
    }

    var isSet: Bool { self == .SS || self == .NS || self == .BS }
    /// Holds child values (Map, List, or one of the sets).
    var isContainer: Bool { self == .M || self == .L || isSet }

    /// Element type of a set (`SS` → `S`, ...).
    var setElementType: DdbType? {
        switch self {
        case .SS: return .S
        case .NS: return .N
        case .BS: return .B
        default: return nil
        }
    }
}

/// One attribute value exactly as DynamoDB types it ("DynamoDB JSON").
/// Unlike the grid's plain JSON this keeps a string set apart from a list
/// and the number 5 apart from the string "5" - what the item popup's
/// DynamoDB JSON and Form views need. Numbers stay strings, as DynamoDB
/// sends them, so no precision is lost; binary is base64.
indirect enum DdbTypedValue: Equatable {
    case s(String)
    case n(String)
    case b(String)
    case bool(Bool)
    case null
    case m([DdbNamedValue])
    case l([DdbTypedValue])
    case ss([String])
    case ns([String])
    case bs([String])

    var type: DdbType {
        switch self {
        case .s: return .S
        case .n: return .N
        case .b: return .B
        case .bool: return .BOOL
        case .null: return .NULL
        case .m: return .M
        case .l: return .L
        case .ss: return .SS
        case .ns: return .NS
        case .bs: return .BS
        }
    }
}

/// A named attribute - map members and top-level item attributes keep their
/// order (an item's key attributes first), which a `Dictionary` wouldn't.
struct DdbNamedValue: Equatable {
    var name: String
    var value: DdbTypedValue
}

struct DdbValueError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Typed JSON ({"S": "..."}) <-> model

extension DdbTypedValue {
    /// Parses one attribute value from DynamoDB JSON (already decoded by
    /// `JSONSerialization`). `path` names the attribute in error messages.
    static func fromTypedJSON(_ any: Any, path: String) throws -> DdbTypedValue {
        guard let object = any as? [String: Any], object.count == 1, let (key, raw) = object.first, let type = DdbType(rawValue: key) else {
            throw DdbValueError(message: "\(path): expected exactly one type key, e.g. {\"S\": \"text\"} (\(DdbType.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        func string(_ v: Any) throws -> String {
            if let s = v as? String { return s }
            if let n = v as? NSNumber, !n.isBool { return n.stringValue }
            throw DdbValueError(message: "\(path): \(type.rawValue) value must be a string")
        }
        func strings(_ v: Any) throws -> [String] {
            guard let array = v as? [Any] else { throw DdbValueError(message: "\(path): \(type.rawValue) value must be an array") }
            return try array.map(string)
        }
        switch type {
        case .S: return .s(try string(raw))
        case .N: return .n(try string(raw))
        case .B: return .b(try string(raw))
        case .BOOL:
            guard let n = raw as? NSNumber, n.isBool else { throw DdbValueError(message: "\(path): BOOL value must be true or false") }
            return .bool(n.boolValue)
        case .NULL: return .null
        case .SS: return .ss(try strings(raw))
        case .NS: return .ns(try strings(raw))
        case .BS: return .bs(try strings(raw))
        case .L:
            guard let array = raw as? [Any] else { throw DdbValueError(message: "\(path): L value must be an array") }
            return .l(try array.enumerated().map { try fromTypedJSON($0.element, path: "\(path)[\($0.offset)]") })
        case .M:
            guard let dict = raw as? [String: Any] else { throw DdbValueError(message: "\(path): M value must be an object") }
            return .m(try dict.keys.sorted().map { DdbNamedValue(name: $0, value: try fromTypedJSON(dict[$0]!, path: "\(path).\($0)")) })
        }
    }

    /// Foundation object for `JSONSerialization` (typed shape).
    var typedJSONObject: Any {
        switch self {
        case .s(let v): return ["S": v]
        case .n(let v): return ["N": v]
        case .b(let v): return ["B": v]
        case .bool(let v): return ["BOOL": v]
        case .null: return ["NULL": true]
        case .ss(let v): return ["SS": v]
        case .ns(let v): return ["NS": v]
        case .bs(let v): return ["BS": v]
        case .l(let v): return ["L": v.map(\.typedJSONObject)]
        case .m(let v): return ["M": Dictionary(v.map { ($0.name, $0.value.typedJSONObject) }, uniquingKeysWith: { _, last in last })]
        }
    }

    /// Order-preserving node for pretty printing (typed shape).
    var typedNode: OrderedJSON {
        switch self {
        case .s(let v): return .object([("S", .string(v))])
        case .n(let v): return .object([("N", .string(v))])
        case .b(let v): return .object([("B", .string(v))])
        case .bool(let v): return .object([("BOOL", .bool(v))])
        case .null: return .object([("NULL", .bool(true))])
        case .ss(let v): return .object([("SS", .array(v.map { .string($0) }))])
        case .ns(let v): return .object([("NS", .array(v.map { .string($0) }))])
        case .bs(let v): return .object([("BS", .array(v.map { .string($0) }))])
        case .l(let v): return .object([("L", .array(v.map(\.typedNode)))])
        case .m(let v): return .object([("M", .object(v.map { ($0.name, $0.value.typedNode) }))])
        }
    }

    /// Order-preserving node for pretty printing (plain shape - what the
    /// grid and the original JSON view show). Sets become arrays, numbers
    /// are emitted as the literal DynamoDB stored.
    var plainNode: OrderedJSON {
        switch self {
        case .s(let v), .b(let v): return .string(v)
        case .n(let v): return Double(v) != nil ? .number(v) : .string(v)
        case .bool(let v): return .bool(v)
        case .null: return .null
        case .ss(let v), .bs(let v): return .array(v.map { .string($0) })
        case .ns(let v): return .array(v.map { Double($0) != nil ? .number($0) : .string($0) })
        case .l(let v): return .array(v.map(\.plainNode))
        case .m(let v): return .object(v.map { ($0.name, $0.value.plainNode) })
        }
    }

    // MARK: Plain JSON -> typed

    /// Infers DynamoDB types from plain JSON the way the SDK's `marshall()`
    /// does (string→S, number→N, bool→BOOL, null→NULL, array→L,
    /// object→M) - except where `hint` (the attribute's type before
    /// editing) says otherwise and the new value still fits it: an array
    /// that used to be a string/number/binary set stays a set, a string
    /// that used to be binary stays binary, a numeric string that used to
    /// be a number stays a number. Without this, editing one field in the
    /// plain JSON view would silently turn every set in the item into a list.
    static func fromPlain(_ any: Any, hint: DdbTypedValue?) -> DdbTypedValue {
        if any is NSNull { return .null }
        if let n = any as? NSNumber {
            if n.isBool { return .bool(n.boolValue) }
            return .n(n.stringValue)
        }
        if let s = any as? String {
            switch hint {
            case .b: return .b(s)
            case .n where Double(s) != nil: return .n(s)
            default: return .s(s)
            }
        }
        if let array = any as? [Any] {
            switch hint {
            case .ss where array.allSatisfy({ $0 is String }):
                return .ss(array.map { $0 as! String })
            case .bs where array.allSatisfy({ $0 is String }):
                return .bs(array.map { $0 as! String })
            case .ns where array.allSatisfy({ ($0 as? NSNumber).map { !$0.isBool } ?? (($0 as? String).flatMap(Double.init) != nil) }):
                return .ns(array.map { ($0 as? NSNumber)?.stringValue ?? ($0 as! String) })
            case .l(let old):
                return .l(array.enumerated().map { fromPlain($0.element, hint: $0.offset < old.count ? old[$0.offset] : nil) })
            default:
                return .l(array.map { fromPlain($0, hint: nil) })
            }
        }
        if let dict = any as? [String: Any] {
            let oldMembers: [DdbNamedValue]
            if case .m(let members) = hint { oldMembers = members } else { oldMembers = [] }
            return .m(orderedNames(Array(dict.keys), preferred: oldMembers.map(\.name)).map { name in
                DdbNamedValue(name: name, value: fromPlain(dict[name]!, hint: oldMembers.first { $0.name == name }?.value))
            })
        }
        return .s(String(describing: any))
    }
}

/// Keys in `preferred` order first (e.g. the key schema, or the order the
/// item had before editing), the rest alphabetically.
/// `names` with the `preferred` ones first. Every name appears exactly
/// once: callers pass overlapping lists (key order + the original item's
/// names, which also contain the keys), and a duplicate here used to reach
/// `Dictionary(uniqueKeysWithValues:)` on save and crash the app.
func orderedNames(_ names: [String], preferred: [String]) -> [String] {
    let available = Set(names)
    var seen = Set<String>()
    let first = preferred.filter { available.contains($0) && seen.insert($0).inserted }
    return first + Set(names).subtracting(first).sorted()
}

// MARK: - Whole items

enum DdbItemCodec {
    /// Typed item (`{"PK": {"S": ...}, ...}`) from the backend / the typed editor.
    static func parseTyped(_ object: [String: Any], keyOrder: [String]) throws -> [DdbNamedValue] {
        try orderedNames(Array(object.keys), preferred: keyOrder).map {
            DdbNamedValue(name: $0, value: try DdbTypedValue.fromTypedJSON(object[$0]!, path: $0))
        }
    }

    static func parseTyped(text: String, keyOrder: [String]) throws -> [DdbNamedValue] {
        guard let object = try parseObject(text) else {
            throw DdbValueError(message: "Must be a JSON object of attributes, e.g. { \"PK\": { \"S\": \"value\" } }")
        }
        return try parseTyped(object, keyOrder: keyOrder)
    }

    /// Plain JSON text → typed item, keeping types from `original` where the new values still fit them.
    static func parsePlain(text: String, original: [DdbNamedValue], keyOrder: [String]) throws -> [DdbNamedValue] {
        guard let object = try parseObject(text) else {
            throw DdbValueError(message: "Must be a JSON object, e.g. { \"key\": \"value\" } - not an array or a bare value")
        }
        return orderedNames(Array(object.keys), preferred: keyOrder + original.map(\.name)).map { name in
            DdbNamedValue(name: name, value: DdbTypedValue.fromPlain(object[name]!, hint: original.first { $0.name == name }?.value))
        }
    }

    static func typedText(_ item: [DdbNamedValue]) -> String {
        OrderedJSON.object(item.map { ($0.name, $0.value.typedNode) }).pretty()
    }

    static func plainText(_ item: [DdbNamedValue]) -> String {
        OrderedJSON.object(item.map { ($0.name, $0.value.plainNode) }).pretty()
    }

    static func typedJSONObject(_ item: [DdbNamedValue]) -> [String: Any] {
        // Last one wins instead of trapping - names are de-duplicated
        // upstream, this only keeps a stray duplicate from killing the app.
        Dictionary(item.map { ($0.name, $0.value.typedJSONObject) }, uniquingKeysWith: { _, last in last })
    }

    private static func parseObject(_ text: String) throws -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { throw DdbValueError(message: "Couldn't read this as text") }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
        } catch {
            throw DdbValueError(message: "Invalid JSON: \(error.localizedDescription)")
        }
    }
}

// MARK: - Order-preserving JSON printer

/// Minimal JSON tree that keeps object key order - `JSONSerialization`
/// either scrambles keys or (with `.sortedKeys`) sorts them, which would
/// push an item's PK/SK away from the top.
indirect enum OrderedJSON {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    /// Raw numeric literal, emitted verbatim.
    case number(String)
    case bool(Bool)
    case null

    func pretty(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .object(let members):
            if members.isEmpty { return "{}" }
            let body = members.map { "\(inner)\(Self.quote($0.0)): \($0.1.pretty(indent: indent + 1))" }.joined(separator: ",\n")
            return "{\n\(body)\n\(pad)}"
        case .array(let elements):
            if elements.isEmpty { return "[]" }
            let body = elements.map { "\(inner)\($0.pretty(indent: indent + 1))" }.joined(separator: ",\n")
            return "[\n\(body)\n\(pad)]"
        case .string(let s): return Self.quote(s)
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func quote(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let wrapped = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(wrapped.dropFirst().dropLast())
    }
}

extension NSNumber {
    /// `JSONSerialization` decodes JSON booleans as `NSNumber` too - this is
    /// the reliable way to tell `true` from `1`.
    var isBool: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}
