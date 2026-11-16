import Foundation

/// Turns Filter Builder conditions into a DynamoDB PartiQL `SELECT` - the
/// "Search with PartiQL" button. Conditions fold left to right like the
/// builder does (`((a OR b) AND c)`), so each step is parenthesized rather
/// than relying on PartiQL's AND-before-OR precedence.
///
/// Differences from the builder's own matching that can't be expressed in
/// PartiQL: comparisons are case-sensitive and typed (a column whose loaded
/// values are numbers/booleans gets unquoted literals, see `ValueKind`), and
/// BNN only covers missing / NULL / empty string, not the text "null"/"none".
enum PartiQLFilterBuilder {
    enum ValueKind { case string, number, bool }

    /// The Query form's key condition, when the search started from Query.
    struct KeyCondition {
        var indexName: String?
        var partitionKey: (name: String, type: String, value: String)
        var sortKey: (name: String, type: String, operator: String, value: String, value2: String)?
    }

    static func statement(
        tableName: String,
        conditions: [FilterCondition],
        key: KeyCondition? = nil,
        kind: (String) -> ValueKind = { _ in .string }
    ) -> String {
        var from = ident(tableName)
        if let index = key?.indexName { from += "." + ident(index) }

        var clauses: [String] = []
        if let key {
            let pk = key.partitionKey
            clauses.append("\(ident(pk.name)) = \(keyLiteral(pk.value, type: pk.type))")
            if let sk = key.sortKey, let clause = sortClause(sk) { clauses.append(clause) }
        }
        if let filter = filterExpression(conditions, kind: kind) { clauses.append(filter) }

        var sql = "SELECT * FROM \(from)"
        if !clauses.isEmpty { sql += "\nWHERE " + clauses.joined(separator: "\n  AND ") }
        return sql
    }

    static func filterExpression(_ conditions: [FilterCondition], kind: (String) -> ValueKind) -> String? {
        let parts = conditions.compactMap { c in expression(c, kind: kind(c.columnID)).map { (c.logicalOperator, $0) } }
        guard var result = parts.first?.1 else { return nil }
        for (op, expr) in parts.dropFirst() {
            result = "(\(result) \(op == .or ? "OR" : "AND") \(expr))"
        }
        return result
    }

    private static func expression(_ c: FilterCondition, kind: ValueKind) -> String? {
        let col = ident(c.columnID)
        let first = c.values.first ?? ""
        switch c.matchOperator {
        case .equal: return "\(col) = \(literal(first, kind: kind))"
        case .notEqual: return "\(col) <> \(literal(first, kind: kind))"
        case .contains:
            if first.isEmpty { return nil }
            return "contains(\(col), \(literal(first, kind: .string)))"
        case .isIn:
            let values = c.values.filter { !$0.isEmpty }
            if values.isEmpty { return nil }
            return "\(col) IN [\(values.map { literal($0, kind: kind) }.joined(separator: ", "))]"
        case .onlyBlankNullNone:
            return "(\(col) IS MISSING OR \(col) IS NULL OR \(col) = '')"
        case .notBlankNullNone:
            return "(\(col) IS NOT MISSING AND \(col) IS NOT NULL AND \(col) <> '')"
        }
    }

    private static let sortOperators: [String: String] = ["=": "=", "<": "<", "<=": "<=", ">": ">", ">=": ">="]

    private static func sortClause(_ sk: (name: String, type: String, operator: String, value: String, value2: String)) -> String? {
        let col = ident(sk.name)
        let v1 = keyLiteral(sk.value, type: sk.type)
        switch sk.operator {
        case "none": return nil
        case "between": return "\(col) BETWEEN \(v1) AND \(keyLiteral(sk.value2, type: sk.type))"
        case "begins_with": return "begins_with(\(col), \(v1))"
        default: return sortOperators[sk.operator].map { "\(col) \($0) \(v1)" }
        }
    }

    /// Double-quoted identifier (`"a""b"` for a quote inside).
    static func ident(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func stringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func literal(_ value: String, kind: ValueKind) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .number where Double(trimmed) != nil: return trimmed
        case .bool where ["true", "false"].contains(trimmed.lowercased()): return trimmed.lowercased()
        default: return stringLiteral(value)
        }
    }

    private static func keyLiteral(_ value: String, type: String) -> String {
        type == "N" ? literal(value, kind: .number) : stringLiteral(value)
    }
}

/// Spots the slow PartiQL mistake: `FROM "Table"` with `WHERE "GSI1PK" =`
/// on an index key. DynamoDB never picks an index by itself - without
/// `FROM "Table"."Index"` that's a full table Scan (seconds) instead of a
/// Query on one partition (milliseconds), even though the result is the same.
enum PartiQLIndexAdvisor {
    struct Suggestion: Equatable {
        let indexName: String
        let partitionKey: String
        /// The statement with `FROM "Table"` → `FROM "Table"."Index"`.
        let rewritten: String
        /// Safe to apply on Run without asking: the index projects every
        /// attribute and the WHERE has no OR, so reading the index returns
        /// exactly the rows the table scan would - only much faster.
        let isAutomatic: Bool
    }

    static func suggest(statement: String, tableName: String, tableKeySchema: [DdbKeySchemaElement], indexes: [DdbIndexInfo]) -> Suggestion? {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("SELECT") else { return nil }
        let from = PartiQLFilterBuilder.ident(tableName)
        // Only the bare table: `FROM "T"` not followed by `."Index"`.
        let pattern = "FROM\\s+" + NSRegularExpression.escapedPattern(for: from) + "(?!\\s*\\.)"
        guard let fromRegex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = fromRegex.firstMatch(in: statement, range: NSRange(statement.startIndex..., in: statement)),
              let fromRange = Range(match.range, in: statement) else { return nil }
        let wherePart = statement[fromRange.upperBound...]
        func hasEquality(_ attribute: String) -> Bool {
            let p = "(^|[^A-Za-z0-9_\"])\"?" + NSRegularExpression.escapedPattern(for: attribute) + "\"?\\s*="
            return wherePart.range(of: p, options: .regularExpression) != nil
        }
        // The table's own partition key already makes it a Query.
        if let tablePK = tableKeySchema.first(where: { $0.keyType == "HASH" })?.attributeName, hasEquality(tablePK) { return nil }
        for index in indexes where index.indexType == "GSI" {
            guard let pk = index.keySchema.first(where: { $0.keyType == "HASH" })?.attributeName, hasEquality(pk) else { continue }
            var rewritten = statement
            rewritten.insert(contentsOf: "." + PartiQLFilterBuilder.ident(index.indexName), at: fromRange.upperBound)
            let hasOr = wherePart.range(of: "\\bOR\\b", options: [.regularExpression, .caseInsensitive]) != nil
            return Suggestion(indexName: index.indexName, partitionKey: pk, rewritten: rewritten,
                              isAutomatic: index.projectionType == "ALL" && !hasOr)
        }
        return nil
    }
}
