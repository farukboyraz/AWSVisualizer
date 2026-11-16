import Foundation

/// Messages for the sidecar's input checks
/// (packages/api/src/presentation/middleware/validate-input.ts). The sidecar
/// rejects a bad profile / region / id / tag with a 400 carrying a stable
/// `code` and `params`; the text the user sees is built here, in the app's
/// language, instead of showing the sidecar's English fallback or AWS's
/// own "1 validation error detected…" wording.
extension AppLanguage {
    /// The language picked in the app - mirrored by `AppState.language`
    /// so error text built outside a view can follow it.
    nonisolated(unsafe) static var current: AppLanguage = .en

    func validationMessage(_ failure: ValidationFailure) -> String {
        let p = failure.params
        let max = p["max"] ?? ""
        let length = p["length"].map { self == .tr ? " (şu an \($0))" : " (currently \($0))" } ?? ""
        switch (failure.code, self) {
        case ("ProfileNotFound", .en): return "Profile \"\(p["profile"] ?? "")\" was not found in ~/.aws/config or ~/.aws/credentials."
        case ("ProfileNotFound", .tr): return "\"\(p["profile"] ?? "")\" profili ~/.aws/config veya ~/.aws/credentials dosyasında bulunamadı."
        case ("RegionInvalid", .en): return "\"\(p["region"] ?? "")\" is not a valid AWS region (for example eu-west-1)."
        case ("RegionInvalid", .tr): return "\"\(p["region"] ?? "")\" geçerli bir AWS bölgesi değil (örneğin eu-west-1)."
        case ("IdTooLong", .en): return "The resource id is too long (at most \(max) characters)."
        case ("IdTooLong", .tr): return "Kaynak kimliği çok uzun (en fazla \(max) karakter)."
        case ("TagKeyEmpty", .en): return "Tag key cannot be empty."
        case ("TagKeyEmpty", .tr): return "Etiket anahtarı boş olamaz."
        case ("TagKeyTooLong", .en): return "Tag key can be at most \(max) characters\(length)."
        case ("TagKeyTooLong", .tr): return "Etiket anahtarı en fazla \(max) karakter olabilir\(length)."
        case ("TagKeyReserved", .en): return "Tag keys starting with \"aws:\" are reserved for AWS."
        case ("TagKeyReserved", .tr): return "\"aws:\" ile başlayan etiket anahtarları AWS'ye ayrılmıştır."
        case ("TagValueTooLong", .en): return "Tag value can be at most \(max) characters\(length)."
        case ("TagValueTooLong", .tr): return "Etiket değeri en fazla \(max) karakter olabilir\(length)."
        default: return failure.fallback
        }
    }
}

/// Body of a sidecar 400 with `type: "ValidationError"`.
struct ValidationFailure: Decodable {
    let code: String
    let field: String?
    let params: [String: String]
    let fallback: String

    private enum CodingKeys: String, CodingKey { case type, code, field, params, error }

    /// Built in the app (tag form) with the same codes the sidecar uses.
    init(code: String, field: String, params: [String: String] = [:]) {
        self.code = code
        self.field = field
        self.params = params
        fallback = code
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .type) == "ValidationError" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "not a validation error")
        }
        code = try c.decode(String.self, forKey: .code)
        field = try c.decodeIfPresent(String.self, forKey: .field)
        fallback = try c.decodeIfPresent(String.self, forKey: .error) ?? code
        // Numbers and strings both arrive as text.
        var params: [String: String] = [:]
        if let raw = try c.decodeIfPresent([String: LooseValue].self, forKey: .params) {
            for (key, value) in raw { params[key] = value.text }
        }
        self.params = params
    }

    /// Parses an error body, nil when it isn't a validation error.
    static func from(body: String) -> ValidationFailure? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ValidationFailure.self, from: data)
    }
}

private struct LooseValue: Decodable {
    let text: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { text = s }
        else if let i = try? c.decode(Int.self) { text = String(i) }
        else if let d = try? c.decode(Double.self) { text = String(d) }
        else { text = "" }
    }
}

/// The sidecar's tag rules (validate-input.ts), checked in the tag forms
/// while the user types so the warning shows before anything is sent.
/// Lengths are Unicode scalars, as the sidecar and AWS count them.
enum TagRules {
    static let keyMax = 128
    static let valueMax = 256

    /// nil = fine to send. An empty key also returns nil: the Add button is
    /// simply disabled then, a warning before typing anything would be noise.
    static func problem(key rawKey: String, value: String) -> ValidationFailure? {
        let key = rawKey.trimmingCharacters(in: .whitespaces)
        if key.isEmpty {
            return rawKey.isEmpty ? nil : ValidationFailure(code: "TagKeyEmpty", field: "key")
        }
        let keyLength = key.unicodeScalars.count
        if keyLength > keyMax {
            return ValidationFailure(code: "TagKeyTooLong", field: "key", params: ["max": "\(keyMax)", "length": "\(keyLength)"])
        }
        if key.lowercased().hasPrefix("aws:") {
            return ValidationFailure(code: "TagKeyReserved", field: "key")
        }
        let valueLength = value.unicodeScalars.count
        if valueLength > valueMax {
            return ValidationFailure(code: "TagValueTooLong", field: "value", params: ["max": "\(valueMax)", "length": "\(valueLength)"])
        }
        return nil
    }

    /// Whether the Add button may send this key/value.
    static func canAdd(key: String, value: String) -> Bool {
        !key.trimmingCharacters(in: .whitespaces).isEmpty && problem(key: key, value: value) == nil
    }
}
