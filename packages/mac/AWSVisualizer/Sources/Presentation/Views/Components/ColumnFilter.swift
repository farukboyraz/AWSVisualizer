import Foundation

/// How a condition combines with whatever precedes it - `nil` on a
/// condition means it's the first one, with nothing to combine with yet.
enum FilterLogicalOperator: String, CaseIterable, Identifiable {
    case and = "AND"
    case or = "OR"

    var id: String { rawValue }
}

/// The SQL-ish comparison a single filter condition applies to one column's
/// value.
enum FilterMatchOperator: String, CaseIterable, Identifiable {
    case equal = "Equal"
    case notEqual = "Not Equal"
    case contains = "Contain"
    case onlyBlankNullNone = "Only BNN"
    case notBlankNullNone = "Not BNN"
    case isIn = "In"

    var id: String { rawValue }

    /// Exactly one free-text value to type.
    var takesSingleValue: Bool {
        self == .equal || self == .notEqual || self == .contains
    }

    /// No value at all - matches purely on blank/null/none-ness.
    var takesNoValue: Bool {
        self == .onlyBlankNullNone || self == .notBlankNullNone
    }

    /// Up to `FilterCondition.maxInValues` free-text values (SQL `IN (...)`).
    var takesMultipleValues: Bool {
        self == .isIn
    }
}

/// One row in the filter builder popup - a single column comparison, plus
/// (for every condition after the first) the operator that connects it to
/// the running result of everything before it.
struct FilterCondition: Identifiable, Equatable {
    /// Matches the SQL `IN (...)` cap the spec calls for - the 11th box
    /// never appears.
    static let maxInValues = 10
    /// Matches the "at most 5 criteria" cap on the whole filter.
    static let maxConditions = 5

    let id: UUID
    /// `nil` only for the first condition in the list.
    var logicalOperator: FilterLogicalOperator?
    var columnID: String
    var matchOperator: FilterMatchOperator
    /// Single element for `.equal`/`.notEqual`/`.contains`, empty for the
    /// two BNN operators, up to `maxInValues` elements for `.isIn` (with a
    /// trailing blank slot kept open for typing the next one, up to the cap).
    var values: [String]

    init(
        id: UUID = UUID(),
        logicalOperator: FilterLogicalOperator?,
        columnID: String,
        matchOperator: FilterMatchOperator = .contains,
        values: [String] = [""]
    ) {
        self.id = id
        self.logicalOperator = logicalOperator
        self.columnID = columnID
        self.matchOperator = matchOperator
        self.values = values
    }
}

/// True if `raw` counts as "blank/null/none" for the BNN operators - blank
/// (after trimming), or the literal text "null"/"none". That's all there is
/// to go on once a cell's value has already been rendered down to a plain
/// display string by the caller.
private func isBlankNullNone(_ raw: String?) -> Bool {
    guard let raw else { return true }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    return trimmed.caseInsensitiveCompare("null") == .orderedSame
        || trimmed.caseInsensitiveCompare("none") == .orderedSame
}

private func matchesSingle(_ condition: FilterCondition, value raw: String?) -> Bool {
    switch condition.matchOperator {
    case .onlyBlankNullNone:
        return isBlankNullNone(raw)
    case .notBlankNullNone:
        return !isBlankNullNone(raw)
    case .equal:
        guard let raw else { return false }
        return raw.caseInsensitiveCompare(condition.values.first ?? "") == .orderedSame
    case .notEqual:
        guard let raw else { return true }
        return raw.caseInsensitiveCompare(condition.values.first ?? "") != .orderedSame
    case .contains:
        let needle = condition.values.first ?? ""
        guard !needle.isEmpty else { return true }
        guard let raw else { return false }
        return raw.range(of: needle, options: .caseInsensitive) != nil
    case .isIn:
        guard let raw else { return false }
        let candidates = condition.values.filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return true }
        return candidates.contains { raw.caseInsensitiveCompare($0) == .orderedSame }
    }
}

/// Folds every condition left-to-right the way a flat SQL `WHERE a AND b OR
/// c` clause would - no operator precedence/grouping, each condition just
/// combines with the running result using its own connector. `valueForColumn`
/// is how the caller's row type exposes a cell's raw text for a given
/// column id, keeping this function generic over any row shape.
func evaluateFilterConditions<Row>(
    _ conditions: [FilterCondition],
    row: Row,
    valueForColumn: (Row, String) -> String?
) -> Bool {
    guard let first = conditions.first else { return true }
    var result = matchesSingle(first, value: valueForColumn(row, first.columnID))
    for condition in conditions.dropFirst() {
        let current = matchesSingle(condition, value: valueForColumn(row, condition.columnID))
        switch condition.logicalOperator ?? .and {
        case .and: result = result && current
        case .or: result = result || current
        }
    }
    return result
}

extension FilterCondition {
    /// The shape the backend's whole-table search expects - same fields,
    /// operators as stable codes instead of display labels.
    var apiPayload: [String: Any] {
        var payload: [String: Any] = [
            "columnID": columnID,
            "matchOperator": matchOperator.apiCode,
            "values": values,
        ]
        if let logicalOperator {
            payload["logicalOperator"] = logicalOperator == .and ? "and" : "or"
        }
        return payload
    }
}

extension FilterMatchOperator {
    var apiCode: String {
        switch self {
        case .equal: return "equal"
        case .notEqual: return "notEqual"
        case .contains: return "contains"
        case .onlyBlankNullNone: return "onlyBNN"
        case .notBlankNullNone: return "notBNN"
        case .isIn: return "in"
        }
    }
}
