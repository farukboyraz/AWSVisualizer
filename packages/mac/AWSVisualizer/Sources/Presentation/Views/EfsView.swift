import SwiftUI

/// EFS file systems: list on the left, the console's file system page on
/// the right (General, Network, Access points, Replication, File system
/// policy, Tags).
struct EfsView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[EfsFileSystemSummary]> = .loading
    @State private var selectedId: String?

    private var selectedName: String? {
        guard case .loaded(let items) = state, let fs = items.first(where: { $0.fileSystemId == selectedId }) else { return nil }
        return fs.name ?? fs.fileSystemId
    }

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 300, minWidth: 220, maxWidth: 480, isDetailActive: selectedId != nil, onBack: { selectedId = nil }, backTitle: "File systems", detailTitle: selectedName) {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle("EFS")
                    ScreenFilterField(text: $filter)
                    LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No EFS file systems in this region") { unfilteredItems in
                        let items = unfilteredItems.matching(filter)
                        List(items, selection: $selectedId) { fs in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(fs.name ?? fs.fileSystemId).font(.body.bold()).lineLimit(1)
                                    Spacer()
                                    StatusBadge(fs.lifeCycleState ?? "-")
                                }
                                Text([fs.fileSystemId, StorageFormat.bytes(fs.sizeInBytes), fs.availabilityZoneName.map { "One Zone · \($0)" } ?? "Regional"].joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.vertical, 2)
                            .tag(fs.fileSystemId)
                        }
                        .listStyle(.sidebar)
                    }
                    PanelActionBar {
                        RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
                    } trailing: {
                        if case .loaded(let items) = state {
                            Text("\(items.count) file systems").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } detail: {
                if let selectedId {
                    EfsFileSystemDetailView(id: selectedId).id(selectedId)
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
            let items = try await api.getEfsFileSystems(profile: appState.currentProfile, region: appState.currentRegion)
            state = items.isEmpty ? .empty : .loaded(items)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct EfsFileSystemDetailView: View {
    let id: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case general = "General"
        case network = "Network"
        case accessPoints = "Access points"
        case replication = "Replication"
        case policy = "File system policy"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .general
    @State private var state: LoadState<EfsFileSystemDetail> = .loading
    @State private var extras: LoadState<EfsFileSystemExtras> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { fs in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(title: fs.name ?? fs.fileSystemId, subtitle: fs.fileSystemId, status: fs.lifeCycleState, tab: $tab)
                DetailActionBar(onRefresh: { Task { await load() } }) { EmptyView() }
                Group {
                    switch tab {
                    case .general: general(fs)
                    case .network: extrasTab { network($0) }
                    case .accessPoints: extrasTab { accessPoints($0) }
                    case .replication: extrasTab { replication($0) }
                    case .policy: extrasTab { PolicyDocumentView(policy: $0.policy, emptyMessage: "No file system policy - any client with network access can mount it (subject to IAM).") }
                    case .tags:
                        ResourceTagsEditor(tags: fs.tags, resourceNoun: "file system", onAdd: { key, value in
                            state = .loaded(try await api.addEfsTag(profile: appState.currentProfile, region: appState.currentRegion, id: id, key: key, value: value))
                        }, onRemove: { key in
                            state = .loaded(try await api.removeEfsTag(profile: appState.currentProfile, region: appState.currentRegion, id: id, key: key))
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: id) { await load() }
    }

    private func extrasTab<Content: View>(@ViewBuilder _ content: @escaping (EfsFileSystemExtras) -> Content) -> some View {
        LoadableContent(extras, retry: { Task { await loadExtras() } }) { x in
            VStack(alignment: .leading, spacing: 0) {
                if !x.errors.isEmpty { PartialErrorsView(errors: x.errors).padding(.horizontal, 16).padding(.top, 8) }
                content(x)
            }
        }
    }

    private func general(_ fs: EfsFileSystemDetail) -> some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "General") {
                DetailGrid(items: [
                    DetailItem("File system ID", fs.fileSystemId),
                    DetailItem("State", fs.lifeCycleState),
                    DetailItem("Availability and durability", fs.availabilityZoneName.map { "One Zone (\($0))" } ?? "Regional", monospaced: false),
                    DetailItem("Performance mode", fs.performanceMode),
                    DetailItem("Throughput mode", fs.throughputMode.map { $0 == "provisioned" ? "Provisioned (\(Formatters.formatNumber(fs.provisionedThroughputInMibps, decimals: 0)) MiB/s)" : $0 }),
                    DetailItem("Encrypted", fs.encrypted == true ? "Yes" : "No", monospaced: false),
                    DetailItem("KMS key", fs.kmsKeyId.map(ComputeFormat.arnResourceName)),
                    DetailItem("Automatic backups", fs.automaticBackups ?? "-"),
                    DetailItem("Replication overwrite protection", fs.replicationOverwriteProtection),
                    DetailItem("Mount targets", ComputeFormat.int(fs.numberOfMountTargets)),
                    DetailItem("Owner", fs.ownerId),
                    DetailItem("Created", Formatters.formatISODate(fs.creationTime), monospaced: false),
                ])
            }
            DetailSection(title: "Metered size") {
                HStack(spacing: 12) {
                    MetricTile(title: "Total", value: StorageFormat.bytes(fs.sizeInBytes))
                    MetricTile(title: "Standard", value: StorageFormat.bytes(fs.sizeInStandard))
                    MetricTile(title: "Infrequent Access", value: StorageFormat.bytes(fs.sizeInIA))
                    MetricTile(title: "Archive", value: StorageFormat.bytes(fs.sizeInArchive))
                }
                if let ts = fs.sizeTimestamp {
                    Text("Measured \(Formatters.formatISODate(ts)) - EFS updates this about once an hour.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            DetailSection(title: "Lifecycle management") {
                if fs.lifecyclePolicies.isEmpty {
                    Text("No lifecycle policy - everything stays in Standard.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(fs.lifecyclePolicies, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
            DetailSection(title: "Attach") {
                DetailField("DNS name", fs.dnsName)
                Text("Using the EFS mount helper (amazon-efs-utils):").font(.caption2).foregroundStyle(.secondary)
                CopyableBlock(text: "sudo mount -t efs -o tls \(fs.fileSystemId):/ /mnt/efs")
                Text("Using the NFS client:").font(.caption2).foregroundStyle(.secondary)
                CopyableBlock(text: "sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \(fs.dnsName):/ /mnt/efs")
            }
            if let arn = fs.fileSystemArn {
                DetailSection(title: "ARN") { CopyableBlock(text: arn) }
            }
        }
    }

    private func network(_ x: EfsFileSystemExtras) -> some View {
        Group {
            if x.mountTargets.isEmpty {
                EmptyStateView(message: "No mount targets - the file system can't be mounted until one is created in a subnet.")
            } else {
                Table(x.mountTargets) {
                    TableColumn("Availability Zone") { m in Text(m.availabilityZoneName ?? "-").font(.caption) }
                    TableColumn("Mount target ID") { m in Text(m.mountTargetId).font(.caption.monospaced()).textSelection(.enabled) }
                    TableColumn("Subnet") { m in Text(m.subnetId ?? "-").font(.caption.monospaced()) }
                    TableColumn("IP address") { m in Text(m.ipAddress ?? "-").font(.caption.monospaced()).textSelection(.enabled) }
                    TableColumn("Security groups") { m in Text(m.securityGroups.joined(separator: ", ")).font(.caption.monospaced()).lineLimit(2) }
                    TableColumn("State") { m in StatusBadge(m.lifeCycleState ?? "-") }.width(min: 80, ideal: 100)
                }
            }
        }
    }

    private func accessPoints(_ x: EfsFileSystemExtras) -> some View {
        Group {
            if x.accessPoints.isEmpty {
                EmptyStateView(message: "No access points")
            } else {
                Table(x.accessPoints) {
                    TableColumn("Name") { a in Text(a.name ?? "-").font(.caption.bold()) }
                    TableColumn("Access point ID") { a in Text(a.accessPointId).font(.caption.monospaced()).textSelection(.enabled) }
                    TableColumn("Path") { a in Text(a.path ?? "/").font(.caption.monospaced()) }
                    TableColumn("POSIX user") { a in Text(a.posixUser ?? "-").font(.caption.monospaced()) }
                    TableColumn("Root directory creation") { a in Text(a.creationInfo ?? "-").font(.caption) }
                    TableColumn("State") { a in StatusBadge(a.lifeCycleState ?? "-") }.width(min: 80, ideal: 100)
                }
            }
        }
    }

    private func replication(_ x: EfsFileSystemExtras) -> some View {
        DetailTabPage {
            if x.replications.isEmpty {
                Text("Replication is not configured for this file system.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(x.replications.enumerated()), id: \.offset) { _, r in
                DetailSection(title: r.isSource ? "Replicating to" : "Replica of \(r.sourceFileSystemId ?? "-") (\(r.sourceRegion ?? "-"))") {
                    ForEach(Array(r.destinations.enumerated()), id: \.offset) { _, d in
                        HStack {
                            Text(d.fileSystemId ?? "-").font(.caption.monospaced()).textSelection(.enabled)
                            Text(d.region ?? "-").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("Last sync: \(Formatters.formatISODate(d.lastReplicatedTimestamp))").font(.caption2).foregroundStyle(.secondary)
                            StatusBadge(d.status ?? "-")
                        }
                        Divider()
                    }
                    Text("Created \(Formatters.formatISODate(r.creationTime))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await api.getEfsFileSystem(profile: appState.currentProfile, region: appState.currentRegion, id: id))
        } catch {
            state = .failed(error.friendlyMessage)
        }
        await loadExtras()
    }

    private func loadExtras() async {
        do {
            extras = .loaded(try await api.getEfsFileSystemExtras(profile: appState.currentProfile, region: appState.currentRegion, id: id))
        } catch {
            extras = .failed(error.friendlyMessage)
        }
    }
}
