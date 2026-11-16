import SwiftUI

/// S3 Glacier vaults (the original vault API, not S3 Glacier storage
/// classes). Archives can only be listed through an inventory job, so the
/// Jobs tab can request one and open it once Glacier has prepared it.
struct GlacierView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[GlacierVault]> = .loading
    @State private var selected: String?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 300, minWidth: 220, maxWidth: 480, isDetailActive: selected != nil, onBack: { selected = nil }, backTitle: "Vaults", detailTitle: selected) {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle("S3 Glacier")
                    ScreenFilterField(text: $filter)
                    LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No Glacier vaults in this region") { unfilteredVaults in
                        let vaults = unfilteredVaults.matching(filter)
                        List(vaults, selection: $selected) { v in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.vaultName).font(.body.bold()).lineLimit(1)
                                Text("\(v.numberOfArchives ?? 0) archives · \(StorageFormat.bytes(v.sizeInBytes))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(v.vaultName)
                        }
                        .listStyle(.sidebar)
                    }
                    PanelActionBar {
                        RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
                    }
                }
            } detail: {
                if let selected {
                    GlacierVaultDetailView(vaultName: selected).id(selected)
                } else {
                    EmptyStateView(message: "Select a vault")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private func loadData() async {
        if case .loaded = state {} else { state = .loading }
        do {
            let vaults = try await api.getGlacierVaults(profile: appState.currentProfile, region: appState.currentRegion)
            state = vaults.isEmpty ? .empty : .loaded(vaults)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct GlacierVaultDetailView: View {
    let vaultName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case jobs = "Jobs & inventory"
        case policy = "Permissions"
        case lock = "Vault lock"
        case notifications = "Notifications"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .details
    @State private var state: LoadState<GlacierVaultDetail> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { v in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(title: v.vaultName, subtitle: "\(v.numberOfArchives ?? 0) archives · \(StorageFormat.bytes(v.sizeInBytes))", tab: $tab)
                Group {
                    switch tab {
                    case .details:
                        DetailTabPage(maxWidth: 900) {
                            DetailGrid(items: [
                                DetailItem("Vault name", v.vaultName),
                                DetailItem("Archives", ComputeFormat.int(v.numberOfArchives)),
                                DetailItem("Size", StorageFormat.bytes(v.sizeInBytes)),
                                DetailItem("Created", Formatters.formatISODate(v.creationDate), monospaced: false),
                                DetailItem("Last inventory", v.lastInventoryDate.map(Formatters.formatISODate) ?? "Never", monospaced: false),
                            ])
                            DetailNote("Archive count and size come from Glacier's last inventory, which it refreshes about once a day.")
                            if let arn = v.vaultArn { DetailSection(title: "ARN") { CopyableBlock(text: arn) } }
                        }
                    case .jobs:
                        GlacierJobsTab(vaultName: vaultName)
                    case .policy:
                        PolicyDocumentView(policy: v.accessPolicy, emptyMessage: "No vault access policy - only IAM permissions of this account apply.")
                    case .lock:
                        if let lock = v.lock {
                            VStack(alignment: .leading, spacing: 0) {
                                DetailTabPage(maxWidth: 900) {
                                    DetailGrid(items: [
                                        DetailItem("State", lock.state),
                                        DetailItem("Created", Formatters.formatISODate(lock.creationDate), monospaced: false),
                                        DetailItem("Expires (in-progress lock)", lock.expirationDate.map(Formatters.formatISODate), monospaced: false),
                                    ])
                                }
                                .frame(maxHeight: 140)
                                PolicyDocumentView(policy: lock.policy)
                            }
                        } else {
                            EmptyStateView(message: "No vault lock policy")
                        }
                    case .notifications:
                        DetailTabPage(maxWidth: 900) {
                            if let n = v.notifications {
                                DetailField("SNS topic", n.snsTopic ?? "-")
                                DetailChipsField("Events", n.events)
                            } else {
                                Text("Notifications are not enabled for this vault.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    case .tags:
                        ResourceTagsEditor(tags: v.tags, resourceNoun: "vault", onAdd: { key, value in
                            state = .loaded(try await api.addGlacierTag(profile: appState.currentProfile, region: appState.currentRegion, name: vaultName, key: key, value: value))
                        }, onRemove: { key in
                            state = .loaded(try await api.removeGlacierTag(profile: appState.currentProfile, region: appState.currentRegion, name: vaultName, key: key))
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: vaultName) { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await api.getGlacierVault(profile: appState.currentProfile, region: appState.currentRegion, name: vaultName))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct GlacierJobsTab: View {
    let vaultName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[GlacierJob]> = .loading
    @State private var isRequesting = false
    @State private var actionError: String?
    @State private var note: String?
    @State private var openJob: GlacierJob?
    @State private var inventory: LoadState<GlacierInventory> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailActionBar(error: actionError, note: note, onRefresh: { Task { await load() } }) {
                ConfirmedActionButton(
                    title: "Request inventory", systemImage: "list.bullet.rectangle",
                    confirmationTitle: "Request an inventory of \(vaultName)?",
                    confirmationMessage: "Glacier prepares the archive list in about 3-5 hours; it then stays downloadable for 24 hours. A small retrieval request charge applies.",
                    isLoading: isRequesting, isDisabled: isRequesting, role: nil
                ) { Task { await requestInventory() } }
            }
            if let job = openJob {
                inventoryView(job)
            } else {
                LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No jobs in the last 24 hours. Glacier keeps finished jobs for about a day.") { jobs in
                    Table(jobs) {
                        TableColumn("Action") { j in Text(j.action ?? "-").font(.caption.bold()) }
                        TableColumn("Status") { j in StatusBadge(j.statusCode ?? "-") }.width(min: 80, ideal: 100)
                        TableColumn("Created") { j in Text(Formatters.formatISODate(j.creationDate)).font(.caption) }
                        TableColumn("Completed") { j in Text(Formatters.formatISODate(j.completionDate)).font(.caption) }
                        TableColumn("Size") { j in Text(StorageFormat.bytes(j.inventorySizeInBytes ?? j.archiveSizeInBytes)).font(.caption) }.width(min: 60, ideal: 80)
                        TableColumn("") { j in
                            if j.action == "InventoryRetrieval" && j.statusCode == "Succeeded" {
                                AppButton("View", kind: .open, isLoading: false) {
                                    openJob = j
                                    Task { await loadInventory(j) }
                                }
                            } else if let m = j.statusMessage, j.statusCode == "Failed" {
                                Text(m).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                            }
                        }
                        .width(min: 70, ideal: 90)
                    }
                }
            }
        }
        .task(id: vaultName) { await load() }
    }

    private func inventoryView(_ job: GlacierJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecondaryButton("Back to jobs", systemImage: "chevron.left") { openJob = nil }
                Spacer()
                if case .loaded(let inv) = inventory {
                    Text("\(inv.archives.count)\(inv.truncated ? "+" : "") archives · inventory of \(Formatters.formatISODate(inv.inventoryDate))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            LoadableContent(inventory, retry: { Task { await loadInventory(job) } }, emptyMessage: "The vault was empty at inventory time") { inv in
                Table(inv.archives) {
                    TableColumn("Archive ID") { a in Text(a.archiveId).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                    TableColumn("Description") { a in Text(a.description ?? "-").font(.caption).lineLimit(1) }
                    TableColumn("Created") { a in Text(Formatters.formatISODate(a.creationDate)).font(.caption) }
                    TableColumn("Size") { a in Text(StorageFormat.bytes(a.size)).font(.caption) }.width(min: 60, ideal: 90)
                }
            }
        }
    }

    private func load() async {
        do {
            let jobs = try await api.getGlacierJobs(profile: appState.currentProfile, region: appState.currentRegion, name: vaultName)
            state = jobs.isEmpty ? .empty : .loaded(jobs)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }

    private func loadInventory(_ job: GlacierJob) async {
        inventory = .loading
        do {
            let inv = try await api.getGlacierInventory(profile: appState.currentProfile, region: appState.currentRegion, name: vaultName, jobId: job.jobId)
            inventory = inv.archives.isEmpty ? .empty : .loaded(inv)
        } catch {
            inventory = .failed(error.friendlyMessage)
        }
    }

    private func requestInventory() async {
        isRequesting = true
        actionError = nil
        note = nil
        do {
            let started = try await api.requestGlacierInventory(profile: appState.currentProfile, region: appState.currentRegion, name: vaultName)
            note = "Inventory job \(started.jobId.map { String($0.prefix(12)) } ?? "") started - come back in a few hours and press View."
            await load()
        } catch {
            actionError = error.friendlyMessage
        }
        isRequesting = false
    }
}
