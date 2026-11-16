import SwiftUI

enum ServiceSelectionMode {
    /// First launch: only implemented services, preselected.
    case onboarding
    /// Full catalog (Settings page or the sidebar's "Select Services...").
    case settings
}

/// Search + "select default" + ALL + category groups of service checkboxes
/// with favorite stars. Owns no saving: it edits `selection`, which in
/// Settings › Services is part of the Settings draft.
struct ServiceSelectionList: View {
    let mode: ServiceSelectionMode
    @Binding var selection: Set<String>

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var searchText = ""
    @State private var counts: [String: Int?] = [:]
    @State private var showMinServiceWarning = false
    @State private var showSelectedOnly = false
    @State private var installRequest: InstallRequest?
    @State private var errorItem: InstallStepItem?

    private struct InstallRequest: Identifiable {
        let id = UUID()
        let services: [String]
    }

    private var candidateEntries: [AWSServiceCatalogEntry] {
        switch mode {
        case .onboarding: appState.serviceCatalog.filter { $0.implemented }
        case .settings: appState.serviceCatalog
        }
    }

    /// The user's first-sign-in picks when there are any, else every implemented service.
    private var defaultServiceIDs: Set<String> {
        appState.userDefaultServiceIDs.isEmpty ? Set(appState.serviceCatalog.filter { $0.implemented }.map { $0.id }) : Set(appState.userDefaultServiceIDs)
    }

    /// Selected services whose packages are missing (bulk install button).
    private var selectedNeedingInstall: [String] {
        candidateEntries.filter { selection.contains($0.id) && $0.needsPackageInstall }.map(\.id)
    }

    private var filteredEntries: [AWSServiceCatalogEntry] {
        candidateEntries.filter { entry in
            (searchText.isEmpty || entry.name.localizedCaseInsensitiveContains(searchText) || entry.category.localizedCaseInsensitiveContains(searchText))
                && (!showSelectedOnly || selection.contains(entry.id))
        }
    }

    private var groupedByCategory: [(category: String, entries: [AWSServiceCatalogEntry])] {
        let groups = Dictionary(grouping: filteredEntries, by: { $0.category })
        return groups.keys.sorted().map { key in (key, groups[key]!.sorted { $0.name < $1.name }) }
    }

    private var allSelectedBinding: Binding<Bool> {
        Binding(
            get: { !filteredEntries.isEmpty && Set(filteredEntries.map { $0.id }).isSubset(of: selection) },
            set: { isOn in
                if isOn { selection.formUnion(filteredEntries.map { $0.id }) }
            }
        )
    }

    private func categoryToggleBinding(_ group: (category: String, entries: [AWSServiceCatalogEntry])) -> Binding<Bool> {
        let categoryIDs = Set(group.entries.map { $0.id })
        return Binding(
            get: { !categoryIDs.isEmpty && categoryIDs.isSubset(of: selection) },
            set: { isOn in
                if isOn {
                    selection.formUnion(categoryIDs)
                } else {
                    let remainder = selection.subtracting(categoryIDs)
                    if remainder.isEmpty {
                        showMinServiceWarning = true
                    } else {
                        selection = remainder
                    }
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                TextField("Search services or categories", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Toggle("Selected only", isOn: $showSelectedOnly)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Toggle(isOn: Binding(
                    get: { selection == defaultServiceIDs },
                    set: { isOn in
                        if isOn { selection = defaultServiceIDs }
                    }
                )) {
                    Text(appState.language.selectDefaultServicesLabel)
                }
                .toggleStyle(.checkbox)
                .fixedSize()
            }
            .padding(.bottom, 8)

            List {
                Toggle(isOn: allSelectedBinding) {
                    Text("ALL")
                        .font(.caption.bold())
                }
                .toggleStyle(.checkbox)

                ForEach(groupedByCategory, id: \.category) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            row(entry)
                        }
                    } header: {
                        categoryHeader(group)
                    }
                }
            }
            .overlay {
                if filteredEntries.isEmpty {
                    EmptyStateView(message: "No services match")
                }
            }

            HStack {
                Text("\(selection.count) selected · ★ favorites appear at the top of the sidebar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if mode == .settings, !selectedNeedingInstall.isEmpty {
                    NewButton("Install selected (\(selectedNeedingInstall.count))", systemImage: "arrow.down.circle") {
                        installRequest = InstallRequest(services: selectedNeedingInstall)
                    }
                }
            }
            .padding(.top, 6)
        }
        .task { await loadCounts() }
        .sheet(item: $installRequest) { request in
            PackageInstallSheet(services: request.services) { installRequest = nil }
        }
        .sheet(item: $errorItem) { item in
            InstallErrorView(item: item, onRetry: {
                errorItem = nil
                installRequest = InstallRequest(services: [item.id])
            }) {
                errorItem = nil
            }
        }
        .alert(appState.language.minServiceWarningTitle, isPresented: $showMinServiceWarning) {
            Button(appState.language.okButtonTitle) {}
        } message: {
            Text(appState.language.minServiceWarningMessage)
        }
    }

    private func categoryHeader(_ group: (category: String, entries: [AWSServiceCatalogEntry])) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: categoryToggleBinding(group))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(AWSServiceCatalogEntry.categoryTint(group.category))
            Text(group.category.isEmpty ? "Other" : group.category)
            Text("\(group.entries.filter { selection.contains($0.id) }.count)/\(group.entries.count)")
                .foregroundStyle(.tertiary)
        }
    }

    private func row(_ entry: AWSServiceCatalogEntry) -> some View {
        ServiceRow(
            entry: entry,
            isSelected: selection.contains(entry.id),
            isFavorite: appState.favoriteServiceIDs.contains(entry.id),
            countLabel: countLabel(for: entry),
            showsInstall: mode == .settings,
            onInstall: { installRequest = InstallRequest(services: [entry.id]) },
            onShowError: { Task { await showFailure(entry) } },
            onToggleSelection: { isOn in
                if isOn {
                    selection.insert(entry.id)
                } else if selection.count > 1 {
                    selection.remove(entry.id)
                } else {
                    showMinServiceWarning = true
                }
            },
            onToggleFavorite: { toggleFavorite(entry.id) }
        )
    }

    /// Favorites save immediately (they don't change which services exist
    /// in the sidebar, only their order).
    private func toggleFavorite(_ id: String) {
        var favorites = appState.favoriteServiceIDs
        if favorites.contains(id) {
            favorites.remove(id)
        } else {
            favorites.insert(id)
        }
        appState.favoriteServiceIDs = favorites
        Task {
            try? await api.setFavoriteServices(Array(favorites))
        }
    }

    /// The failure recorded in ~/.awsvisualizer for this service.
    private func showFailure(_ entry: AWSServiceCatalogEntry) async {
        guard let status = try? await api.getPackagesStatus() else { return }
        if let failure = status.failures[entry.id] {
            errorItem = InstallStepItem(failure: failure, name: entry.name)
        } else {
            // Resolved meanwhile (e.g. installed from Terminal).
            await appState.reloadServiceCatalog(using: api)
        }
    }

    private func countLabel(for entry: AWSServiceCatalogEntry) -> String? {
        guard entry.implemented else { return nil }
        guard let value = counts[entry.id] ?? nil else { return nil }
        return "(\(value))"
    }

    private func loadCounts() async {
        let implementedIDs = candidateEntries.filter { $0.implemented }.map { $0.id }
        guard !implementedIDs.isEmpty, !appState.currentProfile.isEmpty else { return }
        if let result = try? await api.getServiceCounts(profile: appState.currentProfile, region: appState.currentRegion, services: implementedIDs) {
            counts = result
        }
    }
}

extension AppState {
    /// Saves the sidebar's service list. Open tabs may point at a service
    /// that was just deselected, so the workspace goes back to Dashboard.
    @MainActor
    func saveSelectedServices(_ selection: Set<String>, using api: APIService) async throws {
        let ids = Array(selection)
        try await api.setSelectedServices(ids)
        selectedServiceIDs = ids
        resetToDashboard()
    }
}

/// One row in the service list - the checkbox/name sit far from the star
/// (a `Spacer()` between them), so on hover the whole row gets a tinted,
/// rounded background tying them together visually, making it obvious
/// which star belongs to which service without having to line them up by
/// eye across a wide row.
private struct ServiceRow: View {
    let entry: AWSServiceCatalogEntry
    let isSelected: Bool
    let isFavorite: Bool
    let countLabel: String?
    var showsInstall: Bool = false
    var onInstall: () -> Void = {}
    var onShowError: () -> Void = {}
    var onToggleSelection: (Bool) -> Void
    var onToggleFavorite: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { isSelected }, set: onToggleSelection)) {
                HStack(spacing: 8) {
                    ServiceIcon(entry: entry)
                        .frame(width: 20)
                    Text(entry.name)
                    if let countLabel {
                        Text(countLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !entry.implemented {
                        Text("Coming soon")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            if entry.needsPackageInstall {
                if entry.packageInstallFailed == true {
                    Button(action: onShowError) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help("Install failed - show the error recorded in ~/.awsvisualizer")
                }
                if showsInstall {
                    // Icon only, plain: keeps the row at its normal height.
                    Button(action: onInstall) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Install this service's npm packages")
                }
            }
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isFavorite ? .yellow : .secondary)
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
