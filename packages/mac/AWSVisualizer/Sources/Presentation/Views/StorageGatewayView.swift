import SwiftUI

/// Storage Gateway: gateways on the left; the right shows the gateway page
/// with whichever of volumes / file shares / tapes its type serves.
struct StorageGatewayView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[GatewaySummary]> = .loading
    @State private var selectedArn: String?

    private var selectedName: String? {
        guard case .loaded(let items) = state else { return nil }
        return items.first { $0.gatewayArn == selectedArn }?.gatewayName
    }

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 300, minWidth: 220, maxWidth: 480, isDetailActive: selectedArn != nil, onBack: { selectedArn = nil }, backTitle: "Gateways", detailTitle: selectedName) {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle("Storage Gateway")
                    ScreenFilterField(text: $filter)
                    LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No gateways in this region") { unfilteredItems in
                        let items = unfilteredItems.matching(filter)
                        List(items, selection: $selectedArn) { g in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(g.gatewayName ?? g.gatewayId ?? "-").font(.body.bold()).lineLimit(1)
                                    Spacer()
                                    StatusBadge(g.operationalState ?? "-")
                                }
                                Text([GatewayFormat.typeName(g.gatewayType), g.hostEnvironment].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.vertical, 2)
                            .tag(g.gatewayArn)
                        }
                        .listStyle(.sidebar)
                    }
                    PanelActionBar {
                        RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
                    }
                }
            } detail: {
                if let selectedArn {
                    GatewayDetailView(arn: selectedArn).id(selectedArn)
                } else {
                    EmptyStateView(message: "Select a gateway")
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
            let items = try await api.getStorageGateways(profile: appState.currentProfile, region: appState.currentRegion)
            state = items.isEmpty ? .empty : .loaded(items)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

enum GatewayFormat {
    static func typeName(_ raw: String?) -> String {
        switch raw {
        case "FILE_S3": return "Amazon S3 File Gateway"
        case "FILE_FSX_SMB": return "FSx File Gateway"
        case "CACHED": return "Volume Gateway (cached)"
        case "STORED": return "Volume Gateway (stored)"
        case "VTL", "VTL_SNOW": return "Tape Gateway"
        default: return raw ?? "-"
        }
    }
}

private struct GatewayDetailView: View {
    let arn: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case storage = "Storage resources"
        case disks = "Local disks & cache"
        case maintenance = "Maintenance & bandwidth"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .details
    @State private var state: LoadState<GatewayDetail> = .loading
    @State private var storage: LoadState<GatewayStorage> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { g in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(title: g.gatewayName ?? g.gatewayId ?? "-", subtitle: GatewayFormat.typeName(g.gatewayType), status: g.gatewayState, tab: $tab)
                DetailActionBar(onRefresh: { Task { await load() } }) { EmptyView() }
                Group {
                    switch tab {
                    case .details: details(g)
                    case .storage: storageTab { storageResources($0) }
                    case .disks: storageTab { disks(g, $0) }
                    case .maintenance:
                        DetailTabPage(maxWidth: 900) {
                            DetailSection(title: "Maintenance window") { DetailField("Starts", g.maintenance ?? "-", monospaced: false) }
                            DetailSection(title: "Software updates") {
                                DetailGrid(items: [
                                    DetailItem("Software version", g.softwareVersion),
                                    DetailItem("Last update", Formatters.formatISODate(g.lastSoftwareUpdate), monospaced: false),
                                    DetailItem("Next update available", Formatters.formatISODate(g.nextUpdateAvailabilityDate), monospaced: false),
                                    DetailItem("Updates end", Formatters.formatISODate(g.softwareUpdatesEndDate), monospaced: false),
                                    DetailItem("Deprecation date", Formatters.formatISODate(g.deprecationDate), monospaced: false),
                                ])
                            }
                            DetailSection(title: "Bandwidth rate limits") {
                                if g.bandwidth.isEmpty { Text("Not available for this gateway type.").font(.caption).foregroundStyle(.secondary) }
                                DetailGrid(items: g.bandwidth.detailItems)
                            }
                        }
                    case .tags:
                        ResourceTagsEditor(tags: g.tags, resourceNoun: "gateway", onAdd: { key, value in
                            state = .loaded(try await api.addStorageGatewayTag(profile: appState.currentProfile, region: appState.currentRegion, arn: arn, key: key, value: value))
                        }, onRemove: { key in
                            state = .loaded(try await api.removeStorageGatewayTag(profile: appState.currentProfile, region: appState.currentRegion, arn: arn, key: key))
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: arn) { await load() }
    }

    private func storageTab<Content: View>(@ViewBuilder _ content: @escaping (GatewayStorage) -> Content) -> some View {
        LoadableContent(storage, retry: { Task { await loadStorage() } }) { s in
            VStack(alignment: .leading, spacing: 0) {
                if !s.errors.isEmpty { PartialErrorsView(errors: s.errors).padding(.horizontal, 16).padding(.top, 8) }
                content(s)
            }
        }
    }

    private func details(_ g: GatewayDetail) -> some View {
        DetailTabPage(maxWidth: 900) {
            PartialErrorsView(errors: g.errors)
            DetailSection(title: "Details") {
                DetailGrid(items: [
                    DetailItem("Gateway ID", g.gatewayId),
                    DetailItem("Type", GatewayFormat.typeName(g.gatewayType), monospaced: false),
                    DetailItem("State", g.gatewayState),
                    DetailItem("Host platform", g.hostEnvironment),
                    DetailItem("EC2 instance", g.ec2InstanceId),
                    DetailItem("Capacity", g.gatewayCapacity),
                    DetailItem("Endpoint type", g.endpointType),
                    DetailItem("VPC endpoint", g.vpcEndpoint),
                    DetailItem("Time zone", g.timezone),
                    DetailItem("Software version", g.softwareVersion),
                ])
                DetailChipsField("IP addresses", g.networkInterfaces)
            }
            if let lg = g.cloudWatchLogGroupArn {
                DetailSection(title: "CloudWatch log group") { CopyableBlock(text: lg) }
            }
            DetailSection(title: "ARN") { CopyableBlock(text: g.gatewayArn) }
        }
    }

    @ViewBuilder
    private func storageResources(_ s: GatewayStorage) -> some View {
        if !s.fileShares.isEmpty {
            Table(s.fileShares) {
                TableColumn("File share") { f in Text(f.path ?? f.fileShareId ?? "-").font(.caption.monospaced().bold()) }
                TableColumn("Protocol") { f in Text(f.type ?? "-").font(.caption) }.width(min: 60, ideal: 70)
                TableColumn("Storage location") { f in Text(f.locationArn.map(ComputeFormat.arnResourceName) ?? "-").font(.caption.monospaced()).textSelection(.enabled) }
                TableColumn("ID") { f in Text(f.fileShareId ?? "-").font(.caption2.monospaced()) }
                TableColumn("Status") { f in StatusBadge(f.status ?? "-") }.width(min: 80, ideal: 100)
            }
        } else if !s.volumes.isEmpty {
            Table(s.volumes) {
                TableColumn("Volume ID") { v in Text(v.volumeId ?? "-").font(.caption.monospaced().bold()).textSelection(.enabled) }
                TableColumn("Type") { v in Text(v.volumeType ?? "-").font(.caption) }
                TableColumn("Size") { v in Text(StorageFormat.bytes(v.sizeInBytes)).font(.caption) }
                TableColumn("Attachment") { v in StatusBadge(v.attachmentStatus ?? "-") }
            }
        } else if !s.tapes.isEmpty {
            Table(s.tapes) {
                TableColumn("Barcode") { t in Text(t.barcode ?? "-").font(.caption.monospaced().bold()).textSelection(.enabled) }
                TableColumn("Size") { t in Text(StorageFormat.bytes(t.sizeInBytes)).font(.caption) }
                TableColumn("Pool") { t in Text(t.poolId ?? "-").font(.caption) }
                TableColumn("Status") { t in StatusBadge(t.status ?? "-") }
            }
        } else {
            EmptyStateView(message: "No file shares, volumes or tapes on this gateway")
        }
    }

    private func disks(_ g: GatewayDetail, _ s: GatewayStorage) -> some View {
        DetailTabPage(maxWidth: 1000) {
            if !g.cache.isEmpty {
                DetailSection(title: "Cache") { DetailGrid(items: g.cache.detailItems) }
            }
            DetailSection(title: "Local disks · \(s.disks.count)") {
                if s.disks.isEmpty { Text("No local disks reported.").font(.caption).foregroundStyle(.secondary) }
                ForEach(s.disks) { d in
                    HStack {
                        Text(d.path ?? d.diskId).font(.caption.monospaced().bold()).textSelection(.enabled)
                        Text(StorageFormat.bytes(d.sizeInBytes)).font(.caption)
                        Text(d.allocationType ?? "Unallocated").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        StatusBadge(d.status ?? "-")
                    }
                    Divider()
                }
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await api.getStorageGateway(profile: appState.currentProfile, region: appState.currentRegion, arn: arn))
        } catch {
            state = .failed(error.friendlyMessage)
        }
        await loadStorage()
    }

    private func loadStorage() async {
        do {
            storage = .loaded(try await api.getStorageGatewayStorage(profile: appState.currentProfile, region: appState.currentRegion, arn: arn))
        } catch {
            storage = .failed(error.friendlyMessage)
        }
    }
}
