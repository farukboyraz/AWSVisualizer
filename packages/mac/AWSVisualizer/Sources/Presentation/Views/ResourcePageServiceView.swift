import SwiftUI

/// Screen for every service on the shared ResourcePage model
/// (`ResourcePage`): grouped list on the left, the backend-built console tabs on
/// the right. Per-service differences live in the backend adapters
/// (packages/api/src/infrastructure/aws/*), not here.
struct ResourcePageServiceView: View {
    let service: String
    let title: String
    let emptyMessage: String
    var noun: String = "resource"

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[PageSummary]> = .loading
    @State private var selectedId: String?
    @State private var filter = ""
    /// List-level "New ..." forms (G1); empty for most services.
    @State private var createForms: [PageAction] = []
    @State private var openForm: PageAction?

    private var selectedName: String? {
        guard case .loaded(let rows) = state else { return nil }
        return rows.first { $0.id == selectedId }?.name
    }

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 320, minWidth: 230, maxWidth: 500, isDetailActive: selectedId != nil, onBack: { selectedId = nil }, backTitle: title, detailTitle: selectedName) {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle(title)
                    // A dashboard card's search lands here.
                    ScreenFilterField(text: $filter)
                    LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: emptyMessage) { rows in
                        List(selection: $selectedId) {
                            ForEach(groups(rows), id: \.name) { group in
                                if let name = group.name {
                                    Section(name) { ForEach(group.rows) { row($0) } }
                                } else {
                                    ForEach(group.rows) { row($0) }
                                }
                            }
                        }
                        .listStyle(.sidebar)
                    }
                    PanelActionBar {
                        ForEach(createForms) { form in
                            NewButton(systemImage: form.systemImage, compactSize: 24, help: form.title) { openForm = form }
                        }
                        RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
                    } trailing: {
                        if case .loaded(let rows) = state {
                            Text("\(rows.count) items").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } detail: {
                if let selectedId {
                    ResourcePageView(service: service, id: selectedId, noun: noun, onChanged: { Task { await loadData() } }).id("\(service)-\(selectedId)")
                } else {
                    EmptyStateView(message: "Select a \(noun)")
                }
            }
            .task(id: "\(service)-\(appState.currentProfile)-\(appState.currentRegion)") {
                selectedId = nil
                state = .loading
                await loadData()
            }
            .task(id: service) { createForms = (try? await api.getPageForms(service: service)) ?? [] }
            .sheet(item: $openForm) { form in
                PageFormSheet(service: service, form: form) { params in
                    let newId = try await api.createPageResource(service: service, profile: appState.currentProfile, region: appState.currentRegion, form: form.id, params: params)
                    await loadData()
                    if let newId { selectedId = newId }
                }
            }
        }
    }

    private struct Group {
        let name: String?
        let rows: [PageSummary]
    }

    /// Keeps the backend's order; rows without a group come first.
    private func groups(_ rows: [PageSummary]) -> [Group] {
        // Every word must appear in the name, status, info or group (same rule as the other lists).
        let shown = rows.matching(filter)
        var order: [String?] = []
        var byGroup: [String?: [PageSummary]] = [:]
        for r in shown {
            if byGroup[r.group] == nil { order.append(r.group) }
            byGroup[r.group, default: []].append(r)
        }
        return order.map { Group(name: $0, rows: byGroup[$0] ?? []) }
    }

    private func row(_ r: PageSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(r.name).font(.body.bold()).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let status = r.status { StatusBadge(status) }
            }
            if let info = r.info, !info.isEmpty {
                Text(info).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .tag(r.id)
    }

    private func loadData() async {
        if case .loaded = state {} else { state = .loading }
        do {
            let rows = try await api.getPageList(service: service, profile: appState.currentProfile, region: appState.currentRegion)
            state = rows.isEmpty ? .empty : .loaded(rows)
            // A dashboard card asked for one resource.
            if let link = appState.takeDeepLink(for: service), let id = link.resource, rows.contains(where: { $0.id == id }) {
                selectedId = id
            }
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

/// Renders one `ResourcePage`: header, action buttons, tabs from the backend plus
/// a Tags tab when the resource is taggable.
struct ResourcePageView: View {
    let service: String
    let id: String
    let noun: String
    let onChanged: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    private static let tagsTab = "Tags"

    @State private var state: LoadState<ResourcePage> = .loading
    @State private var tab = ""
    @State private var pending: String?
    @State private var actionError: String?
    /// The action whose form sheet is open (G1).
    @State private var formAction: PageAction?

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { page in
            let titles = page.tabs.map(\.title) + (page.tags != nil ? [Self.tagsTab] : [])
            VStack(alignment: .leading, spacing: 0) {
                header(page, titles: titles)
                DetailActionBar(error: actionError, onRefresh: { Task { await load() } }) {
                    ForEach(page.actions) { a in
                        if a.hasForm {
                            // The sheet shows the confirm text with the fields.
                            AppButton(a.title, kind: a.destructive ? .warning : .confirm, systemImage: a.systemImage, showIcon: true, isLoading: pending == a.id, isDisabled: pending != nil) {
                                formAction = a
                            }
                        } else {
                            ConfirmedActionButton(
                                title: a.title, systemImage: a.systemImage,
                                confirmationTitle: a.confirmTitle, confirmationMessage: a.confirmMessage,
                                isLoading: pending == a.id, isDisabled: pending != nil,
                                role: a.destructive ? .destructive : nil
                            ) { Task { await run(a.id) } }
                        }
                    }
                }
                if !page.errors.isEmpty {
                    PartialErrorsView(errors: page.errors).padding(.horizontal, 16).padding(.bottom, 4)
                }
                Group {
                    if tab == Self.tagsTab, let tags = page.tags {
                        ResourceTagsEditor(tags: tags, resourceNoun: noun, onAdd: { key, value in
                            state = .loaded(try await api.addPageTag(service: service, profile: appState.currentProfile, region: appState.currentRegion, id: id, arn: page.arn ?? "", key: key, value: value))
                        }, onRemove: { key in
                            state = .loaded(try await api.removePageTag(service: service, profile: appState.currentProfile, region: appState.currentRegion, id: id, arn: page.arn ?? "", key: key))
                        })
                    } else if let t = page.tabs.first(where: { $0.title == tab }) ?? page.tabs.first {
                        PageTabView(tab: t, arn: t.title == page.tabs.first?.title ? page.arn : nil, resourceKey: "\(service)|\(id)")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear { if !titles.contains(tab) { tab = titles.first ?? "" } }
        }
        .task(id: id) { await load() }
        .sheet(item: $formAction) { action in
            PageFormSheet(service: service, form: action) { params in
                state = .loaded(try await api.runPageAction(service: service, profile: appState.currentProfile, region: appState.currentRegion, id: id, action: action.id, params: params))
                onChanged()
            }
        }
    }

    private func header(_ page: ResourcePage, titles: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title).font(.title2.bold()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let subtitle = page.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if let status = page.status { StatusBadge(status) }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 6)
            TabBar(tabs: titles, selection: $tab, title: { $0 })
                .padding(.bottom, 8)
        }
    }

    private func run(_ action: String) async {
        pending = action
        actionError = nil
        do {
            state = .loaded(try await api.runPageAction(service: service, profile: appState.currentProfile, region: appState.currentRegion, id: id, action: action))
            onChanged()
        } catch {
            actionError = error.friendlyMessage
        }
        pending = nil
    }

    private func load() async {
        do {
            let page = try await api.getResourcePage(service: service, profile: appState.currentProfile, region: appState.currentRegion, id: id)
            state = .loaded(page)
            let titles = page.tabs.map(\.title) + (page.tags != nil ? [Self.tagsTab] : [])
            if !titles.contains(tab) { tab = titles.first ?? "" }
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

/// One backend tab: JSON document full-size, otherwise sections then tables.
private struct PageTabView: View {
    let tab: PageTab
    /// Shown at the bottom of the first tab.
    let arn: String?
    /// Reloads the graphs when another resource is shown.
    var resourceKey: String = ""

    private var charts: [MetricChartSpec] { tab.charts ?? [] }

    var body: some View {
        if let json = tab.json {
            StructuredContentView(text: json, kind: .json)
        } else if let text = tab.text {
            StructuredContentView(text: text, kind: .plain)
        } else if tab.sections.isEmpty && tab.tables.isEmpty && charts.isEmpty {
            EmptyStateView(message: tab.emptyMessage ?? "Nothing to show")
        } else {
            DetailTabPage(maxWidth: 1200) {
                if !charts.isEmpty {
                    MetricChartGrid(charts: charts, reloadKey: resourceKey)
                }
                ForEach(Array(tab.sections.enumerated()), id: \.offset) { _, s in
                    DetailSection(title: s.title) {
                        if !s.settings.isEmpty { DetailGrid(items: s.settings.detailItems) }
                        ForEach(s.copyable ?? []) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.label).font(.caption2).foregroundStyle(.tertiary)
                                CopyableBlock(text: c.value)
                            }
                        }
                        if let note = s.note { DetailNote(note) }
                    }
                }
                ForEach(Array(tab.tables.enumerated()), id: \.offset) { _, t in
                    if let title = t.title {
                        DetailSection(title: title) { PageTableView(table: t) }
                    } else {
                        PageTableView(table: t)
                    }
                }
                if let arn {
                    DetailSection(title: "ARN") { CopyableBlock(text: arn) }
                }
            }
        }
    }
}

/// A backend table with any number of columns. Column widths follow the
/// longest cell (capped), rows are lazy, and wide tables scroll sideways.
private struct PageTableView: View {
    let table: PageTable

    private var widths: [CGFloat] {
        table.columns.indices.map { i in
            let longest = ([table.columns[i]] + table.rows.prefix(200).map { i < $0.count ? $0[i] : "" }).map(\.count).max() ?? 0
            return min(max(CGFloat(longest) * 6.6 + 18, 70), 420)
        }
    }

    var body: some View {
        if table.rows.isEmpty {
            Text(table.emptyMessage ?? "No items").font(.caption).foregroundStyle(.secondary)
        } else {
            let w = widths
            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(table.columns.indices, id: \.self) { i in
                            Text(table.columns[i]).font(.caption.bold()).foregroundStyle(.secondary)
                                .frame(width: w[i], alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            ForEach(table.columns.indices, id: \.self) { i in
                                cell(i < row.count ? row[i] : "", column: i)
                                    .frame(width: w[i], alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                    }
                }
                .padding(.trailing, 8)
            }
        }
    }

    @ViewBuilder
    private func cell(_ value: String, column: Int) -> some View {
        if column == table.statusColumn, value != "-" {
            StatusBadge(value)
        } else {
            Text(displayValue(value))
                .font(column == 0 ? .caption.bold() : .caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
                .padding(.trailing, 8)
        }
    }

    /// ISO timestamps from the backend read better localized.
    private func displayValue(_ value: String) -> String {
        if value.count >= 20, value.dropFirst(4).first == "-", value.contains("T"), value.hasSuffix("Z") {
            return Formatters.formatISODate(value)
        }
        return value
    }
}
