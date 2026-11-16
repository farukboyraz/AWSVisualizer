import Foundation

/// English + Turkish text sent by the sidecar; shown in the app's language.
struct LocalizedText: Codable, Equatable, Hashable {
    let en: String
    let tr: String

    func callAsFunction(_ language: AppLanguage) -> String { language == .tr ? tr : en }
}

/// A kind of dashboard card a service offers
/// (`GET /api/dashboard/card-templates?service=`).
struct CardTemplate: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        /// Shows a number; refreshed with the dashboard.
        case metric
        /// Changes something on AWS; only runs on Run + confirm.
        case action
        /// Opens a screen of the app.
        case link
        /// Free text.
        case note
    }

    struct Param: Codable, Equatable, Identifiable {
        enum ParamType: String, Codable { case text, textarea, select, combo, dynamoQuery, dynamoSearch }
        enum Scope: String, Codable { case card, run }

        struct Choice: Codable, Equatable { let value: String; let label: LocalizedText }
        /// Filled from an option source when empty (e.g. the last commit message).
        struct Prefill: Codable, Equatable { let source: String; let use: String }
        struct VisibleWhen: Codable, Equatable { let key: String; let `in`: [String] }

        let key: String
        let label: LocalizedText
        let type: ParamType
        var required: Bool?
        var scope: Scope?
        var hint: LocalizedText?
        var placeholder: String?
        var maxLength: Int?
        var pattern: String?
        var patternMessage: LocalizedText?
        var choices: [Choice]?
        var source: String?
        var dependsOn: [String]?
        var visibleWhen: VisibleWhen?
        var defaultValue: String?
        var prefill: Prefill?

        var id: String { key }
        var isRequired: Bool { required ?? false }
        var isRunTime: Bool { scope == .run }

        func isVisible(_ params: [String: String]) -> Bool {
            guard let rule = visibleWhen else { return true }
            return rule.in.contains(params[rule.key] ?? "")
        }

        /// What's wrong with `value`, or nil (same rules as the sidecar).
        func problem(_ value: String, language: AppLanguage) -> String? {
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                return isRequired ? (language == .tr ? "\(label.tr) gerekli" : "\(label.en) is required") : nil
            }
            if value.count > (maxLength ?? 1024) {
                return language == .tr ? "\(label.tr) çok uzun (en fazla \(maxLength ?? 1024))" : "\(label.en) is too long (at most \(maxLength ?? 1024))"
            }
            if let pattern, value.range(of: pattern, options: .regularExpression) == nil {
                return "\(label(language)): \(patternMessage?(language) ?? (language == .tr ? "geçerli değil" : "not valid"))"
            }
            return nil
        }
    }

    let id: String
    let kind: Kind
    let name: LocalizedText
    let description: LocalizedText
    let icon: String
    let params: [Param]
    var confirm: LocalizedText?
    var hasPreview: Bool?

    var cardParams: [Param] { params.filter { !$0.isRunTime } }
    var runParams: [Param] { params.filter(\.isRunTime) }
}

struct CardTemplatesResponse: Decodable { let templates: [CardTemplate] }

/// A dropdown choice (`GET /api/dashboard/card-options`).
struct CardOption: Decodable, Identifiable, Equatable {
    let value: String
    let label: String
    var detail: String?
    /// DynamoDB key schema: { pk: {name,type}, sk?: {name,type} }.
    var meta: KeySchemaMeta?

    var id: String { value + "|" + label }

    struct KeySchemaMeta: Decodable, Equatable {
        struct Key: Decodable, Equatable { let name: String; let type: String }
        var pk: Key?
        var sk: Key?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decode(String.self, forKey: .value)
        label = try c.decode(String.self, forKey: .label)
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        meta = try? c.decodeIfPresent(KeySchemaMeta.self, forKey: .meta)
    }

    private enum CodingKeys: String, CodingKey { case value, label, detail, meta }
}

struct CardOptionsResponse: Decodable { let items: [CardOption] }

/// The data a card works on, shown under the editor.
struct CardPreview: Decodable, Equatable {
    let title: LocalizedText
    let columns: [LocalizedText]
    let rows: [[String]]
    var more: Bool?
    let emptyMessage: LocalizedText
    var note: LocalizedText?
}

/// A screen of the app (a card's link, an action's result).
struct CardLinkTarget: Codable, Equatable {
    let service: String
    var resource: String?
    var tab: String?
    /// S3: folder inside the bucket.
    var prefix: String?
    /// DynamoDB: the card's query JSON, run in the table's Query form.
    var query: String?
    /// Lists with a filter field.
    var filter: String?
}

/// What an action card's run answered.
struct CardActionResult: Codable, Equatable {
    let message: LocalizedText
    var link: CardLinkTarget?
}
