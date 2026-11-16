import SwiftUI

enum LightsailItem: Hashable {
    case instance(String)
    case database(String)
    case containerService(String)
}

private struct LightsailLists {
    var instances: [LightsailInstance] = []
    var databases: [LightsailDatabase] = []
    var containerServices: [LightsailContainerService] = []
    var errors: [String] = []

    var isEmpty: Bool { instances.isEmpty && databases.isEmpty && containerServices.isEmpty }
}

/// Lightsail's home page tabs (Instances, Databases, Containers) as list
/// sections; the three lists load in parallel and one failing (e.g. a
/// region without container services) doesn't hide the others.
struct LightsailView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<LightsailLists> = .loading
    @State private var selection: LightsailItem?

    private var detailTitle: String? {
        switch selection {
        case .instance(let n), .database(let n), .containerService(let n): return n
        case nil: return nil
        }
    }

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 320, minWidth: 240, maxWidth: 500, isDetailActive: selection != nil, onBack: { selection = nil }, backTitle: "Lightsail", detailTitle: detailTitle) {
                listPanel
            } detail: {
                detail
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .instance(let name):
            LightsailInstanceDetailView(name: name).id("i-\(name)")
        case .database(let name):
            if case .loaded(let lists) = state, let db = lists.databases.first(where: { $0.name == name }) {
                LightsailDatabaseDetailView(database: db, onTagsChanged: { Task { await loadData(keepSelection: true) } }).id("d-\(name)")
            }
        case .containerService(let name):
            if case .loaded(let lists) = state, let service = lists.containerServices.first(where: { $0.name == name }) {
                LightsailContainerServiceDetailView(service: service, onTagsChanged: { Task { await loadData(keepSelection: true) } }).id("c-\(name)")
            }
        case nil:
            EmptyStateView(message: "Select an instance, database or container service")
        }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Lightsail")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No Lightsail resources in this region") { lists in
                List(selection: $selection) {
                    Section("Instances · \(lists.instances.count)") {
                        ForEach(lists.instances.matching(filter)) { i in
                            row(i.name, caption: [i.blueprintName, i.bundleId, i.publicIp].compactMap { $0 }.joined(separator: " · "), status: i.state)
                                .tag(LightsailItem.instance(i.name))
                        }
                    }
                    if !lists.databases.isEmpty {
                        Section("Databases · \(lists.databases.count)") {
                            ForEach(lists.databases.matching(filter)) { d in
                                row(d.name, caption: [d.engine, d.engineVersion].compactMap { $0 }.joined(separator: " "), status: d.state)
                                    .tag(LightsailItem.database(d.name))
                            }
                        }
                    }
                    if !lists.containerServices.isEmpty {
                        Section("Container services · \(lists.containerServices.count)") {
                            ForEach(lists.containerServices.matching(filter)) { c in
                                row(c.name, caption: [c.power, c.scale.map { "×\($0)" }].compactMap { $0 }.joined(separator: " "), status: c.state)
                                    .tag(LightsailItem.containerService(c.name))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                if !lists.errors.isEmpty {
                    Label(lists.errors.joined(separator: "\n"), systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
            }
            PanelActionBar {
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
            }
        }
    }

    private func row(_ title: String, caption: String, status: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.body.bold()).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let status { StatusBadge(status) }
            }
            if !caption.isEmpty {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func loadData(keepSelection: Bool = false) async {
        if !keepSelection { state = .loading }
        let profile = appState.currentProfile
        let region = appState.currentRegion
        async let instances = capture { try await api.getLightsailInstances(profile: profile, region: region) }
        async let databases = capture { try await api.getLightsailDatabases(profile: profile, region: region) }
        async let containers = capture { try await api.getLightsailContainerServices(profile: profile, region: region) }
        let (i, d, c) = await (instances, databases, containers)

        var lists = LightsailLists()
        switch i {
        case .success(let v): lists.instances = v
        case .failure(let e): lists.errors.append("Instances: \(e.friendlyMessage)")
        }
        switch d {
        case .success(let v): lists.databases = v
        case .failure(let e): lists.errors.append("Databases: \(e.friendlyMessage)")
        }
        switch c {
        case .success(let v): lists.containerServices = v
        case .failure(let e): lists.errors.append("Containers: \(e.friendlyMessage)")
        }
        if lists.errors.count == 3 {
            state = .failed(lists.errors.joined(separator: "\n"))
        } else {
            state = lists.isEmpty && lists.errors.isEmpty ? .empty : .loaded(lists)
        }
    }
}

private func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

// MARK: - Instance

/// An instance's Lightsail page: Connect, Networking, Storage, Snapshots,
/// Tags, with Start / Stop / Reboot.
struct LightsailInstanceDetailView: View {
    let name: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case connect = "Connect"
        case networking = "Networking"
        case storage = "Storage"
        case snapshots = "Snapshots"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .connect
    @State private var detailState: LoadState<LightsailInstanceDetail> = .loading
    @State private var pendingAction: String?
    @State private var actionError: String?

    var body: some View {
        LoadableContent(detailState, retry: { Task { await load() } }) { detail in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(
                    title: detail.name,
                    subtitle: [detail.blueprintName, detail.bundleId, detail.availabilityZone].compactMap { $0 }.joined(separator: " · "),
                    status: detail.state,
                    tab: $tab
                )
                actionBar(detail)
                Group {
                    switch tab {
                    case .connect: connectTab(detail)
                    case .networking: networkingTab(detail)
                    case .storage: storageTab(detail)
                    case .snapshots: snapshotsTab(detail)
                    case .tags:
                        ResourceTagsEditor(tags: detail.tags, resourceNoun: "instance", onAdd: { key, value in
                            try await api.addLightsailTag(profile: appState.currentProfile, region: appState.currentRegion, resourceName: name, key: key, value: value)
                            await load()
                        }, onRemove: { key in
                            try await api.removeLightsailTag(profile: appState.currentProfile, region: appState.currentRegion, resourceName: name, key: key)
                            await load()
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: name) { await load() }
    }

    private func actionBar(_ detail: LightsailInstanceDetail) -> some View {
        let running = detail.state == "running"
        let stopped = detail.state == "stopped"
        return DetailActionBar(error: actionError, onRefresh: { Task { await load() } }) {
            ConfirmedActionButton(
                title: "Start", systemImage: "play.fill",
                confirmationTitle: "Start \(detail.name)?",
                confirmationMessage: "The public IP changes unless a static IP is attached.",
                isLoading: pendingAction == "start", isDisabled: !stopped || pendingAction != nil, role: nil
            ) { Task { await run("start") } }
            ConfirmedActionButton(
                title: "Stop", systemImage: "stop.fill",
                confirmationTitle: "Stop \(detail.name)?",
                confirmationMessage: "A stopped Lightsail instance is still billed. The public IP is released unless it's static.",
                isLoading: pendingAction == "stop", isDisabled: !running || pendingAction != nil
            ) { Task { await run("stop") } }
            ConfirmedActionButton(
                title: "Reboot", systemImage: "arrow.clockwise",
                confirmationTitle: "Reboot \(detail.name)?",
                confirmationMessage: "The instance is unavailable while it restarts.",
                isLoading: pendingAction == "reboot", isDisabled: !running || pendingAction != nil
            ) { Task { await run("reboot") } }
        }
    }

    private func connectTab(_ d: LightsailInstanceDetail) -> some View {
        DetailTabPage {
            DetailSection(title: "Connect using your own SSH client") {
                if let ip = d.publicIp, let user = d.username {
                    CopyableBlock(text: "ssh -i <key.pem> \(user)@\(ip)")
                } else {
                    Text("No public IP - the instance isn't reachable from the internet right now.").font(.caption).foregroundStyle(.secondary)
                }
            }
            DetailSection(title: "Instance") {
                DetailGrid(items: [
                    DetailItem("Public IP", d.publicIp.map { d.isStaticIp ? "\($0) (static)" : $0 }),
                    DetailItem("Private IP", d.privateIp),
                    DetailItem("Username", d.username),
                    DetailItem("SSH key", d.sshKeyName),
                    DetailItem("Blueprint", d.blueprintName ?? d.blueprintId),
                    DetailItem("Bundle", d.bundleId),
                    DetailItem("vCPUs", d.cpuCount.map(String.init)),
                    DetailItem("Memory", d.ramSizeInGb.map { "\(Formatters.formatNumber($0)) GB" }),
                    DetailItem("Availability Zone", d.availabilityZone),
                    DetailItem("Created", Formatters.formatISODate(d.createdAt), monospaced: false),
                ])
            }
            DetailSection(title: "ARN") { CopyableBlock(text: d.arn) }
        }
    }

    private func networkingTab(_ d: LightsailInstanceDetail) -> some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "IP addresses") {
                DetailGrid(items: [
                    DetailItem("Public IPv4", d.publicIp),
                    DetailItem("Static IP", ComputeFormat.bool(d.isStaticIp)),
                    DetailItem("Private IPv4", d.privateIp),
                    DetailItem("IP address type", d.ipAddressType),
                    DetailItem("Monthly transfer allowance", d.monthlyTransferGb.map { "\($0) GB" }),
                ])
                if !d.ipv6Addresses.isEmpty {
                    DetailChipsField("IPv6", d.ipv6Addresses)
                }
            }
            DetailSection(title: "IPv4 / IPv6 firewall") {
                if d.ports.isEmpty {
                    Text("No open ports.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Table(d.ports) {
                        TableColumn("Protocol") { p in Text(p.protocol?.uppercased() ?? "-").font(.caption.monospaced()) }
                            .width(70)
                        TableColumn("Port") { p in Text(p.range).font(.caption.monospaced()) }
                            .width(90)
                        TableColumn("Restricted to") { p in Text(p.cidrs.isEmpty ? "Any IP address" : p.cidrs.joined(separator: ", ")).font(.caption.monospaced()) }
                        TableColumn("State") { p in StatusBadge(p.state ?? "-") }
                            .width(80)
                    }
                    .frame(minHeight: CGFloat(min(d.ports.count, 10)) * 26 + 32)
                }
            }
        }
    }

    private func storageTab(_ d: LightsailInstanceDetail) -> some View {
        DetailTabPage {
            DetailSection(title: "Disks") {
                ForEach(d.disks) { disk in
                    HStack {
                        Image(systemName: disk.isSystemDisk ? "internaldrive" : "externaldrive")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(disk.isSystemDisk ? "System disk" : disk.name).font(.body.bold())
                            Text([disk.sizeInGb.map { "\($0) GB" }, disk.path, disk.iops.map { "\($0) IOPS" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let state = disk.state { StatusBadge(state) }
                    }
                    Divider()
                }
            }
        }
    }

    private func snapshotsTab(_ d: LightsailInstanceDetail) -> some View {
        DetailTabPage {
            DetailSection(title: "Automatic snapshots") {
                Text(d.autoSnapshot.map { "Enabled · \($0)" } ?? "Not enabled").font(.caption)
            }
            DetailSection(title: "Manual snapshots · \(d.snapshots.count)") {
                if d.snapshots.isEmpty {
                    Text("No snapshots of this instance.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(d.snapshots) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.caption.monospaced().bold())
                            Text("\(Formatters.formatISODate(s.createdAt))\(s.sizeInGb.map { " · \($0) GB" } ?? "")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(s.state ?? "-")
                    }
                    Divider()
                }
            }
        }
    }

    private func run(_ action: String) async {
        pendingAction = action
        actionError = nil
        do {
            detailState = .loaded(try await api.runLightsailInstanceAction(profile: appState.currentProfile, region: appState.currentRegion, name: name, action: action))
        } catch {
            actionError = error.friendlyMessage
        }
        pendingAction = nil
    }

    private func load() async {
        do {
            detailState = .loaded(try await api.getLightsailInstance(profile: appState.currentProfile, region: appState.currentRegion, name: name))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Database

private struct LightsailDatabaseDetailView: View {
    let database: LightsailDatabase
    let onTagsChanged: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case connectivity = "Connectivity & security"
        case details = "Details"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .connectivity

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(title: database.name, subtitle: [database.engine, database.engineVersion].compactMap { $0 }.joined(separator: " "), status: database.state, tab: $tab)
            Group {
                switch tab {
                case .connectivity:
                    DetailTabPage {
                        DetailSection(title: "Endpoint") {
                            CopyableBlock(text: database.endpoint ?? "-")
                        }
                        DetailGrid(items: [
                            DetailItem("User name", database.masterUsername),
                            DetailItem("Database name", database.masterDatabaseName),
                            DetailItem("Public mode", database.publiclyAccessible ? "Enabled" : "Disabled", monospaced: false),
                        ])
                    }
                case .details:
                    DetailTabPage {
                        DetailGrid(items: [
                            DetailItem("Engine", [database.engine, database.engineVersion].compactMap { $0 }.joined(separator: " ")),
                            DetailItem("Bundle", database.bundleId),
                            DetailItem("Availability Zone", database.availabilityZone),
                            DetailItem("Automatic backups", ComputeFormat.bool(database.backupRetentionEnabled)),
                            DetailItem("Backup window (UTC)", database.preferredBackupWindow),
                            DetailItem("Maintenance window (UTC)", database.preferredMaintenanceWindow),
                            DetailItem("Created", Formatters.formatISODate(database.createdAt), monospaced: false),
                        ])
                        DetailSection(title: "ARN") { CopyableBlock(text: database.arn) }
                    }
                case .tags:
                    ResourceTagsEditor(tags: database.tags, resourceNoun: "database", onAdd: { key, value in
                        try await api.addLightsailTag(profile: appState.currentProfile, region: appState.currentRegion, resourceName: database.name, key: key, value: value)
                        onTagsChanged()
                    }, onRemove: { key in
                        try await api.removeLightsailTag(profile: appState.currentProfile, region: appState.currentRegion, resourceName: database.name, key: key)
                        onTagsChanged()
                    })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Container service

private struct LightsailContainerServiceDetailView: View {
    let service: LightsailContainerService
    let onTagsChanged: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case deployment = "Deployment"
        case details = "Details"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .deployment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(title: service.name, subtitle: "Container service · \(service.power ?? "-") ×\(service.scale ?? 0)", status: service.isDisabled ? "Disabled" : service.state, tab: $tab)
            Group {
                switch tab {
                case .deployment:
                    DetailTabPage {
                        DetailSection(title: "Public domain") {
                            if let url = service.url {
                                CopyableBlock(text: url)
                                ExternalLinkButton(title: "Open in browser", urlString: url)
                            } else {
                                Text("No active deployment.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        DetailSection(title: "Current deployment containers") {
                            if service.containers.isEmpty {
                                Text("No containers deployed.").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(service.containers, id: \.self) { c in
                                Text(c).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                case .details:
                    DetailTabPage {
                        DetailGrid(items: [
                            DetailItem("Power", service.power),
                            DetailItem("Scale", service.scale.map(String.init)),
                            DetailItem("State", service.state),
                            DetailItem("Private domain", service.privateDomainName),
                            DetailItem("Created", Formatters.formatISODate(service.createdAt), monospaced: false),
                        ])
                        DetailSection(title: "ARN") { CopyableBlock(text: service.arn) }
                    }
                case .tags:
                    ResourceTagsEditor(tags: service.tags, resourceNoun: "container service", onAdd: { key, value in
                        try await api.addLightsailTag(profile: appState.currentProfile, region: appState.currentRegion, resourceName: service.name, key: key, value: value)
                        onTagsChanged()
                    }, onRemove: { key in
                        try await api.removeLightsailTag(profile: appState.currentProfile, region: appState.currentRegion, resourceName: service.name, key: key)
                        onTagsChanged()
                    })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
