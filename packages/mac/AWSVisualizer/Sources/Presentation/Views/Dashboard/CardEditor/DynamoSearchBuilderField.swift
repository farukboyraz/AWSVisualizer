import SwiftUI

/// The DynamoDB search card's builder - the three ways the DynamoDB screen
/// searches a table, picked with a switch:
/// - **Query**: query on the table or an index (key names / types from the
///   table), partition key value, optional sort key condition, and Filter
///   Builder conditions on the partition;
/// - **Filter**: Filter Builder conditions over the whole table (the grid's
///   search);
/// - **PartiQL**: a SELECT statement.
/// Conditions are edited in the app's own Filter Builder popup. Writes the
/// JSON the sidecar's `dynamodb.search` reads and shows the statement the
/// search amounts to.
struct DynamoSearchBuilderField: View {
    let param: CardTemplate.Param
    @Binding var value: String
    let params: [String: String]
    let context: CardFormContext

    @Environment(\.apiService) private var api

    @State private var targets: [CardOption] = []
    @State private var attributes: [String] = []
    @State private var isLoading = false
    @State private var failure: String?
    @State private var model = Model()
    @State private var showFilterBuilder = false

    private var language: AppLanguage { context.language }
    private var table: String { params["table"] ?? "" }

    enum Mode: String, CaseIterable { case query, scan, partiql }

    struct Model: Equatable {
        var mode: Mode = .query
        var index = ""
        var pkName = ""
        var pkType = "S"
        var pkValue = ""
        var skName: String?
        var skType = "S"
        var skOperator = "none"
        var skValue = ""
        var skValue2 = ""
        var conditions: [FilterCondition] = []
        var statement = ""
    }

    private static let sortOperators = ["none", "=", "<", "<=", ">", ">=", "begins_with", "between"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if table.isEmpty {
                Text(language.qbChooseTable).font(.callout).foregroundStyle(.secondary)
            } else if isLoading && targets.isEmpty {
                ProgressView().controlSize(.small)
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            } else {
                MultiSwitchBox(selection: $model.mode, options: Mode.allCases.map { ($0, language.qbMode($0.rawValue)) }, segmentWidth: 140)
                Text(language.qbModeHint(model.mode.rawValue)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                switch model.mode {
                case .query: keyCondition; filters
                case .scan: filters
                case .partiql: partiqlEditor
                }
                if model.mode != .partiql { statementView }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: "\(context.profile)|\(context.region)|\(table)") { await loadSchema() }
        .onChange(of: model) { _, newModel in value = Self.json(newModel) }
        .sheet(isPresented: $showFilterBuilder) {
            ColumnFilterBuilderView(
                columns: attributes.map { DataGridColumn(id: $0, title: $0) },
                initialConditions: model.conditions.isEmpty ? [FilterCondition(logicalOperator: nil, columnID: attributes.first ?? "")] : model.conditions,
                onSearch: { conditions in
                    model.conditions = conditions.filter { !$0.columnID.isEmpty }
                    showFilterBuilder = false
                },
                onDiscard: { showFilterBuilder = false },
                onClearAll: {
                    model.conditions = []
                    showFilterBuilder = false
                }
            )
        }
    }

    // MARK: Query: key condition

    @ViewBuilder private var keyCondition: some View {
        row(language.qbTarget) {
            Picker("", selection: Binding(get: { model.index }, set: { selectTarget($0) })) {
                ForEach(targets, id: \.value) { target in
                    Text("\(target.label)  ·  \(target.detail ?? "")").tag(target.value)
                }
            }
            .labelsHidden()
        }
        row("\(language.qbPartition): \(model.pkName) (\(model.pkType))") {
            TextField(language.qbValue, text: $model.pkValue).textFieldStyle(.roundedBorder)
        }
        if let skName = model.skName {
            row("\(language.qbSort): \(skName) (\(model.skType))") {
                HStack {
                    Picker("", selection: $model.skOperator) {
                        ForEach(Self.sortOperators.filter { model.skType == "S" || $0 != "begins_with" }, id: \.self) { Text(language.qbSortOp($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if model.skOperator != "none" {
                        TextField(language.qbValue, text: $model.skValue).textFieldStyle(.roundedBorder)
                        if model.skOperator == "between" {
                            Text("–")
                            TextField(language.qbValue, text: $model.skValue2).textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
        }
    }

    // MARK: Filter Builder conditions

    private var filters: some View {
        row(language.qbFilters) {
            VStack(alignment: .leading, spacing: 6) {
                if model.conditions.isEmpty {
                    Text(model.mode == .scan ? language.qbNoFilterScan : language.qbNoFilter).font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.conditions.enumerated()), id: \.element.id) { index, c in
                        HStack(spacing: 6) {
                            Text(index == 0 ? "WHERE" : (c.logicalOperator ?? .and).rawValue)
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .leading)
                            Text(c.columnID).font(.callout.weight(.semibold))
                            Text(language.qbMatch(c.matchOperator)).font(.callout).foregroundStyle(.secondary)
                            if !c.matchOperator.takesNoValue {
                                Text(c.values.filter { !$0.isEmpty }.joined(separator: ", ")).font(.callout.monospaced())
                            }
                        }
                    }
                }
                HStack {
                    EditButton(model.conditions.isEmpty ? language.qbAddFilter : language.qbEditFilter, compactSize: 24, isDisabled: attributes.isEmpty) { showFilterBuilder = true }
                    if !model.conditions.isEmpty {
                        ClearButton(compactSize: 24, help: language.qbClearFilter) { model.conditions = [] }
                    }
                }
            }
        }
    }

    // MARK: PartiQL

    private var partiqlEditor: some View {
        row(language.qbPartiql) {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $model.statement)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                Text(language.qbPartiqlHint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if model.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.statement = statement }
        }
    }

    private var statementView: some View {
        row(language.qbStatement) {
            Text(statement)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    /// The PartiQL the Query / Filter search amounts to.
    private var statement: String {
        let key: PartiQLFilterBuilder.KeyCondition? = model.mode == .query && !model.pkName.isEmpty
            ? PartiQLFilterBuilder.KeyCondition(
                indexName: model.index.isEmpty ? nil : model.index,
                partitionKey: (model.pkName, model.pkType, model.pkValue),
                sortKey: model.skName.map { ($0, model.skType, model.skOperator, model.skValue, model.skValue2) }
            )
            : nil
        return PartiQLFilterBuilder.statement(tableName: table, conditions: model.conditions, key: key)
    }

    // MARK: - Schema / JSON

    private func loadSchema() async {
        guard !table.isEmpty, let source = param.source else { targets = []; return }
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        isLoading = true
        failure = nil
        do {
            async let keyTargets = api.getCardOptions(service: context.service, source: source, profile: context.profile, region: context.region, params: params)
            async let names = api.getCardOptions(service: context.service, source: "dynamodb.attributes", profile: context.profile, region: context.region, params: params)
            targets = try await keyTargets
            attributes = ((try? await names) ?? []).map(\.value)
            // Keep a saved search when it still fits the table; else start on the table itself.
            if let saved = Self.parse(value), saved.mode != .query || targets.contains(where: { $0.value == saved.index && $0.meta?.pk?.name == saved.pkName }) {
                model = saved
                if saved.mode != .query, let first = targets.first?.value { selectTarget(first, keepMode: true) }
            } else {
                selectTarget(targets.first?.value ?? "", keepMode: true)
            }
        } catch is CancellationError {
        } catch {
            failure = error.friendlyMessage
        }
        isLoading = false
    }

    private func selectTarget(_ index: String, keepMode: Bool = false) {
        guard let target = targets.first(where: { $0.value == index }), let pk = target.meta?.pk else { return }
        var m = model
        m.index = index
        if m.pkName != pk.name { m.pkValue = "" }
        m.pkName = pk.name
        m.pkType = pk.type
        if let sk = target.meta?.sk {
            if m.skName != sk.name { m.skOperator = "none"; m.skValue = ""; m.skValue2 = "" }
            m.skName = sk.name
            m.skType = sk.type
        } else {
            m.skName = nil
            m.skOperator = "none"
        }
        model = m
        value = Self.json(m)
    }

    static func json(_ m: Model) -> String {
        var object: [String: Any] = ["mode": m.mode.rawValue]
        switch m.mode {
        case .partiql:
            object["statement"] = m.statement
        case .scan:
            object["conditions"] = m.conditions.map(\.apiPayload)
        case .query:
            object["pk"] = ["name": m.pkName, "type": m.pkType, "value": m.pkValue]
            if !m.index.isEmpty { object["index"] = m.index }
            if let sk = m.skName, m.skOperator != "none" {
                var s: [String: Any] = ["name": sk, "type": m.skType, "operator": m.skOperator, "value": m.skValue]
                if m.skOperator == "between" { s["value2"] = m.skValue2 }
                object["sk"] = s
            }
            if !m.conditions.isEmpty { object["conditions"] = m.conditions.map(\.apiPayload) }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func parse(_ text: String) -> Model? {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var m = Model()
        m.mode = Mode(rawValue: object["mode"] as? String ?? "query") ?? .query
        m.statement = object["statement"] as? String ?? ""
        m.index = object["index"] as? String ?? ""
        if let pk = object["pk"] as? [String: Any] {
            m.pkName = pk["name"] as? String ?? ""
            m.pkType = pk["type"] as? String ?? "S"
            m.pkValue = pk["value"] as? String ?? ""
        } else if m.mode == .query {
            return nil
        }
        if let sk = object["sk"] as? [String: Any], let name = sk["name"] as? String {
            m.skName = name
            m.skType = sk["type"] as? String ?? "S"
            m.skOperator = sk["operator"] as? String ?? "none"
            m.skValue = sk["value"] as? String ?? ""
            m.skValue2 = sk["value2"] as? String ?? ""
        }
        let codes = Dictionary(uniqueKeysWithValues: FilterMatchOperator.allCases.map { ($0.apiCode, $0) })
        m.conditions = (object["conditions"] as? [[String: Any]] ?? []).compactMap { c in
            guard let column = c["columnID"] as? String, let op = codes[c["matchOperator"] as? String ?? ""] else { return nil }
            let logical: FilterLogicalOperator? = (c["logicalOperator"] as? String).map { $0 == "or" ? .or : .and }
            return FilterCondition(logicalOperator: logical, columnID: column, matchOperator: op, values: c["values"] as? [String] ?? [""])
        }
        return m
    }

    /// What's missing before the search can be saved (nil = ready).
    static func problem(_ text: String, language: AppLanguage) -> String? {
        guard let m = parse(text) else { return language.qbSetUp }
        switch m.mode {
        case .query: return m.pkValue.isEmpty ? "\(language.qbPartition): \(m.pkName)" : nil
        case .scan: return m.conditions.isEmpty ? language.qbNoFilterScan : nil
        case .partiql:
            let s = m.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.lowercased().hasPrefix("select") ? nil : language.qbPartiqlHint
        }
    }
}
