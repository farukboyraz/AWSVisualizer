import SwiftUI

/// FSx file systems (Windows File Server, Lustre, NetApp ONTAP, OpenZFS).
/// Type-specific parts - volumes, SVMs, data repository associations -
/// share the Storage tab and only show what the file system type has.
struct FsxView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[FsxFileSystemSummary]> = .loading
    @State private var selectedId: String?

    private var selected: FsxFileSystemSummary? {
        guard case .loaded(let items) = state else { return nil }
        return items.first { $0.fileSystemId == selectedId }
    }

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 320, minWidth: 220, maxWidth: 480, isDetailActive: selectedId != nil, onBack: { selectedId = nil }, backTitle: "File systems", detailTitle: selected.map { $0.name ?? $0.fileSystemId }) {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle("FSx")
                    ScreenFilterField(text: $filter)
                    LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No FSx file systems in this region") { unfilteredItems in
                        let items = unfilteredItems.matching(filter)
                        List(items, selection: $selectedId) { fs in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(fs.name ?? fs.fileSystemId).font(.body.bold()).lineLimit(1)
                                    Spacer()
                                    StatusBadge(fs.lifecycle ?? "-")
                                }
                                Text([FsxFormat.typeName(fs.fileSystemType), StorageFormat.gib(fs.storageCapacity), fs.deploymentType].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.vertical, 2)
                            .tag(fs.fileSystemId)
                        }
                        .listStyle(.sidebar)
                    }
                    PanelActionBar {
                        RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
                    }
                }
            } detail: {
                if let selected {
                    FsxFileSystemDetailView(id: selected.fileSystemId, type: selected.fileSystemType ?? "").id(selected.fileSystemId)
                } else {
                    EmptyStateView(message: "Select a file system")
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
            let items = try await api.getFsxFileSystems(profile: appState.currentProfile, region: appState.currentRegion)
            state = items.isEmpty ? .empty : .loaded(items)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

enum FsxFormat {
    static func typeName(_ raw: String?) -> String {
        switch raw {
        case "WINDOWS": return "Windows File Server"
        case "LUSTRE": return "Lustre"
        case "ONTAP": return "NetApp ONTAP"
        case "OPENZFS": return "OpenZFS"
        default: return raw ?? "-"
        }
    }
}

private struct FsxFileSystemDetailView: View {
    let id: String
    let type: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case summary = "Summary"
        case network = "Network & security"
        case storage = "Storage"
        case backups = "Backups"
        case maintenance = "Administration"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .summary
    @State private var state: LoadState<FsxFileSystemDetail> = .loading
    @State private var extras: LoadState<FsxFileSystemExtras> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { fs in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(title: fs.name ?? fs.fileSystemId, subtitle: "\(FsxFormat.typeName(fs.fileSystemType)) · \(fs.fileSystemId)", status: fs.lifecycle, tab: $tab)
                DetailActionBar(error: fs.failureMessage, onRefresh: { Task { await load() } }) { EmptyView() }
                Group {
                    switch tab {
                    case .summary: summary(fs)
                    case .network: network(fs)
                    case .storage: extrasTab { storage($0) }
                    case .backups: extrasTab { backups($0) }
                    case .maintenance: administration(fs)
                    case .tags:
                        ResourceTagsEditor(tags: fs.tags, resourceNoun: "file system", onAdd: { key, value in
                            state = .loaded(try await api.addFsxTag(profile: appState.currentProfile, region: appState.currentRegion, id: id, arn: fs.resourceArn ?? "", key: key, value: value))
                        }, onRemove: { key in
                            state = .loaded(try await api.removeFsxTag(profile: appState.currentProfile, region: appState.currentRegion, id: id, arn: fs.resourceArn ?? "", key: key))
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: id) { await load() }
    }

    private func extrasTab<Content: View>(@ViewBuilder _ content: @escaping (FsxFileSystemExtras) -> Content) -> some View {
        LoadableContent(extras, retry: { Task { await loadExtras() } }) { x in
            VStack(alignment: .leading, spacing: 0) {
                if !x.errors.isEmpty { PartialErrorsView(errors: x.errors).padding(.horizontal, 16).padding(.top, 8) }
                content(x)
            }
        }
    }

    private func summary(_ fs: FsxFileSystemDetail) -> some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Summary") {
                DetailGrid(items: [
                    DetailItem("File system ID", fs.fileSystemId),
                    DetailItem("Type", FsxFormat.typeName(fs.fileSystemType), monospaced: false),
                    DetailItem("Version", fs.fileSystemTypeVersion),
                    DetailItem("Lifecycle state", fs.lifecycle),
                    DetailItem("Storage capacity", StorageFormat.gib(fs.storageCapacity)),
                    DetailItem("Storage type", fs.storageType),
                    DetailItem("Owner", fs.ownerId),
                    DetailItem("Created", Formatters.formatISODate(fs.creationTime), monospaced: false),
                ])
            }
            if !fs.settings.isEmpty {
                DetailSection(title: "\(FsxFormat.typeName(fs.fileSystemType)) settings") {
                    DetailGrid(items: fs.settings.detailItems)
                }
            }
            if !fs.endpoints.isEmpty {
                DetailSection(title: "Endpoints") {
                    ForEach(fs.endpoints) { e in DetailField(e.label, e.value) }
                }
            }
            if let arn = fs.resourceArn {
                DetailSection(title: "ARN") { CopyableBlock(text: arn) }
            }
        }
    }

    private func network(_ fs: FsxFileSystemDetail) -> some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Network & security") {
                DetailGrid(items: [
                    DetailItem("VPC", fs.vpcId),
                    DetailItem("DNS name", fs.dnsName),
                    DetailItem("KMS key", fs.kmsKeyId.map(ComputeFormat.arnResourceName)),
                ])
                DetailChipsField("Subnets", fs.subnetIds)
                DetailChipsField("Network interfaces", fs.networkInterfaceIds)
            }
        }
    }

    private func administration(_ fs: FsxFileSystemDetail) -> some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Backups and maintenance") {
                if fs.backupSettings.isEmpty {
                    Text("No backup settings reported.").font(.caption).foregroundStyle(.secondary)
                } else {
                    DetailGrid(items: fs.backupSettings.detailItems)
                }
            }
            DetailSection(title: "Updates (administrative actions)") {
                if fs.administrativeActions.isEmpty {
                    Text("No recent administrative actions.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(fs.administrativeActions.enumerated()), id: \.offset) { _, a in
                    HStack {
                        Text(a.type ?? "-").font(.caption.bold())
                        if let p = a.progressPercent { Text("\(p)%").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Text(Formatters.formatISODate(a.requestTime)).font(.caption2).foregroundStyle(.secondary)
                        StatusBadge(a.status ?? "-")
                    }
                    if let failure = a.failure { Text(failure).font(.caption2).foregroundStyle(.orange) }
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func storage(_ x: FsxFileSystemExtras) -> some View {
        switch type {
        case "ONTAP", "OPENZFS":
            DetailTabPage(maxWidth: 1000) {
                if type == "ONTAP" {
                    DetailSection(title: "Storage virtual machines · \(x.storageVirtualMachines.count)") {
                        ForEach(x.storageVirtualMachines) { s in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(s.name ?? s.storageVirtualMachineId).font(.body.bold())
                                    Text(s.storageVirtualMachineId).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Spacer()
                                    StatusBadge(s.lifecycle ?? "-")
                                }
                                DetailGrid(items: [
                                    DetailItem("Subtype", s.subtype),
                                    DetailItem("Root volume security style", s.rootVolumeSecurityStyle),
                                    DetailItem("Active Directory", s.activeDirectory),
                                ] + s.endpoints.detailItems)
                            }
                            Divider()
                        }
                    }
                }
                DetailSection(title: "Volumes · \(x.volumes.count)") {
                    if x.volumes.isEmpty { Text("No volumes.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(x.volumes) { v in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(v.name ?? v.volumeId).font(.body.bold())
                                Text(v.volumeId).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                if v.sizeInBytes != nil { Text(StorageFormat.bytes(v.sizeInBytes)).font(.caption) }
                                StatusBadge(v.lifecycle ?? "-")
                            }
                            DetailGrid(items: [DetailItem("Path", v.path), DetailItem("SVM", v.storageVirtualMachineId)].filter { $0.value != "-" } + v.settings.detailItems)
                        }
                        Divider()
                    }
                }
            }
        case "LUSTRE":
            if x.dataRepositoryAssociations.isEmpty {
                EmptyStateView(message: "No data repository associations (S3 links)")
            } else {
                Table(x.dataRepositoryAssociations) {
                    TableColumn("File system path") { a in Text(a.fileSystemPath ?? "-").font(.caption.monospaced()) }
                    TableColumn("Data repository") { a in Text(a.dataRepositoryPath ?? "-").font(.caption.monospaced()).textSelection(.enabled) }
                    TableColumn("Auto import") { a in Text(a.autoImport ?? "Off").font(.caption) }
                    TableColumn("Auto export") { a in Text(a.autoExport ?? "Off").font(.caption) }
                    TableColumn("State") { a in StatusBadge(a.lifecycle ?? "-") }.width(min: 80, ideal: 100)
                }
            }
        default:
            EmptyStateView(message: "Windows File Server exposes its storage as SMB shares - see Endpoints under Summary.")
        }
    }

    private func backups(_ x: FsxFileSystemExtras) -> some View {
        Group {
            if x.backups.isEmpty {
                EmptyStateView(message: "No backups of this file system")
            } else {
                Table(x.backups) {
                    TableColumn("Backup ID") { b in Text(b.backupId).font(.caption.monospaced()).textSelection(.enabled) }
                    TableColumn("Type") { b in Text(b.type ?? "-").font(.caption) }.width(min: 80, ideal: 110)
                    TableColumn("Volume") { b in Text(b.volumeId ?? "-").font(.caption.monospaced()) }
                    TableColumn("Created") { b in Text(Formatters.formatISODate(b.creationTime)).font(.caption) }
                    TableColumn("Status") { b in
                        HStack(spacing: 4) {
                            StatusBadge(b.lifecycle ?? "-")
                            if let p = b.progressPercent, b.lifecycle != "AVAILABLE" { Text("\(p)%").font(.caption2) }
                        }
                    }
                    TableColumn("Failure") { b in Text(b.failureMessage ?? "").font(.caption2).foregroundStyle(.orange).lineLimit(2) }
                }
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await api.getFsxFileSystem(profile: appState.currentProfile, region: appState.currentRegion, id: id))
        } catch {
            state = .failed(error.friendlyMessage)
        }
        await loadExtras()
    }

    private func loadExtras() async {
        do {
            extras = .loaded(try await api.getFsxFileSystemExtras(profile: appState.currentProfile, region: appState.currentRegion, id: id, type: type))
        } catch {
            extras = .failed(error.friendlyMessage)
        }
    }
}
