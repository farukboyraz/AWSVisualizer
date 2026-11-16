import SwiftUI

struct DynamoScanData {
    let info: DdbTableInfo?
    let items: [[String: DdbAttributeValue]]
}

private enum ItemSheetMode {
    case view    // starts read-only, can toggle to Edit; Save overwrites this item
    case create  // starts blank and editable; Save creates a new item
    case clone   // starts prefilled and editable; Save creates a new item (own key)
}

/// Identity wrapper so the item sheet uses `.sheet(item:)` instead of a
/// separately-tracked `isPresented` bool + optional item - with the latter,
/// the sheet's content closure could occasionally run before the item
/// state had actually landed, showing a blank popup the first time you
/// opened one after switching tables. `.sheet(item:)` only ever presents
/// once the wrapped value is non-nil, so the item is always there.
private struct ItemSheetTarget: Identifiable {
    let id = UUID()
    let item: [String: DdbAttributeValue]?
    let mode: ItemSheetMode
}

/// Wraps a scanned item with a stable, position-based identity for
/// `DataGridView`'s `ForEach` - mirrors the previous `id: \.offset` used
/// directly on the raw items array.
private struct DynamoRow: Identifiable {
    let id: Int
    let item: [String: DdbAttributeValue]
}

struct DynamoDBView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var tablesState: LoadState<[String]> = .loading
    @State private var selectedTableName: String?
    @State private var tableInfo: DdbTableInfo?
    @State private var scanState: LoadState<DynamoScanData> = .empty
    @State private var sheetTarget: ItemSheetTarget?
    /// The item a context-menu "Delete Item" is pending confirmation for -
    /// context menu rows can't host an `AppButton` (they need plain menu
    /// items, not colored pills), so this path gets its own
    /// `.confirmationDialog` instead of the one `DeleteButton()`
    /// bakes in automatically.
    @State private var pendingDeleteItem: [String: DdbAttributeValue]?

    private let pageSize = 25
    /// `pageStartKeys[i]` is the `ExclusiveStartKey` that produced page `i`
    /// (page 0's is always nil) - a growing stack rather than a single
    /// cursor, so "Previous" can go back without re-scanning from page 0.
    @State private var pageStartKeys: [[String: Any]?] = [nil]
    @State private var currentPage = 0
    @State private var hasNextPage = false

    // Whole-table search (Filter Builder). While `searchConditions` is
    // non-empty the grid shows server-side search results instead of the
    // current scan page - the builder used to filter only the 25 rows on
    // screen, so matches on any other page were silently missed.
    @State private var searchConditions: [FilterCondition] = []
    @State private var searchItems: [[String: DdbAttributeValue]] = []
    @State private var searchScannedCount = 0
    /// Resume token of the server's parallel scan; nil before the first
    /// step and after the last one (`searchFinished` tells them apart).
    @State private var searchCursor: String?
    @State private var searchFinished = false
    @State private var isSearching = false
    /// Time spent actually searching (not waiting for the user to scroll).
    @State private var searchStopwatch = QueryStopwatch()
    @State private var isSearchStopped = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    /// The search keeps stepping on its own until it has this many matches
    /// (or the table ends); scrolling near the bottom of the results raises
    /// it - infinite scrolling instead of "Keep searching" / "Load more".
    @State private var searchTarget = 0
    @State private var searchSegments = 1
    @State private var searchRoute: DdbSearchRoute?
    /// Bumped on every new search / clear so a slow in-flight response from
    /// an older search can't overwrite the newer one's results.
    @State private var searchGeneration = 0
    /// Attribute names of the last scanned page - keeps the grid's columns
    /// (and so the filter popover's column picker) when a search has few or
    /// no matches to derive columns from.
    @State private var pageColumnKeys: [String] = []
    /// Every attribute name of the table (sparse ones too) for the Filter Builder.
    @State private var tableAttributeNames: [String] = []

    @State private var tableTab: DynamoTableTab = .items
    /// PartiQL console docked under the Items grid; its results replace the
    /// Scan/Query rows in that grid until cleared.
    @State private var partiql = PartiQLSession()
    @State private var showPartiQL = false
    /// The Query form, docked under the items like the PartiQL console
    /// (there's no separate Query tab - a Filter Builder search on a key
    /// attribute already runs as a Query; this is for sort key ranges,
    /// begins_with, index choice and sort order).
    @State private var showQueryPanel = false
    @State private var showCreateTable = false

    // Items → Query (the console's "Explore items → Query"): partition key
    // equality + optional sort key condition, on the table or an index.
    private enum ItemsMode: String, CaseIterable { case scan = "Scan", query = "Query" }
    @State private var itemsMode: ItemsMode = .scan
    /// nil = the table itself.
    @State private var queryIndexName: String?
    @State private var queryPKValue = ""
    @State private var querySKOperator = "none"
    @State private var querySKValue = ""
    @State private var querySKValue2 = ""
    @State private var queryAscending = true
    @State private var queryItems: [[String: DdbAttributeValue]] = []
    @State private var queryNextKey: [String: Any]?
    @State private var queryScannedCount = 0
    /// Rows shown (100, +100 per Load More, `.max` during Load All).
    @State private var queryShownLimit = 100
    @State private var queryLoadingAll = false
    @State private var isQuerying = false
    @State private var queryError: String?
    @State private var queryHasRun = false
    /// Filter Builder conditions on the query results - sent to the server,
    /// which applies them to the whole partition (not just loaded rows).
    @State private var queryConditions: [FilterCondition] = []
    @State private var queryGeneration = 0
    @State private var queryStopwatch = QueryStopwatch()
    private let queryPageSize = 100
    private let searchBatchSize = 100

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 220, minWidth: 180, maxWidth: 500, isDetailActive: selectedTableName != nil, onBack: { selectedTableName = nil }, backTitle: "Tables", detailTitle: selectedTableName) {
                tableListSection
            } detail: {
                tablePanel
            }
            .sheet(isPresented: $showCreateTable) {
                DdbCreateTableSheet { name in
                    Task {
                        await loadTables()
                        selectedTableName = name
                    }
                }
            }
            .sheet(item: $sheetTarget) { target in
                if let selectedTableName {
                    DynamoItemSheet(
                        tableName: selectedTableName,
                        keySchema: tableInfo?.keySchema ?? [],
                        attributeDefinitions: tableInfo?.attributeDefinitions ?? [],
                        item: target.item,
                        mode: target.mode,
                        onSaved: { Task { await refreshAfterMutation() } },
                        onClose: { sheetTarget = nil }
                    )
                }
            }
            .confirmationDialog(
                appState.language.deleteConfirmationTitle,
                isPresented: Binding(
                    get: { pendingDeleteItem != nil },
                    set: { if !$0 { pendingDeleteItem = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(appState.language.yesButtonTitle, role: .destructive) {
                    if let pendingDeleteItem { Task { await deleteItem(pendingDeleteItem) } }
                }
                Button(appState.language.noButtonTitle, role: .cancel) {}
            } message: {
                Text(appState.language.deleteConfirmationMessage)
            }
        }
        .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
            await loadTables()
        }
    }

    private var tableListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("DynamoDB Tables")
            LoadableContent(tablesState, retry: { Task { await loadTables() } }) { tableNames in
                List(tableNames, id: \.self, selection: $selectedTableName) { name in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .font(.body.bold())
                        if let info = tableInfo, info.tableName == name {
                            HStack {
                                if let status = info.tableStatus {
                                    StatusBadge(status)
                                }
                                if let count = info.itemCount {
                                    Text("\(count) items")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let size = info.tableSizeBytes {
                                    Text(Formatters.formatBytes(size))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(name)
                }
                .onChange(of: selectedTableName) { _, newValue in
                    if let name = newValue {
                        Task { await loadTableDetails(name) }
                    }
                }
            }
            PanelActionBar {
                NewButton(compactSize: 24, help: "Create Table") { showCreateTable = true }
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadTables() } }
            }
        }
    }

    /// Right side: the selected table's page, with the console's tabs.
    @ViewBuilder
    private var tablePanel: some View {
        if let selectedTableName {
            VStack(alignment: .leading, spacing: 0) {
                Text(selectedTableName)
                    .font(.title3.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                // Smaller and higher than the other screens' tabs, with room
                // below - so the strip doesn't run into the grid's column headers.
                TabBar(selection: $tableTab, height: 28, icon: { $0.systemImage })
                    .padding(.bottom, 4)

                Group {
                    switch tableTab {
                    case .items: scanViewSection
                    case .overview:
                        DdbOverviewTab(tableName: selectedTableName, onDeleted: {
                            self.selectedTableName = nil
                            tableInfo = nil
                            tableTab = .items
                            Task { await loadTables() }
                        })
                    case .indexes: DdbIndexesTab(tableName: selectedTableName)
                    case .monitor: DdbMonitorTab(tableName: selectedTableName)
                    case .backups: DdbBackupsTab(tableName: selectedTableName)
                    case .tags: DdbTagsTab(tableName: selectedTableName)
                    }
                }
                .id(selectedTableName)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            EmptyStateView(message: "Select a table")
        }
    }

    private var scanViewSection: some View {
        VStack(spacing: 0) {
            itemsGridSection
            if showQueryPanel {
                Divider()
                queryForm
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.05))
            }
            if showPartiQL, let selectedTableName {
                Divider()
                DdbPartiQLConsole(
                    tableName: selectedTableName,
                    tableKeySchema: tableInfo?.keySchema ?? [],
                    indexes: tableInfo?.indexes ?? [],
                    session: partiql
                )
            }
        }
    }

    /// PartiQL results in the Items grid - the same grid as Scan (Edit /
    /// Clone on each row, double-click opens the item popup); 100 rows at a
    /// time with Load More / Load All.
    private var partiqlResultsSection: some View {
        VStack(spacing: 0) {
            if !partiql.items.isEmpty {
                scanResultsView(partiql.shownItems, source: .partiql)
            } else if partiql.isRunning {
                BrandedLoader(message: "Running PartiQL…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(message: partiql.error == nil ? "No items returned" : "The statement failed - see the console below")
            }
            Divider()
            HStack(spacing: 10) {
                bottomLeadingButtons
                ResultCountLabel(count: partiql.shownItems.count, singular: "item", plural: "items", detail: partiqlDetail)
                if partiql.isRunning { ProgressView().controlSize(.small) }
                ElapsedTimeLabel(stopwatch: partiql.stopwatch)
                Spacer(minLength: 0)
                loadMoreControls(
                    hasMore: partiql.hasMore,
                    isLoading: partiql.isRunning,
                    onMore: { Task { await partiql.loadMore(api: api, profile: appState.currentProfile, region: appState.currentRegion) } },
                    onAll: { Task { await partiql.loadAll(api: api, profile: appState.currentProfile, region: appState.currentRegion) } },
                    onStop: { partiql.stop() }
                )
                closeResultsButton(help: "Close the PartiQL results and show the \(itemsMode == .query ? "Query results" : "scanned items") again") {
                    partiql.clearResults()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    /// Tooltip of the PartiQL bar's count. ExecuteStatement doesn't report
    /// how many items it read, only what it returned.
    private var partiqlDetail: String {
        let shown = partiql.shownItems.count, read = partiql.items.count
        var text = "\(shown) item\(shown == 1 ? "" : "s") shown"
        text += read > shown ? " of \(read) already read by PartiQL." : " - returned by PartiQL."
        if partiql.isRunning { return text + (partiql.isLoadingAll ? "\nLoading everything that's left…" : "\nReading…") }
        if partiql.nextToken != nil { return text + "\nMore left in DynamoDB - Load More / Load All continue where this stopped." }
        return text + (read > shown ? "" : "\nEverything the statement selects has been read.")
    }

    private var itemsGridSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if partiql.hasResults {
                partiqlResultsSection
            } else if itemsMode == .query {
                querySection
            } else if !searchConditions.isEmpty {
                searchResultsSection
            } else {
                LoadableContent(scanState, retry: nil, emptyMessage: scanEmptyMessage) { data in
                    scanResultsView(data.items)
                }

                // Also shown for an empty table, so New Item (bottom-left)
                // is always reachable.
                if selectedTableName != nil, scanState.isSettled {
                    Divider()
                    paginationBar
                }
            }
        }
    }

    private var scanEmptyMessage: String {
        selectedTableName == nil ? "Select a table to scan" : "No items found"
    }

    private let actionsColumnWidth: CGFloat = 52
    private let minColumnWidth: CGFloat = 120
    private let maxColumnWidth: CGFloat = 280

    /// Builds the shared `DataGridView` from this page's items - columns
    /// come from the union of attribute names across the page (sorted for a
    /// stable order), each individually resizable, and (when
    /// `dynamoDbAutoColumnWidth` is on) auto-sized to fit its content.
    /// Which result set a grid shows - decides where its Filter Builder
    /// goes (whole-table search, re-run the Query, or just the rows loaded).
    private enum GridSource: String { case scan, search, query, partiql }

    private func scanResultsView(_ items: [[String: DdbAttributeValue]], source: GridSource = .scan) -> some View {
        let isQuery = source == .query
        let inSearch = source == .search
        var keySet = Set(items.flatMap { $0.keys })
        if isQuery { keySet.formUnion(queryConditions.map(\.columnID)) }
        if inSearch {
            keySet.formUnion(pageColumnKeys)
            keySet.formUnion(searchConditions.map(\.columnID))
        }
        let allKeys = Array(keySet).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let columns = allKeys.map { key in
            DataGridColumn(id: key, title: key, minWidth: minColumnWidth, maxWidth: maxColumnWidth)
        }
        let rows = items.enumerated().map { DynamoRow(id: $0.offset, item: $0.element) }
        return DataGridView(
            columns: columns,
            rows: rows,
            actionsColumnWidth: actionsColumnWidth,
            autoFitColumns: appState.dynamoDbAutoColumnWidth,
            cell: { row, column in
                Text(row.item[column.id]?.value.displayString ?? "")
                    .font(.system(size: 12.5))
                    .lineLimit(1)
            },
            rowActions: { row in AnyView(rowActions(row.item)) },
            onDoubleTapRow: { row in
                sheetTarget = ItemSheetTarget(item: row.item, mode: .view)
            },
            contextMenu: { row in AnyView(rowContextMenu(row.item)) },
            filterValue: { row, column in row.item[column.id]?.value.displayString },
            // In Query mode the filter re-runs the query with the conditions
            // applied server-side to the whole partition; PartiQL results
            // are filtered where they are (the rows loaded). More rows come
            // from Load More / Load All in the bottom bar, not from scrolling.
            onFilterApplied: source == .partiql ? nil : (isQuery ? { conditions in applyQueryFilter(conditions) } : { conditions in applyFilter(conditions) }),
            initialFilterConditions: source == .partiql ? [] : (isQuery ? queryConditions : searchConditions),
            onSearchWithPartiQL: source == .partiql ? nil : { conditions in searchWithPartiQL(conditions, fromQuery: isQuery, items: items) },
            // Attributes no row on screen has can still be filtered on.
            extraFilterColumnIDs: tableAttributeNames
        )
        // `DataGridView` owns column widths and filter conditions in its own
        // @State now (see its doc comment) - forcing a fresh identity per
        // table is how both get reset when the table changes, since a
        // different table's columns may not even include the ones a stale
        // width/filter referenced.
        .id("\(selectedTableName ?? "")|\(source.rawValue)")
    }

    private func rowContextMenu(_ item: [String: DdbAttributeValue]) -> some View {
        Group {
            Button("Edit Item") {
                sheetTarget = ItemSheetTarget(item: item, mode: .view)
            }
            Button("Clone Item") {
                sheetTarget = ItemSheetTarget(item: item, mode: .clone)
            }
            Button("Delete Item", role: .destructive) {
                pendingDeleteItem = item
            }
        }
    }

    /// Pencil = edit this item in place, doc-on-doc = open the same data
    /// pre-filled but saved as a brand new item (for near-duplicate rows
    /// that only differ in a couple of fields).
    private func rowActions(_ item: [String: DdbAttributeValue]) -> some View {
        HStack(spacing: 5) {
            EditButton(compactSize: 20, help: "Edit Item") {
                sheetTarget = ItemSheetTarget(item: item, mode: .view)
            }
            CloneButton(compactSize: 20, help: "Clone Item") {
                sheetTarget = ItemSheetTarget(item: item, mode: .clone)
            }
        }
    }

    private func loadTables() async {
        tablesState = .loading
        do {
            let tableNames = try await api.getDynamoDBTables(profile: appState.currentProfile, region: appState.currentRegion)
            tablesState = tableNames.isEmpty ? .empty : .loaded(tableNames)
            // A dashboard card asked for one table (the list is new, so its onChange doesn't fire).
            if let link = appState.takeDeepLink(for: "dynamodb"), let name = link.resource, tableNames.contains(name) {
                selectedTableName = name
                await loadTableDetails(name)
                if let search = link.query { await runCardSearch(search) }
            }
        } catch {
            tablesState = .failed(error.localizedDescription)
        }
    }

    private func loadTableDetails(_ name: String) async {
        resetSearch()
        resetQuery()
        tableTab = .items
        partiql.reset(tableName: name)
        pageColumnKeys = []
        pageStartKeys = [nil]
        tableAttributeNames = []
        // In the background - the grid doesn't wait for it.
        Task {
            let names = (try? await api.getDynamoDBAttributeNames(profile: appState.currentProfile, region: appState.currentRegion, tableName: name)) ?? []
            if selectedTableName == name { tableAttributeNames = names }
        }
        do {
            tableInfo = try await api.getDynamoDBTable(profile: appState.currentProfile, region: appState.currentRegion, tableName: name)
        } catch {
            tableInfo = nil
        }
        await loadPage(0)
    }

    /// Fetches `pageSize + 1` items so a full page can tell "there's more"
    /// from a real peeked-at item rather than trusting `lastEvaluatedKey`'s
    /// mere presence - DynamoDB can return that even when nothing is left,
    /// whenever the scan stopped early for any reason other than actually
    /// running out of items. The (unshown) extra item's own primary key
    /// becomes the next page's `ExclusiveStartKey`, computed once per page
    /// and cached in `pageStartKeys` so "Previous" never re-scans.
    private func loadPage(_ pageIndex: Int) async {
        guard let selectedTableName, pageIndex < pageStartKeys.count else { return }
        scanState = .loading
        do {
            let scan = try await api.scanDynamoDBTable(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                tableName: selectedTableName,
                limit: pageSize + 1,
                startKey: pageStartKeys[pageIndex]
            )
            var items = scan.items ?? []
            let more = items.count > pageSize
            if more { items = Array(items.prefix(pageSize)) }

            if more, pageStartKeys.count == pageIndex + 1, let keySchema = tableInfo?.keySchema, let lastItem = items.last {
                pageStartKeys.append(primaryKey(from: lastItem, keySchema: keySchema))
            }
            currentPage = pageIndex
            hasNextPage = more
            if !items.isEmpty {
                pageColumnKeys = Array(Set(items.flatMap { $0.keys })).sorted()
            }
            scanState = items.isEmpty ? .empty : .loaded(DynamoScanData(info: tableInfo, items: items))
        } catch {
            scanState = .failed(error.localizedDescription)
        }
    }

    /// Total pages is an *estimate* from `DescribeTable`'s `itemCount`
    /// (itself a periodic AWS estimate, not a live count) - good enough for
    /// "roughly how many pages" but not something to treat as exact.
    private var estimatedTotalPages: Int? {
        guard let itemCount = tableInfo?.itemCount, itemCount > 0 else { return nil }
        return max(1, Int((Double(itemCount) / Double(pageSize)).rounded(.up)))
    }

    /// Page buttons for numbers actually reachable without a fresh scan
    /// (their `ExclusiveStartKey` is already cached in `pageStartKeys`),
    /// windowed to page 1, the last reachable page, and the immediate
    /// neighborhood of the current page - avoids a wall of buttons once
    /// someone has paged deep into a big table.
    private var visiblePageNumbers: [Int] {
        let current = currentPage + 1
        let lastReachable = pageStartKeys.count
        var pages: Set<Int> = [1, lastReachable]
        for p in (current - 1)...(current + 1) where p >= 1 && p <= lastReachable {
            pages.insert(p)
        }
        return pages.sorted()
    }

    /// Bottom-left of the Scan / search / Query bars: New Item + PartiQL.
    private var bottomLeadingButtons: some View {
        HStack(spacing: 10) {
            DownloadButton(compactSize: 28, isDisabled: currentItems.isEmpty, help: "Download CSV - the items currently shown (this page / the rows loaded so far)") {
                DynamoCSV.save(currentItems, suggestedName: selectedTableName ?? "items", keyOrder: tableKeyOrder)
            }
            newItemButton
            SecondaryButton("Query", systemImage: showQueryPanel ? "bolt.fill" : "bolt") {
                showQueryPanel.toggle()
                if showQueryPanel { showPartiQL = false }
            }
            .help(showQueryPanel ? "Hide the Query form" : "Open the Query form below the items - partition key + sort key range / begins_with, on the table or an index")
            SecondaryButton("PartiQL", systemImage: showPartiQL ? "terminal.fill" : "terminal") {
                showPartiQL.toggle()
                if showPartiQL { showQueryPanel = false }
            }
                .help(showPartiQL ? "Hide the PartiQL console" : "Open the PartiQL console below the items")
            if showPartiQL, let selectedTableName {
                DdbPartiQLRunControls(
                    tableName: selectedTableName,
                    tableKeySchema: tableInfo?.keySchema ?? [],
                    indexes: tableInfo?.indexes ?? [],
                    session: partiql
                )
            }
        }
        // Buttons keep their full labels; the counts/status next to them
        // give way instead.
        .fixedSize()
    }

    /// Load More (next 100 under the rows shown) and Load All (everything
    /// left, appended as it arrives) - both continue where the last read
    /// stopped; Stop while loading. Shared by search, Query and PartiQL.
    private func loadMoreControls(hasMore: Bool, isLoading: Bool, onMore: @escaping () -> Void, onAll: @escaping () -> Void, onStop: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if isLoading {
                StopButton("Stop", help: "Stop loading - the rows found so far stay") { onStop() }
            } else if hasMore {
                SecondaryButton("Load More", systemImage: "arrow.down.circle", help: "Load the next 100 rows under these") { onMore() }
                SecondaryButton("Load All", systemImage: "arrow.down.to.line.circle", help: "Load every remaining row - they appear as they're found") { onAll() }
            }
        }
        .fixedSize()
    }

    /// The ✕ that leaves a results view (PartiQL / Query / search).
    private func closeResultsButton(help: String, action: @escaping () -> Void) -> some View {
        CloseButton(compactSize: 26, help: help, action: action)
            .fixedSize()
    }

    /// Bottom-left of every Items bottom bar (scan / search / query / PartiQL).
    private var newItemButton: some View {
        NewButton(compactSize: 28, help: "New Item") {
            sheetTarget = ItemSheetTarget(item: nil, mode: .create)
        }
    }

    /// New Item on the left; item count / page count sit right next to the
    /// page numbers on the right, so all paging information reads as one group.
    private var paginationBar: some View {
        HStack(spacing: 12) {
            bottomLeadingButtons
            Spacer()
            if let itemCount = tableInfo?.itemCount {
                Text(estimatedTotalPages.map { "\(itemCount) items · \($0) page\($0 == 1 ? "" : "s")" } ?? "\(itemCount) items")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .monospacedDigit()
                    .help("Approximate - DynamoDB refreshes the item count about every 6 hours")
            }
            HStack(spacing: 6) {
                if currentPage > 0 {
                    pageArrowButton(systemName: "chevron.left") {
                        Task { await loadPage(currentPage - 1) }
                    }
                }
                let pages = visiblePageNumbers
                ForEach(Array(pages.enumerated()), id: \.offset) { idx, page in
                    if idx > 0, page - pages[idx - 1] > 1 {
                        Text("…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    pageNumberButton(page)
                }
                if hasNextPage, let estimatedTotalPages, estimatedTotalPages > pageStartKeys.count {
                    Text("…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("\(estimatedTotalPages)")
                        .font(.system(size: 12))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(.tertiary)
                        .background(Color.secondary.opacity(0.08), in: Circle())
                }
                pageArrowButton(systemName: "chevron.right", enabled: hasNextPage) {
                    Task { await loadPage(currentPage + 1) }
                }
            }
        }
        .padding()
    }

    private func pageNumberButton(_ page: Int) -> some View {
        let isActive = page == currentPage + 1
        return Button {
            Task { await loadPage(page - 1) }
        } label: {
            Text("\(page)")
                .font(.system(size: 12, weight: isActive ? .bold : .regular))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .background(isActive ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
    }

    private func pageArrowButton(systemName: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.3))
        .background(Color.secondary.opacity(0.1), in: Circle())
        .disabled(!enabled)
    }

    // MARK: - Query

    /// Items currently on screen in the Items tab (for CSV export).
    private var currentItems: [[String: DdbAttributeValue]] {
        if partiql.hasResults { return partiql.shownItems }
        if itemsMode == .query { return queryShownItems }
        if !searchConditions.isEmpty { return searchShownItems }
        if case .loaded(let data) = scanState { return data.items }
        return []
    }

    private var tableKeyOrder: [String] {
        (tableInfo?.keySchema ?? []).sorted { $0.keyType == "HASH" && $1.keyType != "HASH" }.map(\.attributeName)
    }

    /// Key schema of the table or of the selected index.
    private var queryKeySchema: [DdbKeySchemaElement] {
        if let queryIndexName, let index = tableInfo?.indexes?.first(where: { $0.indexName == queryIndexName }) {
            return index.keySchema
        }
        return tableInfo?.keySchema ?? []
    }

    private func attributeType(_ name: String) -> String {
        tableInfo?.attributeDefinitions?.first { $0.attributeName == name }?.attributeType ?? "S"
    }

    private var queryPartitionKey: String? { queryKeySchema.first { $0.keyType == "HASH" }?.attributeName }
    private var querySortKey: String? { queryKeySchema.first { $0.keyType == "RANGE" }?.attributeName }

    private var querySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let queryError {
                Text(queryError).font(.caption).foregroundStyle(.red).padding()
            }
            if isQuerying && queryItems.isEmpty {
                BrandedLoader(message: "Querying…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if queryHasRun {
                if queryItems.isEmpty {
                    EmptyStateView(message: queryConditions.isEmpty ? "No items match this key condition" : "No items in this partition match the filter")
                } else {
                    scanResultsView(queryShownItems, source: .query)
                }
            } else {
                EmptyStateView(message: "Enter a partition key value in the Query form below and run it")
            }
            Divider()
            HStack(spacing: 10) {
                bottomLeadingButtons
                Spacer()
                if queryHasRun {
                    ResultCountLabel(count: queryItems.count, singular: "item", plural: "items", detail: queryDetail)
                    ElapsedTimeLabel(stopwatch: queryStopwatch)
                }
                if isQuerying { ProgressView().controlSize(.small) }
                if queryHasRun {
                    loadMoreControls(
                        hasMore: queryHasMore,
                        isLoading: isQuerying,
                        onMore: { Task { await queryLoadMore() } },
                        onAll: { Task { await queryLoadAll() } },
                        onStop: { stopQueryLoading() }
                    )
                }
                closeResultsButton(help: "Close the Query results and show the scanned items again (the form keeps its values)") {
                    exitQuery()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var queryForm: some View {
        let skType = querySortKey.map(attributeType) ?? "S"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Table or index").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $queryIndexName) {
                    Text("Table - \(selectedTableName ?? "")").tag(String?.none)
                    ForEach(tableInfo?.indexes ?? []) { index in
                        Text("\(index.indexType) - \(index.indexName)").tag(Optional(index.indexName))
                    }
                }
                .labelsHidden()
                .frame(width: 280)
                .onChange(of: queryIndexName) { _, _ in
                    querySKOperator = "none"
                    querySKValue = ""
                    querySKValue2 = ""
                }
                Spacer()
                Picker("", selection: $queryAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .help("Sort order by sort key")
            }
            if let pk = queryPartitionKey {
                HStack(spacing: 8) {
                    Text("\(pk) (\(attributeType(pk)))")
                        .font(.caption.monospaced().bold())
                        .frame(width: 200, alignment: .leading)
                    Text("=").font(.caption.bold())
                    TextField("Partition key value", text: $queryPKValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await runQuery(more: false) } }
                }
            }
            if let sk = querySortKey {
                HStack(spacing: 8) {
                    Text("\(sk) (\(skType))")
                        .font(.caption.monospaced().bold())
                        .frame(width: 200, alignment: .leading)
                    Picker("", selection: $querySKOperator) {
                        Text("any").tag("none")
                        Text("=").tag("=")
                        Text("<").tag("<")
                        Text("≤").tag("<=")
                        Text(">").tag(">")
                        Text("≥").tag(">=")
                        Text("between").tag("between")
                        if skType != "N" { Text("begins with").tag("begins_with") }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    if querySKOperator != "none" {
                        TextField("Sort key value", text: $querySKValue)
                            .textFieldStyle(.roundedBorder)
                        if querySKOperator == "between" {
                            Text("and").font(.caption)
                            TextField("upper bound", text: $querySKValue2)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            HStack {
                Text("Reads only the matching partition - cheaper and faster than a scan.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                RunButton("Run", isLoading: isQuerying, isDisabled: queryPartitionKey == nil || queryPKValue.isEmpty) {
                    Task { await runQuery(more: false) }
                }
            }
        }
    }

    private func runQuery(more: Bool, keepGeneration: Bool = false) async {
        guard let selectedTableName, let pk = queryPartitionKey else { return }
        if more && (queryNextKey == nil || isQuerying) { return }
        if !keepGeneration { queryGeneration += 1 }
        let generation = queryGeneration
        if !more {
            partiql.clearResults()
            itemsMode = .query
            queryShownLimit = queryPageSize
            queryLoadingAll = false
        }
        isQuerying = true
        queryStopwatch.start(reset: !more)
        queryError = nil
        let sk: (name: String, type: String, operator: String, value: String, value2: String)? =
            querySortKey.flatMap { name in querySKOperator == "none" ? nil : (name, attributeType(name), querySKOperator, querySKValue, querySKValue2) }
        do {
            let page = try await api.queryDynamoDBTable(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                tableName: selectedTableName,
                indexName: queryIndexName,
                partitionKey: (pk, attributeType(pk), queryPKValue),
                sortKey: sk,
                ascending: queryAscending,
                limit: queryShownLimit == .max ? 1000 : max(queryShownLimit - (more ? queryItems.count : 0), 1),
                startKey: more ? queryNextKey : nil,
                conditions: queryConditions
            )
            // A newer run (filter changed, re-run) supersedes this one.
            guard generation == queryGeneration else { return }
            queryItems = more ? queryItems + page.items : page.items
            queryScannedCount = (more ? queryScannedCount : 0) + (page.scannedCount ?? page.items.count)
            queryNextKey = page.lastEvaluatedKey?.mapValues { $0.value.jsonValue }
            queryHasRun = true
        } catch {
            guard generation == queryGeneration else { return }
            queryError = error.friendlyMessage
            if !more { queryItems = []; queryNextKey = nil; queryHasRun = true }
        }
        guard generation == queryGeneration else { return }
        queryStopwatch.stop()
        isQuerying = false
    }

    /// Filter Builder → PartiQL console (results in the grid). From Query mode the key condition (and
    /// index) comes along, so PartiQL reads the same partition instead of
    /// scanning the table. Number/boolean columns (judged from the loaded
    /// rows) get unquoted literals - PartiQL comparisons are typed.
    private func searchWithPartiQL(_ conditions: [FilterCondition], fromQuery: Bool, items: [[String: DdbAttributeValue]]) {
        guard let selectedTableName else { return }
        var key: PartiQLFilterBuilder.KeyCondition?
        if fromQuery, let pk = queryPartitionKey, !queryPKValue.isEmpty {
            key = .init(
                indexName: queryIndexName,
                partitionKey: (pk, attributeType(pk), queryPKValue),
                sortKey: querySortKey.flatMap { name in querySKOperator == "none" ? nil : (name, attributeType(name), querySKOperator, querySKValue, querySKValue2) }
            )
        }
        let statement = PartiQLFilterBuilder.statement(tableName: selectedTableName, conditions: conditions, key: key) { column in
            let values = items.compactMap { $0[column]?.value }
            guard !values.isEmpty else { return .string }
            if values.allSatisfy({ if case .integer = $0 { return true }; if case .number = $0 { return true }; return false }) { return .number }
            if values.allSatisfy({ if case .bool = $0 { return true }; return false }) { return .bool }
            return .string
        }
        partiql.statement = statement
        showPartiQL = true
        let keySchema = tableInfo?.keySchema ?? [], indexes = tableInfo?.indexes ?? []
        Task {
            await partiql.run(api: api, profile: appState.currentProfile, region: appState.currentRegion) {
                PartiQLIndexAdvisor.suggest(statement: $0, tableName: selectedTableName, tableKeySchema: keySchema, indexes: indexes)
            }
        }
    }

    private var queryShownItems: [[String: DdbAttributeValue]] {
        queryItems.count > queryShownLimit ? Array(queryItems.prefix(queryShownLimit)) : queryItems
    }

    private var queryHasMore: Bool { queryItems.count > queryShownLimit || queryNextKey != nil }

    /// Tooltip of the Query bar's count.
    private var queryDetail: String {
        var text = queryConditions.isEmpty
            ? "\(queryItems.count) item\(queryItems.count == 1 ? "" : "s") read from the partition."
            : "\(queryItems.count) of \(queryScannedCount) items read from the partition matched the filter."
        if queryItems.count > queryShownItems.count {
            text += "\n\(queryShownItems.count) shown, \(queryItems.count - queryShownItems.count) more already read."
        }
        text += queryNextKey != nil ? "\nMore of the partition is left - Load More / Load All continue from here." : "\nWhole partition read."
        return text
    }

    /// Next 100 under the rows shown - already-read rows first, then the
    /// Query continues from its LastEvaluatedKey.
    private func queryLoadMore() async {
        guard !isQuerying else { return }
        queryShownLimit = min(queryShownLimit, queryItems.count) + queryPageSize
        while queryItems.count < queryShownLimit, queryNextKey != nil, queryError == nil {
            let before = queryItems.count
            await runQuery(more: true)
            if queryItems.count == before && queryNextKey == nil { break }
        }
    }

    /// The rest of the partition, appended as each call returns.
    private func queryLoadAll() async {
        guard !isQuerying else { return }
        queryShownLimit = .max
        queryLoadingAll = true
        let generation = queryGeneration
        while queryLoadingAll, queryNextKey != nil, queryError == nil, generation == queryGeneration {
            await runQuery(more: true, keepGeneration: true)
        }
        queryLoadingAll = false
        if queryShownLimit == .max { queryShownLimit = queryItems.count }
    }

    private func stopQueryLoading() {
        queryLoadingAll = false
        queryGeneration += 1
        isQuerying = false
        queryStopwatch.stop()
        if queryShownLimit == .max { queryShownLimit = queryItems.count }
    }

    private func applyQueryFilter(_ conditions: [FilterCondition]) {
        queryConditions = conditions
        Task { await runQuery(more: false) }
    }

    /// Back to Scan (or the active search) - results go, the form stays.
    private func exitQuery() {
        queryGeneration += 1
        itemsMode = .scan
        queryConditions = []
        queryItems = []
        queryNextKey = nil
        queryError = nil
        queryHasRun = false
        isQuerying = false
        queryStopwatch = QueryStopwatch()
    }

    /// A dashboard search card's Run: the same search, the way the card
    /// built it -
    /// - query: the Query form filled (index, key condition, Filter Builder
    ///   conditions) and run;
    /// - scan: the Filter Builder conditions searched over the whole table;
    /// - partiql: the statement run in the PartiQL console.
    private func runCardSearch(_ json: String) async {
        guard let card = DynamoSearchBuilderField.parse(json) else { return }
        switch card.mode {
        case .scan:
            applyFilter(card.conditions)
            return
        case .partiql:
            guard let selectedTableName else { return }
            partiql.statement = card.statement
            showPartiQL = true
            showQueryPanel = false
            let keySchema = tableInfo?.keySchema ?? [], indexes = tableInfo?.indexes ?? []
            await partiql.run(api: api, profile: appState.currentProfile, region: appState.currentRegion) {
                PartiQLIndexAdvisor.suggest(statement: $0, tableName: selectedTableName, tableKeySchema: keySchema, indexes: indexes)
            }
            return
        case .query:
            // The filled Query form stays open, so the search is visible (and editable).
            showQueryPanel = true
            showPartiQL = false
        }
        queryIndexName = card.index.isEmpty ? nil : card.index
        guard queryPartitionKey == card.pkName else { return }
        queryPKValue = card.pkValue
        querySKOperator = card.skName != nil && querySortKey == card.skName ? card.skOperator : "none"
        querySKValue = card.skValue
        querySKValue2 = card.skValue2
        queryConditions = card.conditions
        await runQuery(more: false)
    }

    private func resetQuery() {
        itemsMode = .scan
        queryConditions = []
        queryIndexName = nil
        queryPKValue = ""
        querySKOperator = "none"
        querySKValue = ""
        querySKValue2 = ""
        queryItems = []
        queryNextKey = nil
        queryError = nil
        queryHasRun = false
    }

    // MARK: - Whole-table search

    /// Search results never block the screen: the grid stays up and fills
    /// in as matches arrive, with progress in the status bar below.
    @ViewBuilder
    private var searchResultsSection: some View {
        scanResultsView(searchShownItems, source: .search)
            .overlay {
                if searchItems.isEmpty {
                    VStack(spacing: 8) {
                        if isSearching {
                            ProgressView().controlSize(.small)
                            Text("Searching… \(searchScannedCount) items scanned so far")
                        } else if let searchError {
                            Text(searchError).foregroundStyle(.red)
                        } else if isSearchStopped {
                            Text("Search stopped - nothing matched in the \(searchScannedCount) items scanned")
                        } else if searchFinished {
                            Text("No items in the table match this filter")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .allowsHitTesting(false)
                }
            }
        Divider()
        searchStatusBar
    }

    private var searchStatusBar: some View {
        HStack(spacing: 10) {
            bottomLeadingButtons
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Color.accentColor)
            ResultCountLabel(count: searchShownItems.count, detail: searchDetail)
            if let searchRoute {
                Label(searchRoute.indexName ?? "Key", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize()
                    .help("Query on \(searchRoute.indexName ?? "the table") - \(searchRoute.keyCondition) pins the key, so only that partition is read instead of the whole table. The other conditions are applied to it.")
            }
            ElapsedTimeLabel(stopwatch: searchStopwatch)
            if isSearching {
                ProgressView().controlSize(.small)
                Text(searchRoute != nil ? "Querying…" : "Searching…")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let searchError {
                Text(searchError).font(.caption).foregroundStyle(.red).lineLimit(1).help(searchError)
            } else if isSearchStopped {
                Text("Stopped").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if searchFinished {
                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    .help(searchRoute != nil ? "Whole partition searched" : "Whole table searched")
            }
            Spacer(minLength: 0)
            loadMoreControls(
                hasMore: searchHasMore,
                isLoading: isSearching,
                onMore: { searchLoadMore() },
                onAll: { searchLoadAll() },
                onStop: { cancelSearch() }
            )
            closeResultsButton(help: "Clear the search and show the scanned items again") {
                applyFilter([])
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// Tooltip of the search bar's count.
    /// The rows on screen - a search call can find a few more than asked;
    /// those wait here for the next Load More.
    private var searchShownItems: [[String: DdbAttributeValue]] {
        searchItems.count > searchTarget ? Array(searchItems.prefix(searchTarget)) : searchItems
    }

    private var searchHasMore: Bool { searchItems.count > searchTarget || !searchFinished }

    private var searchDetail: String {
        var lines: [String]
        if let searchRoute {
            lines = ["\(searchItems.count) of \(searchScannedCount) items read with \(searchRoute.keyCondition) matched (Query on \(searchRoute.indexName ?? "the table"))."]
        } else {
            lines = ["\(searchItems.count) of \(searchScannedCount) items scanned matched (table has ~\(tableInfo?.itemCount ?? 0) items)."]
            if searchSegments > 1 { lines.append("Scanning with \(searchSegments) parallel segments.") }
        }
        if isSearching {
            lines.append("Still searching…")
        } else if searchFinished {
            lines.append(searchRoute != nil ? "Whole partition searched." : "Whole table searched.")
        } else {
            lines.append("More left - Load More / Load All continue where the search stopped.")
        }
        if searchItems.count > searchShownItems.count {
            lines.append("\(searchShownItems.count) shown, \(searchItems.count - searchShownItems.count) more already found.")
        }
        return lines.joined(separator: "\n")
    }

    /// Entry point from the grid's Filter Builder (Search / Clear Filters).
    private func applyFilter(_ conditions: [FilterCondition]) {
        if conditions.isEmpty {
            resetSearch()
            Task { await loadPage(currentPage) }
        } else {
            startSearch(conditions)
        }
    }

    private func startSearch(_ conditions: [FilterCondition]) {
        searchTask?.cancel()
        searchGeneration += 1
        searchConditions = conditions
        searchItems = []
        searchScannedCount = 0
        searchCursor = nil
        searchRoute = nil
        searchFinished = false
        searchError = nil
        isSearchStopped = false
        isSearching = false
        searchStopwatch = QueryStopwatch()
        searchTarget = searchBatchSize
        runSearchLoop()
    }

    /// Next 100 under the rows shown - from matches already found first,
    /// then the search continues from its cursor (no restart).
    private func searchLoadMore() {
        guard !isSearching else { return }
        isSearchStopped = false
        searchError = nil
        searchTarget = min(searchTarget, searchItems.count) + searchBatchSize
        if searchItems.count < searchTarget { runSearchLoop() }
    }

    /// Every remaining match, appended to the grid as each call returns.
    private func searchLoadAll() {
        guard !isSearching else { return }
        isSearchStopped = false
        searchError = nil
        searchTarget = .max
        runSearchLoop()
    }

    /// Steps the server-side search (~3 s per step, parallel scan) on its
    /// own until `searchTarget` matches are in or the table ends - no
    /// confirmation clicks in between. A cancelled step leaves
    /// `searchCursor` where it was, so Resume simply redoes that step.
    private func runSearchLoop() {
        guard let selectedTableName, !isSearching, !searchFinished else { return }
        let generation = searchGeneration
        let conditions = searchConditions
        isSearching = true
        searchStopwatch.start(reset: false)
        searchTask = Task {
            while !Task.isCancelled, generation == searchGeneration, !searchFinished, searchItems.count < searchTarget {
                do {
                    let result = try await api.searchDynamoDBTable(
                        profile: appState.currentProfile,
                        region: appState.currentRegion,
                        tableName: selectedTableName,
                        conditions: conditions,
                        maxResults: min(max(searchTarget - searchItems.count, 1), 500),
                        cursor: searchCursor
                    )
                    guard generation == searchGeneration, !Task.isCancelled else { break }
                    searchItems.append(contentsOf: result.items)
                    searchScannedCount += result.scannedCount
                    searchSegments = result.totalSegments
                    searchRoute = result.route
                    searchCursor = result.cursor
                    if result.cursor == nil { searchFinished = true }
                } catch {
                    if generation == searchGeneration && !Task.isCancelled {
                        searchError = error.friendlyMessage
                    }
                    break
                }
            }
            if generation == searchGeneration {
                isSearching = false
                searchStopwatch.stop()
                if searchTarget == .max && searchFinished { searchTarget = searchItems.count }
            }
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        isSearchStopped = true
        // After Load All, keep showing everything found so far.
        if searchTarget == .max { searchTarget = searchItems.count }
        searchStopwatch.stop()
    }

    private func resetSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration += 1
        searchConditions = []
        searchItems = []
        searchScannedCount = 0
        searchCursor = nil
        searchRoute = nil
        searchFinished = false
        searchError = nil
        isSearching = false
        isSearchStopped = false
        searchStopwatch = QueryStopwatch()
        searchTarget = 0
    }

    /// After an item is saved/deleted: re-run the active search from the
    /// start (the edit may change what matches), or reload the scan page.
    private func refreshAfterMutation() async {
        if partiql.hasResults {
            // Re-read the same SELECT so the edited/deleted row shows its new state.
            if !PartiQLSession.isWrite(partiql.lastStatement) {
                partiql.statement = partiql.lastStatement
                await partiql.run(api: api, profile: appState.currentProfile, region: appState.currentRegion)
            }
        } else if itemsMode == .query && queryHasRun {
            await runQuery(more: false)
        } else if searchConditions.isEmpty {
            await loadPage(currentPage)
        } else {
            startSearch(searchConditions)
        }
    }

    private func primaryKey(from item: [String: DdbAttributeValue], keySchema: [DdbKeySchemaElement]) -> [String: Any] {
        var key: [String: Any] = [:]
        for element in keySchema {
            if let attr = item[element.attributeName] {
                key[element.attributeName] = attr.value.jsonValue
            }
        }
        return key
    }

    private func deleteItem(_ item: [String: DdbAttributeValue]) async {
        guard let selectedTableName, let keySchema = tableInfo?.keySchema, !keySchema.isEmpty else { return }
        let key = primaryKey(from: item, keySchema: keySchema)
        guard !key.isEmpty else { return }
        do {
            try await api.deleteDynamoDBItem(profile: appState.currentProfile, region: appState.currentRegion, tableName: selectedTableName, key: key)
            await refreshAfterMutation()
        } catch {
            // Surfaced via the item sheet's own delete flow for the common
            // path; a context-menu delete failing here is rare enough to
            // just leave the item in place and let the user retry.
        }
    }
}

// MARK: - Item sheet (separate view to break recursive type cycle)

/// The item popup. Three views of the same item, switchable at the top
/// (default from Settings → DynamoDB → Item view):
/// - **JSON** - plain JSON, as the grid shows it.
/// - **DynamoDB JSON** - typed (`{"S": ...}`, `{"SS": [...]}`), exactly as
///   DynamoDB stores it.
/// - **Form** - the console's attribute editor (name / value / type rows,
///   nested Map/List/set rows).
/// All three read the item fresh from DynamoDB in its typed form and save
/// through a typed PutItem, so a string set stays a string set and a number
/// stays a number whichever view it was edited in. Switching views while
/// editing carries the edits over (or refuses, with the reason, if the
/// current text doesn't parse).
private struct DynamoItemSheet: View {
    let tableName: String
    let keySchema: [DdbKeySchemaElement]
    let attributeDefinitions: [DdbAttributeDefinition]
    let item: [String: DdbAttributeValue]?
    let mode: ItemSheetMode
    var onSaved: () -> Void
    var onClose: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var viewMode: DynamoItemViewMode = .json
    @State private var isEditing = false
    @State private var loadState: LoadState<Bool> = .loading
    /// The item as last loaded/saved - the baseline for "Cancel Edit" and
    /// the type hints when plain JSON is turned back into typed values.
    @State private var original: [DdbNamedValue] = []
    @State private var plainText = ""
    @State private var typedText = ""
    @State private var formRoots: [DdbFormNode] = []
    @State private var switchError: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var isDeleting = false
    @State private var deleteError: String?
    /// Set when the typed read failed and types had to be guessed from plain JSON.
    @State private var typesInferred = false

    /// Partition key first, then sort key.
    private var keyOrder: [String] {
        keySchema.sorted { $0.keyType == "HASH" && $1.keyType != "HASH" }.map(\.attributeName)
    }

    private var titleText: String {
        switch mode {
        case .view: return isEditing ? "Edit Item" : "Item"
        case .create: return "New Item"
        case .clone: return "Clone Item"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text(titleText)
                    .font(.headline)
                TabBar(tabs: DynamoItemViewMode.allCases, selection: Binding(get: { viewMode }, set: { switchView(to: $0) }), style: .pills, title: { $0.label })
                Spacer()
                if mode == .view, item != nil, case .loaded = loadState {
                    if isEditing {
                        SecondaryButton("Cancel Edit") {
                            isEditing = false
                            loadEditors(from: original)
                            switchError = nil
                        }
                    } else {
                        EditButton("Edit") {
                            loadEditors(from: original)
                            isEditing = true
                            switchError = nil
                        }
                    }
                }
                SecondaryButton("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top])

            if let switchError {
                Label(switchError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            if typesInferred {
                Text("Couldn't read this item's DynamoDB types - they were guessed from its plain JSON. Sets may show as lists.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            LoadableContent(loadState, retry: { Task { await load() } }) { _ in
                content
            }

            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }
            if let deleteError {
                Text(deleteError).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            HStack {
                if mode == .view, item != nil {
                    DeleteButton("Delete Item", isLoading: isDeleting, isDisabled: keySchema.isEmpty) {
                        Task { await delete() }
                    }
                }
                Spacer()
                if isEditing {
                    SaveButton(mode == .view ? "Save" : "Create", isLoading: isSaving, isDisabled: validationError != nil) {
                        Task { await save() }
                    }
                }
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 760, idealWidth: 1000, maxWidth: .infinity, minHeight: 600, idealHeight: 760, maxHeight: .infinity, alignment: .top)
        .task {
            viewMode = appState.dynamoDbItemView
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewMode {
        case .json, .dynamoDbJson:
            let isPlain = viewMode == .json
            if isEditing {
                VStack(alignment: .leading, spacing: 6) {
                    CodeTextEditor(text: isPlain ? $plainText : $typedText)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(validationError == nil ? Color.secondary.opacity(0.2) : Color.red.opacity(0.6), lineWidth: validationError == nil ? 1 : 1.5)
                        )
                    if let validationError {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else if isPlain {
                        Text("Types are kept from the stored item where the new value still fits (sets stay sets); new attributes are typed from their JSON value.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal)
            } else {
                StructuredContentView(text: isPlain ? DdbItemCodec.plainText(original) : DdbItemCodec.typedText(original), kind: .json)
                    .id(viewMode)
            }
        case .form:
            VStack(alignment: .leading, spacing: 6) {
                ScrollView([.horizontal, .vertical]) {
                    DynamoItemForm(roots: $formRoots, isEditable: isEditing)
                        .frame(minWidth: 940, alignment: .topLeading)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
                if isEditing, let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: Model

    /// The item as the active editor currently has it.
    private func currentTyped() throws -> [DdbNamedValue] {
        switch viewMode {
        case .json: return try DdbItemCodec.parsePlain(text: plainText, original: original, keyOrder: keyOrder)
        case .dynamoDbJson: return try DdbItemCodec.parseTyped(text: typedText, keyOrder: keyOrder)
        case .form: return try DdbFormNode.namedValues(formRoots, path: "")
        }
    }

    /// Nil when the active editor holds a saveable item; otherwise why not.
    private var validationError: String? {
        guard isEditing else { return nil }
        do {
            let typed = try currentTyped()
            let missing = keyOrder.filter { key in !typed.contains { $0.name == key } }
            if !missing.isEmpty { return "Missing key attribute\(missing.count == 1 ? "" : "s"): \(missing.joined(separator: ", "))" }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func loadEditors(from typed: [DdbNamedValue]) {
        plainText = DdbItemCodec.plainText(typed)
        typedText = DdbItemCodec.typedText(typed)
        formRoots = typed.map { attribute in
            DdbFormNode.from(attribute.value, name: attribute.name, keyRole: keyRole(of: attribute.name))
        }
    }

    private func keyRole(of name: String) -> String? {
        guard let element = keySchema.first(where: { $0.attributeName == name }) else { return nil }
        return element.keyType == "HASH" ? "Partition key" : "Sort key"
    }

    /// While editing, converts the current editor's content into the new
    /// view so edits aren't lost; refuses (with the reason) if it doesn't parse.
    private func switchView(to newMode: DynamoItemViewMode) {
        guard newMode != viewMode else { return }
        switchError = nil
        if isEditing {
            do {
                loadEditors(from: try currentTyped())
            } catch {
                switchError = "Fix this first to switch views - \(error.localizedDescription)"
                return
            }
        }
        viewMode = newMode
    }

    private func primaryKey() -> [String: Any]? {
        guard let item else { return nil }
        var key: [String: Any] = [:]
        for element in keySchema {
            guard let attr = item[element.attributeName] else { return nil }
            key[element.attributeName] = attr.value.jsonValue
        }
        return key.isEmpty ? nil : key
    }

    private func load() async {
        loadState = .loading
        typesInferred = false
        if mode == .create || item == nil {
            original = keyOrder.map { name in
                let type = attributeDefinitions.first { $0.attributeName == name }?.attributeType ?? "S"
                let value: DdbTypedValue = type == "N" ? .n("") : type == "B" ? .b("") : .s("")
                return DdbNamedValue(name: name, value: value)
            }
        } else if let key = primaryKey() {
            do {
                guard let typed = try await api.getDynamoDBItemTyped(profile: appState.currentProfile, region: appState.currentRegion, tableName: tableName, key: key, keyOrder: keyOrder) else {
                    loadState = .failed("This item no longer exists in the table.")
                    return
                }
                original = typed
            } catch {
                original = inferredFromPlain()
                typesInferred = true
            }
        } else {
            original = inferredFromPlain()
            typesInferred = true
        }
        loadEditors(from: original)
        if mode != .view { isEditing = true }
        loadState = .loaded(true)
    }

    private func inferredFromPlain() -> [DdbNamedValue] {
        guard let item else { return [] }
        let object = item.mapValues { $0.value.jsonValue }
        return orderedNames(Array(object.keys), preferred: keyOrder).map {
            DdbNamedValue(name: $0, value: DdbTypedValue.fromPlain(object[$0]!, hint: nil))
        }
    }

    private func save() async {
        saveError = nil
        let typed: [DdbNamedValue]
        do {
            typed = try currentTyped()
        } catch {
            saveError = error.localizedDescription
            return
        }
        isSaving = true
        do {
            try await api.putDynamoDBItemTyped(profile: appState.currentProfile, region: appState.currentRegion, tableName: tableName, item: typed)
            onSaved()
            onClose()
        } catch {
            saveError = error.friendlyMessage
        }
        isSaving = false
    }

    private func delete() async {
        guard let key = primaryKey() else {
            deleteError = "Couldn't determine this item's primary key"
            return
        }
        isDeleting = true
        deleteError = nil
        do {
            try await api.deleteDynamoDBItem(profile: appState.currentProfile, region: appState.currentRegion, tableName: tableName, key: key)
            onSaved()
            onClose()
        } catch {
            deleteError = error.friendlyMessage
        }
        isDeleting = false
    }
}
