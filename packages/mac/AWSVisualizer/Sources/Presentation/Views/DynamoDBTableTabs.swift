import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The per-table tabs, mirroring the DynamoDB console's table page:
/// Items (scan / query, in `DynamoDBView`), Overview (incl. the console's
/// "Additional settings": deletion protection, PITR, TTL), Indexes,
/// Monitor, Backups and Tags. PartiQL is a console docked under Items
/// (`DdbPartiQLConsole`), its results shown in the Items grid.
enum DynamoTableTab: String, CaseIterable, Identifiable {
    case items = "Items"
    case overview = "Overview"
    case indexes = "Indexes"
    case monitor = "Monitor"
    case backups = "Backups"
    case tags = "Tags"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .items: return "list.bullet.rectangle"
        case .overview: return "info.circle"
        case .indexes: return "arrow.triangle.branch"
        case .monitor: return "chart.bar"
        case .backups: return "externaldrive"
        case .tags: return "tag"
        }
    }
}

// MARK: - Shared: load the table detail once per tab

/// Loads `DdbTableDetail` for the tabs that need it and hands it (plus an
/// updater for mutations that return a fresh detail) to `content`.
private struct DdbDetailLoader<Content: View>: View {
    let tableName: String
    @ViewBuilder let content: (DdbTableDetail, @escaping (DdbTableDetail) -> Void) -> Content

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @State private var state: LoadState<DdbTableDetail> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { detail in
            content(detail) { state = .loaded($0) }
        }
        .task(id: tableName) { await load() }
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await api.getDynamoDBTableDetail(profile: appState.currentProfile, region: appState.currentRegion, tableName: tableName))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Overview

struct DdbOverviewTab: View {
    let tableName: String
    var onDeleted: () -> Void

    var body: some View {
        DdbDetailLoader(tableName: tableName) { detail, update in
            DdbOverviewContent(detail: detail, onUpdated: update, onDeleted: onDeleted)
        }
    }
}

private struct DdbOverviewContent: View {
    let detail: DdbTableDetail
    var onUpdated: (DdbTableDetail) -> Void
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var busy: String?
    @State private var error: String?
    @State private var ttlAttribute = ""
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        DetailTabPage(maxWidth: 820) {
            DetailSection(title: "General information") {
                HStack(spacing: 24) {
                    DetailField("Partition key", keyText("HASH"))
                    DetailField("Sort key", keyText("RANGE"))
                    DetailField("Status", detail.tableStatus)
                }
                HStack(spacing: 24) {
                    DetailField("Item count (approx.)", "\(detail.itemCount)")
                    DetailField("Table size", Formatters.formatBytes(detail.tableSizeBytes))
                    DetailField("Created", Formatters.formatISODate(detail.creationDateTime), monospaced: false)
                }
                DetailField("ARN", detail.tableArn)
                Text("Item count and size are refreshed by AWS roughly every 6 hours.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            DetailSection(title: "Capacity & storage") {
                HStack(spacing: 24) {
                    DetailField("Capacity mode", detail.billingMode == "PAY_PER_REQUEST" ? "On-demand" : "Provisioned")
                    if detail.billingMode != "PAY_PER_REQUEST" {
                        DetailField("Read / write capacity", "\(detail.readCapacity ?? 0) RCU / \(detail.writeCapacity ?? 0) WCU")
                    }
                    DetailField("Table class", detail.tableClass ?? "STANDARD")
                }
                DetailField("Encryption", detail.encryption + (detail.kmsKeyArn.map { "\n\($0)" } ?? ""))
                DetailField("DynamoDB stream", detail.streamEnabled ? "On (\(detail.streamViewType ?? "-"))" : "Off")
                if !detail.replicaRegions.isEmpty {
                    DetailField("Global table replicas", detail.replicaRegions.joined(separator: ", "))
                }
            }

            DetailSection(title: "Protection & recovery", spacing: 12) {
                LabeledSwitchBox(title: "Deletion protection", isOn: Binding(
                    get: { detail.deletionProtection },
                    set: { value in Task { await run("deletion") { try await api.setDynamoDBDeletionProtection(profile: appState.currentProfile, region: appState.currentRegion, tableName: detail.tableName, enabled: value) } } }
                ), onColor: .green)
                .disabled(busy != nil)
                LabeledSwitchBox(title: "Point-in-time recovery (continuous backups, 35 days)", isOn: Binding(
                    get: { detail.pitrEnabled },
                    set: { value in Task { await run("pitr") { try await api.setDynamoDBPointInTimeRecovery(profile: appState.currentProfile, region: appState.currentRegion, tableName: detail.tableName, enabled: value) } } }
                ), onColor: .green)
                .disabled(busy != nil)
                if detail.pitrEnabled, let earliest = detail.earliestRestorableTime {
                    Text("Restorable from \(Formatters.formatISODate(earliest)) to \(Formatters.formatISODate(detail.latestRestorableTime)). Restoring creates a new table - do that from the AWS console.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)

            DetailSection(title: "Time to Live (TTL)", spacing: 8) {
                Text("Items whose TTL attribute holds an epoch-seconds timestamp in the past are deleted automatically (usually within a few days, at no cost).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    StatusBadge(detail.ttlStatus)
                    if detail.ttlStatus == "ENABLED" || detail.ttlStatus == "ENABLING" {
                        Text("Attribute: \(detail.ttlAttribute ?? "-")").font(.caption.monospaced())
                        Spacer()
                        ConfirmedActionButton(
                            title: "Turn off TTL",
                            confirmationTitle: "Turn off TTL?",
                            confirmationMessage: "Expired items stop being deleted. DynamoDB allows only one TTL change per table per hour.",
                            isLoading: busy == "ttl",
                            isDisabled: detail.ttlStatus != "ENABLED"
                        ) { Task { await run("ttl") { try await api.setDynamoDBTimeToLive(profile: appState.currentProfile, region: appState.currentRegion, tableName: detail.tableName, attributeName: detail.ttlAttribute ?? "", enabled: false) } } }
                    } else {
                        TextField("TTL attribute name, e.g. expiresAt", text: $ttlAttribute)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                        ConfirmedActionButton(
                            title: "Turn on TTL",
                            confirmationTitle: "Turn on TTL with \"\(ttlAttribute)\"?",
                            confirmationMessage: "Every item whose \"\(ttlAttribute)\" is an epoch-seconds time in the past will be deleted automatically. DynamoDB allows only one TTL change per table per hour.",
                            isLoading: busy == "ttl",
                            isDisabled: ttlAttribute.trimmingCharacters(in: .whitespaces).isEmpty || detail.ttlStatus == "DISABLING",
                            role: nil
                        ) { Task { await run("ttl") { try await api.setDynamoDBTimeToLive(profile: appState.currentProfile, region: appState.currentRegion, tableName: detail.tableName, attributeName: ttlAttribute.trimmingCharacters(in: .whitespaces), enabled: true) } } }
                    }
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()

            DetailSection(title: "Danger zone", spacing: 8) {
                Text(detail.deletionProtection
                     ? "Deletion protection is on - turn it off above before the table can be deleted."
                     : "Deletes the table and every item in it. On-demand backups are kept; PITR history is not.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DeleteButton("Delete Table", isLoading: isDeleting, isDisabled: detail.deletionProtection) {
                    Task { await deleteTable() }
                }
                if let deleteError {
                    Text(deleteError).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func keyText(_ type: String) -> String {
        guard let key = detail.keySchema.first(where: { $0.keyType == type }) else { return "-" }
        let attrType = detail.attributeDefinitions.first { $0.attributeName == key.attributeName }?.attributeType ?? "?"
        return "\(key.attributeName) (\(attrType))"
    }

    private func run(_ name: String, _ action: () async throws -> DdbTableDetail) async {
        busy = name
        error = nil
        do {
            onUpdated(try await action())
        } catch {
            self.error = error.friendlyMessage
        }
        busy = nil
    }

    private func deleteTable() async {
        isDeleting = true
        deleteError = nil
        do {
            try await api.deleteDynamoDBTable(profile: appState.currentProfile, region: appState.currentRegion, tableName: detail.tableName)
            onDeleted()
        } catch {
            deleteError = error.friendlyMessage
        }
        isDeleting = false
    }
}

// MARK: - Indexes

struct DdbIndexesTab: View {
    let tableName: String

    var body: some View {
        DdbDetailLoader(tableName: tableName) { detail, _ in
            DetailTabPage(maxWidth: 900) {
                if detail.indexes.isEmpty {
                    Text("This table has no secondary indexes. Queries can only use the table's own keys.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(detail.indexes) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(index.indexName).font(.headline)
                            StatusBadge(index.indexType == "GSI" ? "Global" : "Local", color: index.indexType == "GSI" ? .blue : .purple)
                            if let status = index.indexStatus { StatusBadge(status) }
                            Spacer()
                        }
                        HStack(spacing: 24) {
                            DetailField("Partition key", key(index, "HASH", detail))
                            DetailField("Sort key", key(index, "RANGE", detail))
                            DetailField("Projection", index.projectionType ?? "-")
                        }
                        if !index.nonKeyAttributes.isEmpty {
                            DetailField("Projected attributes", index.nonKeyAttributes.joined(separator: ", "))
                        }
                        HStack(spacing: 24) {
                            DetailField("Items", index.itemCount.map(String.init) ?? "-")
                            DetailField("Size", Formatters.formatBytes(index.sizeBytes))
                            if let r = index.readCapacity, let w = index.writeCapacity {
                                DetailField("Capacity", "\(r) RCU / \(w) WCU")
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Text("Query an index from the Items tab (Query → Table or index). Creating or deleting indexes rebuilds data in the background - do that from the AWS console.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func key(_ index: DdbIndexInfo, _ type: String, _ detail: DdbTableDetail) -> String {
        guard let key = index.keySchema.first(where: { $0.keyType == type }) else { return "-" }
        let attrType = detail.attributeDefinitions.first { $0.attributeName == key.attributeName }?.attributeType ?? "?"
        return "\(key.attributeName) (\(attrType))"
    }
}

// MARK: - Monitor

struct DdbMonitorTab: View {
    let tableName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @State private var state: LoadState<DdbMetricsSummary> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { m in
            DetailTabPage(maxWidth: 1200) {
                MetricChartGrid(charts: charts, reloadKey: tableName)
                Text("Last 24 hours")
                    .font(.subheadline.bold())
                    .padding(.top, 8)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    MetricTile(title: "Consumed read capacity", value: Formatters.formatNumber(m.consumedReadCapacity, decimals: 0), caption: "RCU, total")
                    MetricTile(title: "Consumed write capacity", value: Formatters.formatNumber(m.consumedWriteCapacity, decimals: 0), caption: "WCU, total")
                    MetricTile(title: "Read throttles", value: Formatters.formatNumber(m.readThrottleEvents, decimals: 0), tint: (m.readThrottleEvents ?? 0) > 0 ? .orange : .primary)
                    MetricTile(title: "Write throttles", value: Formatters.formatNumber(m.writeThrottleEvents, decimals: 0), tint: (m.writeThrottleEvents ?? 0) > 0 ? .orange : .primary)
                    MetricTile(title: "GetItem latency", value: latency(m.getItemLatencyMs), caption: "avg")
                    MetricTile(title: "Query latency", value: latency(m.queryLatencyMs), caption: "avg")
                    MetricTile(title: "Scan latency", value: latency(m.scanLatencyMs), caption: "avg")
                    MetricTile(title: "PutItem latency", value: latency(m.putItemLatencyMs), caption: "avg")
                }
                Text("\"-\" means no requests of that kind in the window.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack {
                    Spacer()
                    RefreshButton("Refresh") { Task { await load() } }
                }
            }
        }
        .task(id: tableName) { await load() }
    }

    /// The console's Monitor graphs (AWS/DynamoDB, per table; latency per operation).
    private var charts: [MetricChartSpec] {
        let dims = ["TableName": tableName]
        func latency(_ op: String, _ i: Int) -> MetricQuery {
            MetricQuery(id: "m\(i)", namespace: "AWS/DynamoDB", metricName: "SuccessfulRequestLatency", dimensions: ["TableName": tableName, "Operation": op], stat: "Average", label: op)
        }
        return [
            MetricChartSpec("Capacity used", namespace: "AWS/DynamoDB", dimensions: dims, [("ConsumedReadCapacityUnits", "Sum", "Read (RCU)"), ("ConsumedWriteCapacityUnits", "Sum", "Write (WCU)")]),
            MetricChartSpec("Throttled requests", namespace: "AWS/DynamoDB", dimensions: dims, [("ReadThrottleEvents", "Sum", "Read"), ("WriteThrottleEvents", "Sum", "Write")]),
            MetricChartSpec(title: "Request latency", unit: "ms", queries: [latency("GetItem", 0), latency("Query", 1), latency("Scan", 2), latency("PutItem", 3)]),
            MetricChartSpec("Returned items", namespace: "AWS/DynamoDB", dimensions: ["TableName": tableName, "Operation": "Query"], [("ReturnedItemCount", "Average", "Query (avg)")]),
        ]
    }

    private func latency(_ ms: Double?) -> String {
        guard let ms else { return "-" }
        return "\(Formatters.formatNumber(ms, decimals: 1)) ms"
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await api.getDynamoDBMetrics(profile: appState.currentProfile, region: appState.currentRegion, tableName: tableName))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Backups

struct DdbBackupsTab: View {
    let tableName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @State private var state: LoadState<[DdbBackup]> = .loading
    @State private var backupName = ""
    @State private var isCreating = false
    @State private var deleting: String?
    @State private var error: String?
    @State private var message: String?

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Create on-demand backup", spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Backup name", text: $backupName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                    NewButton("Create Backup", systemImage: "externaldrive.badge.plus", isLoading: isCreating, isDisabled: backupName.trimmingCharacters(in: .whitespaces).isEmpty) {
                        Task { await create() }
                    }
                    Spacer()
                    RefreshButton(compactSize: 22, help: "Refresh") { Task { await load() } }
                }
                Text("Full copy of the table, kept until deleted; doesn't affect table performance. Restoring creates a new table - do that from the AWS console.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let message { Text(message).font(.caption).foregroundStyle(.green) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }

            DetailSection(title: "Backups") {
                LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No backups", minHeight: 80) { backups in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(backups) { backup in
                            HStack(spacing: 10) {
                                Text(backup.backupName).font(.caption.monospaced()).textSelection(.enabled)
                                Spacer()
                                if let type = backup.backupType { Text(type).font(.caption2).foregroundStyle(.secondary) }
                                if let status = backup.backupStatus { StatusBadge(status) }
                                Text(Formatters.formatBytes(backup.sizeBytes)).font(.caption2).foregroundStyle(.secondary)
                                Text(Formatters.formatISODate(backup.createdAt)).font(.caption2).foregroundStyle(.secondary)
                                    .frame(width: 140, alignment: .trailing)
                                if backup.backupType == "USER" {
                                    DeleteButton(compactSize: 20, isLoading: deleting == backup.backupArn, isDisabled: deleting != nil, help: "Delete Backup") {
                                        Task { await delete(backup) }
                                    }
                                }
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                }
            }
        }
        .task(id: tableName) {
            backupName = defaultName
            await load()
        }
    }

    private var defaultName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return "\(tableName)-\(f.string(from: Date()))"
    }

    private func load() async {
        state = .loading
        do {
            let backups = try await api.getDynamoDBBackups(profile: appState.currentProfile, region: appState.currentRegion, tableName: tableName)
            state = backups.isEmpty ? .empty : .loaded(backups)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }

    private func create() async {
        isCreating = true
        error = nil
        message = nil
        do {
            try await api.createDynamoDBBackup(profile: appState.currentProfile, region: appState.currentRegion, tableName: tableName, backupName: backupName.trimmingCharacters(in: .whitespaces))
            message = "Backup started."
            backupName = defaultName
            await load()
        } catch {
            self.error = error.friendlyMessage
        }
        isCreating = false
    }

    private func delete(_ backup: DdbBackup) async {
        deleting = backup.backupArn
        error = nil
        message = nil
        do {
            try await api.deleteDynamoDBBackup(profile: appState.currentProfile, region: appState.currentRegion, backupArn: backup.backupArn)
            await load()
        } catch {
            self.error = error.friendlyMessage
        }
        deleting = nil
    }
}

// MARK: - Tags

struct DdbTagsTab: View {
    let tableName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    var body: some View {
        DdbDetailLoader(tableName: tableName) { detail, update in
            ResourceTagsEditor(tags: detail.tags, resourceNoun: "table", onAdd: { key, value in
                update(try await api.addDynamoDBTableTag(profile: appState.currentProfile, region: appState.currentRegion, tableName: tableName, arn: detail.tableArn, key: key, value: value))
            }, onRemove: { key in
                update(try await api.removeDynamoDBTableTag(profile: appState.currentProfile, region: appState.currentRegion, tableName: tableName, arn: detail.tableArn, key: key))
            })
        }
    }
}

// MARK: - PartiQL editor

/// PartiQL state for one table: the statement being edited plus the rows
/// of the last run. Owned by `DynamoDBView` so the console (bottom) and
/// the results (the Items grid area above it) share it.
@Observable
@MainActor
final class PartiQLSession {
    /// Rows shown per step - the first Run and every Load More.
    static let pageSize = 100

    var statement = ""
    /// Everything read so far. A call can return more than asked (pages are
    /// read whole), so `shownItems` only reveals up to `shownLimit`; the
    /// rest is already here for the next Load More - no re-read.
    private(set) var items: [[String: DdbAttributeValue]] = []
    private(set) var nextToken: String?
    private(set) var shownLimit = PartiQLSession.pageSize
    /// Empty until something has been run - the Items grid shows PartiQL
    /// results only while this is set.
    private(set) var lastStatement = ""
    private(set) var isRunning = false
    private(set) var isLoadingAll = false
    private(set) var error: String?
    private(set) var info: String?
    private(set) var stopwatch = QueryStopwatch()
    /// Bumped by every Run/Stop/clear so an older read loop stops appending.
    private var generation = 0

    var hasResults: Bool { !lastStatement.isEmpty }
    var shownItems: [[String: DdbAttributeValue]] { items.count > shownLimit ? Array(items.prefix(shownLimit)) : items }
    /// Rows already read but not shown, or more left in DynamoDB.
    var hasMore: Bool { items.count > shownLimit || nextToken != nil }

    func reset(tableName: String) {
        clearResults()
        statement = "SELECT * FROM \"\(tableName)\""
    }

    /// Back to Scan/Query in the grid (the statement stays in the console).
    func clearResults() {
        generation += 1
        items = []
        nextToken = nil
        shownLimit = Self.pageSize
        lastStatement = ""
        isRunning = false
        isLoadingAll = false
        error = nil
        info = nil
        stopwatch = QueryStopwatch()
    }

    /// Stops reading; what was found stays (Load All shows it all).
    func stop() {
        generation += 1
        isRunning = false
        if isLoadingAll { shownLimit = items.count }
        isLoadingAll = false
        stopwatch.stop()
    }

    static func isWrite(_ s: String) -> Bool {
        let first = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first?.uppercased() ?? ""
        return ["INSERT", "UPDATE", "DELETE"].contains(first)
    }

    /// Runs the statement and reads the first `pageSize` rows (a SELECT
    /// with a filter may need several calls for that - each returns after
    /// ~3 s with whatever it found).
    ///
    /// `indexRoute` is the console's `PartiQLIndexAdvisor`: when a SELECT
    /// names only the table but pins a GSI partition key, the statement is
    /// rewritten to `FROM "Table"."Index"` before it runs (when that's safe,
    /// see `Suggestion.isAutomatic`) - a Query instead of a full scan.
    func run(api: APIService, profile: String, region: String,
             indexRoute: ((String) -> PartiQLIndexAdvisor.Suggestion?)? = nil) async {
        var routedIndex: String?
        if let route = indexRoute?(statement), route.isAutomatic {
            statement = route.rewritten
            routedIndex = route.indexName
        }
        items = []
        nextToken = nil
        shownLimit = Self.pageSize
        isLoadingAll = false
        lastStatement = statement
        stopwatch = QueryStopwatch()
        await read(api: api, profile: profile, region: region, first: true)
        if error == nil, info == nil, let routedIndex, !Self.isWrite(lastStatement) {
            info = "Read from index \(routedIndex) - a Query on one partition instead of a table scan (FROM was rewritten)."
        }
    }

    /// The next `pageSize` rows under the ones shown - from what's already
    /// read first, then from DynamoDB where the last call left off.
    func loadMore(api: APIService, profile: String, region: String) async {
        guard !isRunning, hasMore else { return }
        shownLimit = min(shownLimit, items.count) + Self.pageSize
        guard items.count < shownLimit, nextToken != nil else { return }
        await read(api: api, profile: profile, region: region, first: false)
    }

    /// Everything that's left, appended to the grid as it arrives.
    func loadAll(api: APIService, profile: String, region: String) async {
        guard !isRunning, hasMore else { return }
        shownLimit = .max
        isLoadingAll = true
        if nextToken != nil {
            await read(api: api, profile: profile, region: region, first: false)
        }
        isLoadingAll = false
        if nextToken == nil { shownLimit = items.count }
    }

    private func read(api: APIService, profile: String, region: String, first: Bool) async {
        generation += 1
        let mine = generation
        isRunning = true
        error = nil
        if first { info = nil }
        stopwatch.start(reset: false)
        let toRun = lastStatement
        var token = first ? nil : nextToken
        do {
            repeat {
                let wanted = shownLimit == .max ? 1000 : max(shownLimit - items.count, 1)
                let result = try await api.executeDynamoDBPartiQL(profile: profile, region: region, statement: toRun, nextToken: token, limit: wanted)
                guard mine == generation else { return }
                items += result.items
                token = result.nextToken
                nextToken = token
            } while token != nil && items.count < shownLimit && !Self.isWrite(toRun) && !Task.isCancelled
            if Self.isWrite(toRun) { info = "Statement executed." }
        } catch {
            guard mine == generation else { return }
            self.error = error.friendlyMessage
        }
        isRunning = false
        stopwatch.stop()
    }
}

/// Examples + Run for the PartiQL console. They sit in the Items bottom
/// bar, on the same row as New Item / PartiQL / Back to Scan, so the
/// console below is just the editor.
struct DdbPartiQLRunControls: View {
    let tableName: String
    var tableKeySchema: [DdbKeySchemaElement] = []
    var indexes: [DdbIndexInfo] = []
    @Bindable var session: PartiQLSession

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @State private var confirmWrite = false

    var body: some View {
        HStack(spacing: 10) {
            Menu("Examples") {
                Button("Select all") { session.statement = "SELECT * FROM \"\(tableName)\"" }
                Button("Select by key") { session.statement = "SELECT * FROM \"\(tableName)\" WHERE \"pk\" = 'value'" }
                Button("Query an index") { session.statement = "SELECT * FROM \"\(tableName)\".\"IndexName\" WHERE \"GSI1PK\" = 'value'" }
                Button("Update an attribute") { session.statement = "UPDATE \"\(tableName)\" SET \"attr\" = 'new' WHERE \"pk\" = 'value'" }
                Button("Delete an item") { session.statement = "DELETE FROM \"\(tableName)\" WHERE \"pk\" = 'value'" }
            }
            .fixedSize()
            RunButton("Run", isLoading: session.isRunning, isDisabled: session.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, help: "Run the PartiQL statement (⌘↩)") {
                if PartiQLSession.isWrite(session.statement) { confirmWrite = true } else { run() }
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
        .fixedSize()
        .confirmationDialog("Run this write statement?", isPresented: $confirmWrite, titleVisibility: .visible) {
            Button("Run", role: .destructive) { run() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("INSERT / UPDATE / DELETE change data in \(tableName) immediately and can't be undone.")
        }
    }

    private func run() {
        Task {
            await session.run(api: api, profile: appState.currentProfile, region: appState.currentRegion) {
                PartiQLIndexAdvisor.suggest(statement: $0, tableName: tableName, tableKeySchema: tableKeySchema, indexes: indexes)
            }
        }
    }
}

/// The PartiQL command line docked at the bottom of Items - results go to
/// the Items grid above it, not to a separate tab. Run / Examples live in
/// the bottom bar (`DdbPartiQLRunControls`); the title is a small badge.
struct DdbPartiQLConsole: View {
    let tableName: String
    var tableKeySchema: [DdbKeySchemaElement] = []
    var indexes: [DdbIndexInfo] = []
    @Bindable var session: PartiQLSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodeTextEditor(text: $session.statement, fontSize: 13)
                .frame(height: 84)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
                .overlay(alignment: .topTrailing) {
                    Label("PartiQL", systemImage: "terminal")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .padding(6)
                        .allowsHitTesting(false)
                        .help("SELECT, INSERT, UPDATE, DELETE - results show above")
                }
            if let suggestion = PartiQLIndexAdvisor.suggest(statement: session.statement, tableName: tableName, tableKeySchema: tableKeySchema, indexes: indexes),
               !suggestion.isAutomatic {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill").foregroundStyle(.orange)
                    Text("\"\(suggestion.partitionKey)\" is the partition key of index \(suggestion.indexName), but FROM names only the table - DynamoDB will scan the whole table. Reading the index is a fast Query on one partition.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    SecondaryButton("Use \(suggestion.indexName)", systemImage: "bolt") {
                        session.statement = suggestion.rewritten
                    }
                    .help("FROM \"\(tableName)\" → FROM \"\(tableName)\".\"\(suggestion.indexName)\" (SELECT * then returns the index's projected attributes)")
                }
                .padding(8)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            } else if let info = session.info {
                Text(info).font(.caption).foregroundStyle(.green)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
    }
}

/// Plain grid for result sets that aren't backed by the table's key schema
/// (PartiQL projections) - no edit/delete actions, local filtering only.
struct DdbReadOnlyGrid: View {
    let items: [[String: DdbAttributeValue]]
    var onDoubleTapRow: (([String: DdbAttributeValue]) -> Void)?

    private struct Row: Identifiable {
        let id: Int
        let item: [String: DdbAttributeValue]
    }

    var body: some View {
        let keys = Array(Set(items.flatMap { $0.keys })).sorted()
        let columns = keys.map { DataGridColumn(id: $0, title: $0, minWidth: 120, maxWidth: 280) }
        let rows = items.enumerated().map { Row(id: $0.offset, item: $0.element) }
        DataGridView(
            columns: columns,
            rows: rows,
            autoFitColumns: true,
            cell: { row, column in
                Text(row.item[column.id]?.value.displayString ?? "")
                    .font(.system(size: 12.5))
                    .lineLimit(1)
            },
            onDoubleTapRow: onDoubleTapRow.map { open in { row in open(row.item) } },
            filterValue: { row, column in row.item[column.id]?.value.displayString }
        )
    }
}

// MARK: - CSV export

/// The console's "Download results to CSV": one column per attribute seen
/// in the results, nested maps/lists written as JSON.
enum DynamoCSV {
    static func csv(_ items: [[String: DdbAttributeValue]], keyOrder: [String] = []) -> String {
        let all = Set(items.flatMap { $0.keys })
        let columns = keyOrder.filter(all.contains) + all.subtracting(keyOrder).sorted()
        var lines = [columns.map(escape).joined(separator: ",")]
        for item in items {
            lines.append(columns.map { escape(cell(item[$0]?.value)) }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func save(_ items: [[String: DdbAttributeValue]], suggestedName: String, keyOrder: [String] = []) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(suggestedName).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv(items, keyOrder: keyOrder).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func cell(_ value: AnyCodableValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .array, .object:
            let data = try? JSONSerialization.data(withJSONObject: value.jsonValue, options: [.sortedKeys, .withoutEscapingSlashes])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        default:
            return value.displayString
        }
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: - Create table

struct DdbCreateTableSheet: View {
    var onCreated: (String) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var tableName = ""
    @State private var pkName = ""
    @State private var pkType = "S"
    @State private var useSortKey = false
    @State private var skName = ""
    @State private var skType = "S"
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create table").font(.title3.bold())
            TextField("Table name", text: $tableName)
                .textFieldStyle(.roundedBorder)
            keyRow("Partition key", name: $pkName, type: $pkType)
            Toggle("Add a sort key", isOn: $useSortKey)
            if useSortKey {
                keyRow("Sort key", name: $skName, type: $skType)
            }
            Text("Created with on-demand capacity (pay per request) and default encryption - the console's default settings. Indexes, streams and TTL can be added afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                SecondaryButton("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                NewButton("Create Table", isLoading: isCreating, isDisabled: !isValid) {
                    Task { await create() }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var isValid: Bool {
        !tableName.trimmingCharacters(in: .whitespaces).isEmpty
            && !pkName.trimmingCharacters(in: .whitespaces).isEmpty
            && (!useSortKey || !skName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func keyRow(_ title: String, name: Binding<String>, type: Binding<String>) -> some View {
        HStack(spacing: 8) {
            TextField(title, text: name)
                .textFieldStyle(.roundedBorder)
            Picker("", selection: type) {
                Text("String").tag("S")
                Text("Number").tag("N")
                Text("Binary").tag("B")
            }
            .labelsHidden()
            .frame(width: 110)
        }
    }

    private func create() async {
        isCreating = true
        error = nil
        do {
            let name = tableName.trimmingCharacters(in: .whitespaces)
            _ = try await api.createDynamoDBTable(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                tableName: name,
                partitionKey: (pkName.trimmingCharacters(in: .whitespaces), pkType),
                sortKey: useSortKey ? (skName.trimmingCharacters(in: .whitespaces), skType) : nil
            )
            onCreated(name)
            dismiss()
        } catch {
            self.error = error.friendlyMessage
        }
        isCreating = false
    }
}
