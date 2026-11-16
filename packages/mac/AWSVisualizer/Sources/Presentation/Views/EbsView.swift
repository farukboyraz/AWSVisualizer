import SwiftUI

/// EBS: volumes and the snapshots this account owns, switched at the top
/// of the list panel like the console's Volumes / Snapshots pages.
struct EbsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum Mode: String, CaseIterable { case volumes = "Volumes", snapshots = "Snapshots" }

    @State private var mode: Mode = .volumes
    @State private var volumes: LoadState<[EbsVolume]> = .loading
    @State private var snapshots: LoadState<EbsSnapshotPage> = .loading
    @State private var selectedVolume: String?
    @State private var selectedSnapshot: String?
    @State private var filter = ""

    private var hasSelection: Bool { mode == .volumes ? selectedVolume != nil : selectedSnapshot != nil }

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 340, minWidth: 240, maxWidth: 520, isDetailActive: hasSelection, onBack: { selectedVolume = nil; selectedSnapshot = nil }, backTitle: mode.rawValue, detailTitle: mode == .volumes ? selectedVolume : selectedSnapshot) {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle("EBS")
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    ScreenFilterField(text: $filter, prompt: "Filter by name or ID")
                    switch mode {
                    case .volumes: volumeList
                    case .snapshots: snapshotList
                    }
                    PanelActionBar {
                        RefreshButton(compactSize: 24, help: "Refresh") { Task { await reload() } }
                    } trailing: {
                        countLabel
                    }
                }
            } detail: {
                switch mode {
                case .volumes:
                    if let selectedVolume {
                        EbsVolumeDetailView(volumeId: selectedVolume, onSnapshotCreated: { Task { await loadSnapshots() } }).id(selectedVolume)
                    } else {
                        EmptyStateView(message: "Select a volume")
                    }
                case .snapshots:
                    if case .loaded(let page) = snapshots, let snap = page.snapshots.first(where: { $0.snapshotId == selectedSnapshot }) {
                        EbsSnapshotDetailView(snapshot: snap, onChanged: { Task { await loadSnapshots() } }).id(snap.snapshotId)
                    } else {
                        EmptyStateView(message: "Select a snapshot")
                    }
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await reload()
            }
        }
    }

    @ViewBuilder
    private var countLabel: some View {
        switch mode {
        case .volumes:
            if case .loaded(let v) = volumes { Text("\(v.count) volumes").font(.caption).foregroundStyle(.secondary) }
        case .snapshots:
            if case .loaded(let p) = snapshots { Text("\(p.snapshots.count)\(p.truncated ? "+" : "") snapshots").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func matches(_ values: String?...) -> Bool {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty || values.contains { $0?.lowercased().contains(f) == true }
    }

    private var volumeList: some View {
        LoadableContent(volumes, retry: { Task { await loadVolumes() } }, emptyMessage: "No EBS volumes in this region") { items in
            List(items.filter { matches($0.name, $0.volumeId, $0.attachments.first?.instanceId) }, selection: $selectedVolume) { v in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(v.name ?? v.volumeId).font(.body.bold()).lineLimit(1)
                        Spacer()
                        StatusBadge(v.state ?? "-")
                    }
                    Text([v.volumeId, v.volumeType, v.size.map { "\($0) GiB" }, v.attachments.first?.instanceId].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 2)
                .tag(v.volumeId)
            }
            .listStyle(.sidebar)
        }
    }

    private var snapshotList: some View {
        LoadableContent(snapshots, retry: { Task { await loadSnapshots() } }, emptyMessage: "This account owns no snapshots in this region") { page in
            VStack(spacing: 0) {
                List(page.snapshots.filter { matches($0.name, $0.snapshotId, $0.volumeId, $0.description) }, selection: $selectedSnapshot) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(s.name ?? s.snapshotId).font(.body.bold()).lineLimit(1)
                            Spacer()
                            StatusBadge(s.state ?? "-")
                        }
                        Text([s.volumeSize.map { "\($0) GiB" }, s.volumeId, Formatters.formatISODate(s.startTime)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(s.snapshotId)
                }
                .listStyle(.sidebar)
                if page.truncated {
                    Label("Showing the newest 1000 snapshots.", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange).padding(6)
                }
            }
        }
    }

    private func reload() async {
        async let a: Void = loadVolumes()
        async let b: Void = loadSnapshots()
        _ = await (a, b)
    }

    private func loadVolumes() async {
        if case .loaded = volumes {} else { volumes = .loading }
        do {
            let items = try await api.getEbsVolumes(profile: appState.currentProfile, region: appState.currentRegion)
            volumes = items.isEmpty ? .empty : .loaded(items)
        } catch {
            volumes = .failed(error.friendlyMessage)
        }
    }

    private func loadSnapshots() async {
        if case .loaded = snapshots {} else { snapshots = .loading }
        do {
            let page = try await api.getEbsSnapshots(profile: appState.currentProfile, region: appState.currentRegion)
            snapshots = page.snapshots.isEmpty ? .empty : .loaded(page)
        } catch {
            snapshots = .failed(error.friendlyMessage)
        }
    }
}

private struct EbsVolumeDetailView: View {
    let volumeId: String
    let onSnapshotCreated: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case status = "Status checks"
        case snapshots = "Snapshots"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .details
    @State private var state: LoadState<EbsVolumeDetail> = .loading
    @State private var showSnapshot = false
    @State private var snapshotDescription = ""
    @State private var isCreating = false
    @State private var actionError: String?
    @State private var note: String?

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { d in
            let v = d.volume
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(title: v.name ?? v.volumeId, subtitle: "\(v.volumeId) · \(v.volumeType ?? "-") · \(v.size.map { "\($0) GiB" } ?? "-")", status: v.state, tab: $tab)
                DetailActionBar(error: actionError, note: note, onRefresh: { Task { await load() } }) {
                    AppButton("Create snapshot", kind: .confirm, systemImage: "camera", isLoading: isCreating, isDisabled: isCreating || v.state == "deleting" || v.state == "error") {
                        snapshotDescription = ""
                        showSnapshot = true
                    }
                    .popover(isPresented: $showSnapshot, arrowEdge: .bottom) { snapshotPopover(v) }
                }
                Group {
                    switch tab {
                    case .details: details(d)
                    case .status: status(d)
                    case .snapshots: snapshots(d)
                    case .tags:
                        ResourceTagsEditor(tags: v.tags, resourceNoun: "volume", onAdd: { key, value in
                            try await api.addEbsTag(profile: appState.currentProfile, region: appState.currentRegion, resourceId: volumeId, key: key, value: value)
                            await load()
                        }, onRemove: { key in
                            try await api.removeEbsTag(profile: appState.currentProfile, region: appState.currentRegion, resourceId: volumeId, key: key)
                            await load()
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: volumeId) { await load() }
    }

    private func snapshotPopover(_ v: EbsVolume) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create snapshot").font(.headline)
            Text("Takes a point-in-time, incremental snapshot of \(v.volumeId). Snapshot storage is billed per GB-month.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Description (optional)", text: $snapshotDescription)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                SecondaryButton("Cancel") { showSnapshot = false }
                AppButton("Create", kind: .confirm, systemImage: "camera", isDisabled: snapshotDescription.count > 255) {
                    showSnapshot = false
                    Task { await createSnapshot() }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func details(_ d: EbsVolumeDetail) -> some View {
        let v = d.volume
        return DetailTabPage(maxWidth: 900) {
            PartialErrorsView(errors: d.errors)
            DetailSection(title: "Details") {
                DetailGrid(items: [
                    DetailItem("Volume ID", v.volumeId),
                    DetailItem("Type", v.volumeType),
                    DetailItem("Size", v.size.map { "\($0) GiB" }),
                    DetailItem("IOPS", ComputeFormat.int(v.iops)),
                    DetailItem("Throughput", v.throughput.map { "\($0) MiB/s" }),
                    DetailItem("State", v.state),
                    DetailItem("Availability Zone", v.availabilityZone),
                    DetailItem("Encryption", v.encrypted == true ? "Encrypted" : "Not encrypted", monospaced: false),
                    DetailItem("KMS key", v.kmsKeyId.map(ComputeFormat.arnResourceName)),
                    DetailItem("Source snapshot", v.snapshotId),
                    DetailItem("Multi-Attach", ComputeFormat.bool(v.multiAttachEnabled)),
                    DetailItem("Created", Formatters.formatISODate(v.createTime), monospaced: false),
                ])
            }
            DetailSection(title: "Attached resources") {
                if v.attachments.isEmpty {
                    Text("Not attached - the volume is still billed while available.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(v.attachments.enumerated()), id: \.offset) { _, a in
                    HStack {
                        Text(a.instanceId ?? "-").font(.caption.monospaced().bold()).textSelection(.enabled)
                        Text(a.device ?? "-").font(.caption.monospaced()).foregroundStyle(.secondary)
                        if a.deleteOnTermination == true { Text("delete on termination").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Text(Formatters.formatISODate(a.attachTime)).font(.caption2).foregroundStyle(.secondary)
                        StatusBadge(a.state ?? "-")
                    }
                }
            }
        }
    }

    private func status(_ d: EbsVolumeDetail) -> some View {
        DetailTabPage(maxWidth: 900) {
            if let s = d.status {
                DetailSection(title: "Volume status") {
                    DetailGrid(items: [
                        DetailItem("Volume status", s.status),
                        DetailItem("I/O enabled", s.ioEnabled),
                        DetailItem("I/O performance", s.ioPerformance ?? "Not applicable"),
                    ])
                }
                DetailSection(title: "Events") {
                    if s.events.isEmpty { Text("No scheduled events.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(s.events.enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.type ?? "-").font(.caption.bold())
                            Text(e.description ?? "").font(.caption)
                            Text("\(Formatters.formatISODate(e.notBefore)) → \(Formatters.formatISODate(e.notAfter))").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if !s.actions.isEmpty {
                    DetailSection(title: "Required actions") {
                        ForEach(Array(s.actions.enumerated()), id: \.offset) { _, a in
                            DetailField(a.code ?? "-", a.description ?? "")
                        }
                    }
                }
            } else {
                Text("No status reported for this volume.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func snapshots(_ d: EbsVolumeDetail) -> some View {
        Group {
            if d.snapshots.isEmpty {
                EmptyStateView(message: "No snapshots of this volume")
            } else {
                Table(d.snapshots) {
                    TableColumn("Snapshot ID") { s in Text(s.snapshotId).font(.caption.monospaced()).textSelection(.enabled) }
                    TableColumn("Name") { s in Text(s.name ?? "-").font(.caption) }
                    TableColumn("Description") { s in Text(s.description ?? "-").font(.caption).lineLimit(1) }
                    TableColumn("Started") { s in Text(Formatters.formatISODate(s.startTime)).font(.caption) }
                    TableColumn("Tier") { s in Text(s.storageTier ?? "-").font(.caption) }.width(min: 60, ideal: 80)
                    TableColumn("Status") { s in
                        HStack(spacing: 4) {
                            StatusBadge(s.state ?? "-")
                            if s.state == "pending", let p = s.progress { Text(p).font(.caption2) }
                        }
                    }
                }
            }
        }
    }

    private func createSnapshot() async {
        isCreating = true
        actionError = nil
        note = nil
        do {
            let snap = try await api.createEbsSnapshot(profile: appState.currentProfile, region: appState.currentRegion, volumeId: volumeId, description: snapshotDescription)
            note = "Snapshot \(snap.snapshotId) started - it appears under Snapshots while pending."
            onSnapshotCreated()
            await load()
        } catch {
            actionError = error.friendlyMessage
        }
        isCreating = false
    }

    private func load() async {
        do {
            state = .loaded(try await api.getEbsVolume(profile: appState.currentProfile, region: appState.currentRegion, id: volumeId))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct EbsSnapshotDetailView: View {
    let snapshot: EbsSnapshot
    let onChanged: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .details

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(title: snapshot.name ?? snapshot.snapshotId, subtitle: snapshot.description, status: snapshot.state, tab: $tab)
            Group {
                switch tab {
                case .details:
                    DetailTabPage(maxWidth: 900) {
                        DetailGrid(items: [
                            DetailItem("Snapshot ID", snapshot.snapshotId),
                            DetailItem("Volume", snapshot.volumeId),
                            DetailItem("Volume size", snapshot.volumeSize.map { "\($0) GiB" }),
                            DetailItem("Status", snapshot.state),
                            DetailItem("Progress", snapshot.progress),
                            DetailItem("Started", Formatters.formatISODate(snapshot.startTime), monospaced: false),
                            DetailItem("Storage tier", snapshot.storageTier),
                            DetailItem("Encryption", snapshot.encrypted == true ? "Encrypted" : "Not encrypted", monospaced: false),
                            DetailItem("KMS key", snapshot.kmsKeyId.map(ComputeFormat.arnResourceName)),
                            DetailItem("Owner", snapshot.ownerId),
                        ])
                        if let d = snapshot.description, !d.isEmpty {
                            DetailSection(title: "Description") { Text(d).font(.caption).textSelection(.enabled) }
                        }
                    }
                case .tags:
                    ResourceTagsEditor(tags: snapshot.tags, resourceNoun: "snapshot", onAdd: { key, value in
                        try await api.addEbsTag(profile: appState.currentProfile, region: appState.currentRegion, resourceId: snapshot.snapshotId, key: key, value: value)
                        onChanged()
                    }, onRemove: { key in
                        try await api.removeEbsTag(profile: appState.currentProfile, region: appState.currentRegion, resourceId: snapshot.snapshotId, key: key)
                        onChanged()
                    })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
