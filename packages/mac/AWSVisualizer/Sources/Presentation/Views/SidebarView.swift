import SwiftUI

private let dashboardEntry = AWSServiceCatalogEntry(
    id: dashboardServiceID,
    name: "Dashboard",
    category: "",
    icon: "square.grid.2x2",
    implemented: true
)

/// One collapsible group in the expanded sidebar list - either a real
/// category, the synthetic "Favorites" group, or the synthetic "Other"
/// group used when there aren't enough services selected to bother
/// splitting by category. Every service sits in exactly one group: a
/// favorited one only under Favorites (not again under its category), so
/// the highlighted row is always the one that was clicked.
private struct SidebarGroup {
    let key: String
    let label: String
    let isFavorites: Bool
    let entries: [AWSServiceCatalogEntry]
    let defaultExpanded: Bool
}

/// A right-click action that asks first.
private enum SidebarConfirmation: Identifiable {
    case removeFavorite(AWSServiceCatalogEntry)
    case removeFromSidebar(AWSServiceCatalogEntry)

    var id: String {
        switch self {
        case .removeFavorite(let e): "fav-\(e.id)"
        case .removeFromSidebar(let e): "hide-\(e.id)"
        }
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isCollapsed: Bool
    let collapsedWidth: CGFloat
    let expandedWidth: CGFloat

    @State private var isCollapsedListScrollable = false
    @State private var collapsedContentHeight: CGFloat = 0
    @State private var collapsedContainerHeight: CGFloat = 0
    /// Explicit user toggles, keyed by group key - anything not in here
    /// falls back to that group's own `defaultExpanded`, so Favorites/Other
    /// start open and real categories start closed without needing every
    /// group's state seeded up front.
    @State private var expandedOverrides: [String: Bool] = [:]
    @State private var isSearching = false
    @State private var searchQuery = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var confirmation: SidebarConfirmation?
    @State private var addingCardFor: AWSServiceCatalogEntry?
    @State private var actionError: String?

    private let favoritesGroupKey = "__favorites__"
    private let otherGroupKey = "__other__"

    /// Typical macOS scrollbar width - reserved as extra sidebar width only
    /// while collapsed content is actually scrollable, so the scrollbar
    /// never eats into the icon column and throw its centering off from
    /// the (unscrolled) header button above it.
    private let scrollbarGutter: CGFloat = 14

    /// Past this many selected services, a flat A-Z list gets long enough
    /// that grouping by category (collapsible, like Select Services) is
    /// easier to scan than scrolling through everything at once.
    private let categoryGroupingThreshold = 20

    private var sortedServiceEntries: [AWSServiceCatalogEntry] {
        appState.selectedCatalogEntries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Selected entries matching the current search, or everything when
    /// there's no query - the single source every group below filters from,
    /// so a search match still shows up in both Favorites and its normal
    /// group rather than collapsing the duplication down to one hit.
    private var searchMatchedEntries: [AWSServiceCatalogEntry] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return sortedServiceEntries }
        return sortedServiceEntries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var isGroupedByCategory: Bool {
        appState.selectedCatalogEntries.count > categoryGroupingThreshold
    }

    /// Whether there's anything favorited among the *selected* services at
    /// all (search-independent, so typing/clearing a search never flips the
    /// list between flat and grouped on its own). No favorites and not
    /// enough services to split by category means there's nothing to group
    /// against, so the list stays plain - an "Other" folder with nothing to
    /// pair against a Favorites folder would just be a folder nobody asked
    /// for wrapping the exact same list that used to be flat.
    private var hasAnyFavoriteSelected: Bool {
        sortedServiceEntries.contains { appState.favoriteServiceIDs.contains($0.id) }
    }

    private var showsFlatList: Bool {
        !isGroupedByCategory && !hasAnyFavoriteSelected
    }

    /// Favorites (if any matched) first, then either per-category groups
    /// (>20 selected) or a single "Other" group holding everything else -
    /// empty groups are dropped so a search with no hits in a category
    /// doesn't leave a header with nothing under it.
    private var sidebarGroups: [SidebarGroup] {
        var groups: [SidebarGroup] = []

        let favoriteEntries = searchMatchedEntries.filter { appState.favoriteServiceIDs.contains($0.id) }
        if !favoriteEntries.isEmpty {
            groups.append(SidebarGroup(key: favoritesGroupKey, label: "Favorites", isFavorites: true, entries: favoriteEntries, defaultExpanded: true))
        }

        // Favorites are listed once, above - the other groups leave them out.
        let otherEntries = searchMatchedEntries.filter { !appState.favoriteServiceIDs.contains($0.id) }

        if isGroupedByCategory {
            let byCategory = Dictionary(grouping: otherEntries, by: { $0.category })
            for category in byCategory.keys.sorted() {
                let entries = byCategory[category]!
                guard !entries.isEmpty else { continue }
                groups.append(SidebarGroup(key: category, label: category.isEmpty ? "Other" : category, isFavorites: false, entries: entries, defaultExpanded: false))
            }
        } else if hasAnyFavoriteSelected, !otherEntries.isEmpty {
            groups.append(SidebarGroup(key: otherGroupKey, label: "Other", isFavorites: false, entries: otherEntries, defaultExpanded: true))
        }

        return groups
    }

    private var entries: [AWSServiceCatalogEntry] {
        [dashboardEntry] + sortedServiceEntries
    }

    private func groupExpandedBinding(_ group: SidebarGroup) -> Binding<Bool> {
        Binding(
            get: {
                if isSearching, !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty { return true }
                return expandedOverrides[group.key] ?? group.defaultExpanded
            },
            set: { isExpanded in expandedOverrides[group.key] = isExpanded }
        )
    }

    private var extraGutter: CGFloat {
        isCollapsed && isCollapsedListScrollable ? scrollbarGutter : 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isCollapsed {
                collapsedList
            } else {
                expandedList
            }
            selectServicesFooter
        }
        .frame(width: isCollapsed ? collapsedWidth + extraGutter : expandedWidth)
        .background(Theme.sidebarBackground(colorScheme))
        .animation(.easeInOut(duration: 0.15), value: extraGutter)
        .alert(
            appState.language.confirmTitle,
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            presenting: confirmation
        ) { item in
            Button(appState.language.confirmYes, role: .destructive) { confirm(item) }
            Button(appState.language.confirmNo, role: .cancel) {}
        } message: { item in
            switch item {
            case .removeFavorite(let entry): Text(appState.language.sidebarRemoveFavoriteMessage(entry.name))
            case .removeFromSidebar(let entry): Text(appState.language.sidebarHideMessage(entry.name))
            }
        }
        .alert(actionError ?? "", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button(appState.language.okButtonTitle) {}
        }
        .sheet(item: $addingCardFor) { entry in
            DashboardCardEditor(
                card: nil,
                presetService: entry.id,
                language: appState.language,
                profiles: appState.profiles.isEmpty ? [appState.currentProfile] : appState.profiles.map(\.name),
                defaultProfile: appState.currentProfile,
                defaultRegion: appState.currentRegion,
                onSave: { card in
                    addingCardFor = nil
                    Task {
                        do { try await appState.addDashboardCard(card, using: api) } catch { actionError = error.friendlyMessage }
                    }
                },
                onCancel: { addingCardFor = nil }
            )
        }
    }

    // MARK: Opening and the right-click menu

    /// Opening a page folds the sidebar away so the page gets the room;
    /// the sidebar button (or a click on the icon strip) brings it back.
    private func open(_ serviceID: String, newTab: Bool = false) {
        if newTab { appState.openInAdditionalTab(serviceID) } else { appState.openInNewTab(serviceID) }
        if !isCollapsed {
            isSearching = false
            withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = true }
        }
    }

    private func menuContext(_ entry: AWSServiceCatalogEntry) -> SidebarServiceMenu.Context {
        SidebarServiceMenu.Context(
            entry: entry,
            isDashboard: entry.id == dashboardEntry.id,
            isFavorite: appState.favoriteServiceIDs.contains(entry.id),
            canOpenInNewTab: appState.maxTabs > 1 && appState.tabs.count < appState.maxTabs,
            canAddCard: appState.dashboardPrefs.cards.count < DashboardPrefs.maxCards,
            canRemoveFromSidebar: appState.selectedServiceIDs.count > 1,
            language: appState.language
        )
    }

    private func serviceMenu(_ entry: AWSServiceCatalogEntry) -> some View {
        SidebarServiceMenu(context: menuContext(entry)) { perform($0, on: entry) }
    }

    private func perform(_ action: SidebarServiceAction, on entry: AWSServiceCatalogEntry) {
        switch action {
        case .open: open(entry.id)
        case .openInNewTab: open(entry.id, newTab: true)
        case .addFavorite: runAction { try await appState.setFavorite(entry.id, true, using: api) }
        case .removeFavorite: confirmation = .removeFavorite(entry)
        case .addCard: addingCardFor = entry
        case .copyName:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.name, forType: .string)
        case .removeFromSidebar: confirmation = .removeFromSidebar(entry)
        }
    }

    private func confirm(_ item: SidebarConfirmation) {
        switch item {
        case .removeFavorite(let entry): runAction { try await appState.setFavorite(entry.id, false, using: api) }
        case .removeFromSidebar(let entry): runAction { try await appState.removeFromSidebar(entry.id, using: api) }
        }
    }

    private func runAction(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { actionError = error.friendlyMessage }
        }
    }

    private var header: some View {
        HStack {
            if !isCollapsed {
                if isSearching {
                    TextField("Search services", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFieldFocused)
                    Button {
                        isSearching = false
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Services")
                        .font(.headline)
                    Spacer()
                    Button {
                        isSearching = true
                        searchFieldFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Search services")
                }
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
        }
        .padding(.horizontal, isCollapsed ? 0 : 14)
        .padding(.trailing, isCollapsed ? extraGutter : 0)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: isCollapsed ? .center : .leading)
        .background(Theme.sidebarPanelBackground(colorScheme))
    }

    /// Rows are tagged with a group-qualified key (`group::service`) and the
    /// selection resolves to exactly one of them - with each service now in
    /// a single group (favorites only under Favorites), that's simply the
    /// row that was clicked.
    private func rowKey(groupKey: String?, serviceID: String) -> String {
        guard let groupKey else { return serviceID }
        return "\(groupKey)::\(serviceID)"
    }

    private func serviceID(fromRowKey rowKey: String) -> String {
        guard let range = rowKey.range(of: "::") else { return rowKey }
        return String(rowKey[range.upperBound...])
    }

    /// The single row key that should render as selected for the currently
    /// active service - `nil` if that service isn't visible under the
    /// current search filter, in which case nothing highlights rather than
    /// guessing.
    private var highlightedRowKey: String? {
        let selectedService = appState.selectedService
        if selectedService == dashboardEntry.id { return dashboardEntry.id }
        if showsFlatList {
            return searchMatchedEntries.contains { $0.id == selectedService } ? selectedService : nil
        }
        if appState.favoriteServiceIDs.contains(selectedService) {
            guard sidebarGroups.contains(where: { $0.isFavorites && $0.entries.contains { $0.id == selectedService } }) else { return nil }
            return rowKey(groupKey: favoritesGroupKey, serviceID: selectedService)
        }
        guard let group = sidebarGroups.first(where: { !$0.isFavorites && $0.entries.contains { $0.id == selectedService } }) else { return nil }
        return rowKey(groupKey: group.key, serviceID: selectedService)
    }

    private var expandedList: some View {
        List(selection: Binding<String?>(
            get: { highlightedRowKey },
            set: { newValue in
                // Group headers (Favorites, Other, categories) carry their
                // ForEach id as an implicit tag - selecting one must not
                // "open" a service by that name; their own button toggles them.
                guard let newValue, !sidebarGroups.contains(where: { $0.key == newValue }) else { return }
                open(serviceID(fromRowKey: newValue))
            }
        )) {
            Label(dashboardEntry.name, systemImage: dashboardEntry.icon)
                .font(.title3.weight(.semibold))
                .padding(.vertical, 3)
                .sidebarHover()
                .tag(dashboardEntry.id)
                .contextMenu { serviceMenu(dashboardEntry) }

            if showsFlatList {
                ForEach(searchMatchedEntries) { entry in
                    serviceRow(entry, showsFavoriteStar: false, groupKey: nil)
                }
            } else {
                ForEach(sidebarGroups, id: \.key) { group in
                    DisclosureGroup(isExpanded: groupExpandedBinding(group)) {
                        ForEach(group.entries) { entry in
                            serviceRow(entry, showsFavoriteStar: group.isFavorites, groupKey: group.key)
                        }
                    } label: {
                        groupLabel(group)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebarPanelBackground(colorScheme))
    }

    /// The whole label row toggles the group, not just the tiny native
    /// disclosure triangle - the same "click anywhere on the row" a tree
    /// view gives you, rather than requiring a precise click on the arrow.
    private func groupLabel(_ group: SidebarGroup) -> some View {
        let binding = groupExpandedBinding(group)
        return Button {
            binding.wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                if group.isFavorites {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                Text(group.label)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .sidebarHover()
        }
        .buttonStyle(.plain)
        .selectionDisabled()
    }

    /// The star (Favorites group only) shows why the row is there; favorites
    /// are toggled from the right-click menu or the Select Services popup.
    private func serviceRow(_ entry: AWSServiceCatalogEntry, showsFavoriteStar: Bool, groupKey: String?) -> some View {
        HStack {
            Label { Text(entry.name) } icon: { ServiceIcon(entry: entry) }
            if showsFavoriteStar {
                Spacer()
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
        }
        .sidebarHover()
        .tag(rowKey(groupKey: groupKey, serviceID: entry.id))
        .contextMenu { serviceMenu(entry) }
    }

    private var collapsedList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(entries) { entry in
                    let isActive = entry.id == appState.selectedService
                    Button {
                        // Stays collapsed: the page opens, the strip stays out of the way.
                        appState.openInNewTab(entry.id)
                    } label: {
                        ServiceIcon(entry: entry, size: 15)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .background(
                        isActive ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .sidebarHover(cornerRadius: 8, inset: 0)
                    .help(entry.name)
                    .contextMenu { serviceMenu(entry) }
                }
            }
            .padding(.vertical, 6)
            .padding(.leading, 14)
            .padding(.trailing, extraGutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newValue in
                collapsedContentHeight = newValue
                updateScrollable()
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.sidebarPanelBackground(colorScheme))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = false }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newValue in
            collapsedContainerHeight = newValue
            updateScrollable()
        }
    }

    private func updateScrollable() {
        isCollapsedListScrollable = collapsedContentHeight > collapsedContainerHeight
    }

    /// The same "Select Services…" entry point as Settings, pinned outside
    /// the scrollable area so it's always reachable no matter how many
    /// services are selected - a floating pill (circle when collapsed),
    /// visually set apart from the plain list rows above it.
    private var selectServicesFooter: some View {
        Group {
            if isCollapsed {
                SidebarFooterButton(icon: "slider.horizontal.3", title: nil) {
                    appState.requestedSettingsPage = .services
                }
                .help("Select Services…")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.trailing, extraGutter)
            } else {
                VStack(spacing: 6) {
                    SidebarFooterButton(icon: "slider.horizontal.3", title: "Select Services…") {
                        appState.requestedSettingsPage = .services
                    }
                    // The app's version; details in Settings › General › About.
                    Button { appState.requestedSettingsPage = .about } label: {
                        Text("v\(AppVersion.short)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("AWS Visualizer \(AppVersion.display)")
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Theme.sidebarPanelBackground(colorScheme))
    }
}

/// A floating pill button (perfect circle when icon-only) with a subtle
/// hover highlight - used for the sidebar's pinned "Select Services…"
/// entry so it reads as an action distinct from the plain service rows.
private struct SidebarFooterButton: View {
    let icon: String
    let title: String?
    let action: () -> Void

    @State private var isHovering = false

    private var shape: AnyShape {
        title == nil ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .medium))
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                }
            }
            .background(Color.secondary.opacity(isHovering ? 0.22 : 0.13), in: shape)
            .overlay(shape.stroke(Color.secondary.opacity(0.18), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering ? Color.primary : Color.secondary)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
