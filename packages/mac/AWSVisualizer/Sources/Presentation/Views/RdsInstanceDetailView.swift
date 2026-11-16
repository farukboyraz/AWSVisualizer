import SwiftUI

/// Mirrors a DB instance's console page - same tab names and order:
/// Connectivity & security, Monitoring, Logs & events, Configuration,
/// Maintenance & backups, Tags - plus the console's Start/Stop/Reboot
/// actions above the tabs.
struct RdsInstanceDetailView: View {
    let dbInstanceId: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case connectivity = "Connectivity & security"
        case monitoring = "Monitoring"
        case logs = "Logs & events"
        case configuration = "Configuration"
        case maintenance = "Maintenance & backups"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .connectivity
    @State private var detailState: LoadState<RdsInstanceDetail> = .loading
    @State private var pendingAction: String?
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeader(
                        title: detail.dbInstanceId,
                        subtitle: "\(detail.engine) \(detail.engineVersion) · \(detail.dbInstanceClass)",
                        status: detail.status,
                        tab: $tab
                    )
                    actionBar(detail)

                    Group {
                        switch tab {
                        case .connectivity:
                            RdsConnectivityTab(detail: detail)
                        case .monitoring:
                            RdsMonitoringTab(dbInstanceId: dbInstanceId)
                        case .logs:
                            RdsLogsTab(dbInstanceId: dbInstanceId)
                        case .configuration:
                            RdsConfigurationTab(detail: detail, onUpdated: { detailState = .loaded($0) })
                        case .maintenance:
                            RdsMaintenanceTab(detail: detail, onUpdated: { detailState = .loaded($0) })
                        case .tags:
                            ResourceTagsEditor(tags: detail.tags, resourceNoun: "database", onAdd: { key, value in
                                detailState = .loaded(try await api.addRDSTag(profile: appState.currentProfile, region: appState.currentRegion, id: dbInstanceId, arn: detail.dbInstanceArn, key: key, value: value))
                            }, onRemove: { key in
                                detailState = .loaded(try await api.removeRDSTag(profile: appState.currentProfile, region: appState.currentRegion, id: dbInstanceId, arn: detail.dbInstanceArn, key: key))
                            })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: dbInstanceId) {
            await loadDetail()
        }
    }

    private func actionBar(_ detail: RdsInstanceDetail) -> some View {
        let isAvailable = detail.status == "available"
        let isStopped = detail.status == "stopped"
        // Aurora instances are started/stopped through their cluster.
        let isClusterMember = detail.dbClusterIdentifier != nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ConfirmedActionButton(
                    title: "Start",
                    systemImage: "play.fill",
                    confirmationTitle: "Start \(detail.dbInstanceId)?",
                    confirmationMessage: "Billing for instance hours resumes once the database is running.",
                    isLoading: pendingAction == "start",
                    isDisabled: !isStopped || isClusterMember || pendingAction != nil,
                    role: nil
                ) { Task { await run("start") } }
                ConfirmedActionButton(
                    title: "Stop",
                    systemImage: "stop.fill",
                    confirmationTitle: "Stop \(detail.dbInstanceId)?",
                    confirmationMessage: "Connections are dropped. AWS automatically starts a stopped database again after 7 days.",
                    isLoading: pendingAction == "stop",
                    isDisabled: !isAvailable || isClusterMember || pendingAction != nil
                ) { Task { await run("stop") } }
                ConfirmedActionButton(
                    title: "Reboot",
                    systemImage: "arrow.clockwise",
                    confirmationTitle: "Reboot \(detail.dbInstanceId)?",
                    confirmationMessage: "The database is unavailable for the duration of the reboot.",
                    isLoading: pendingAction == "reboot",
                    isDisabled: !isAvailable || pendingAction != nil
                ) { Task { await run("reboot") } }
                Spacer()
                RefreshButton(compactSize: 22, help: "Refresh") { Task { await loadDetail() } }
            }
            .controlSize(.small)
            if isClusterMember {
                Text("Part of Aurora cluster \(detail.dbClusterIdentifier ?? "") - start/stop the cluster in the AWS console.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func run(_ action: String) async {
        pendingAction = action
        actionError = nil
        do {
            detailState = .loaded(try await api.setRDSInstanceState(profile: appState.currentProfile, region: appState.currentRegion, id: dbInstanceId, action: action))
        } catch {
            actionError = error.friendlyMessage
        }
        pendingAction = nil
    }

    private func loadDetail() async {
        do {
            detailState = .loaded(try await api.getRDSInstanceDetail(profile: appState.currentProfile, region: appState.currentRegion, id: dbInstanceId))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

private struct RdsConnectivityTab: View {
    let detail: RdsInstanceDetail

    var body: some View {
        DetailTabPage {
            DetailSection(title: "Endpoint & port") {
                if let endpoint = detail.endpoint {
                    CopyableBlock(text: endpoint)
                } else {
                    Text("No endpoint yet - the instance is still being created.").font(.caption).foregroundStyle(.secondary)
                }
                DetailField("Port", detail.port.map(String.init) ?? "-")
            }
            DetailSection(title: "Networking") {
                HStack(spacing: 24) {
                    DetailField("Availability zone", detail.availabilityZone ?? "-")
                    if let secondary = detail.secondaryAvailabilityZone { DetailField("Standby AZ", secondary) }
                    DetailField("VPC", detail.vpcId ?? "-")
                }
                DetailField("Subnet group", detail.subnetGroupName ?? "-")
                DetailField("Subnets", detail.subnets.joined(separator: "\n"))
                DetailField("Publicly accessible", detail.publiclyAccessible ? "Yes" : "No")
            }
            DetailSection(title: "Security") {
                DetailField("VPC security groups", detail.securityGroups.joined(separator: "\n"))
                HStack(spacing: 24) {
                    DetailField("Certificate authority", detail.caCertificateIdentifier ?? "-")
                    DetailField("IAM DB authentication", detail.iamAuthEnabled ? "Enabled" : "Disabled")
                }
            }
        }
    }
}

private struct RdsMonitoringTab: View {
    let dbInstanceId: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<RdsMetricsSummary> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { m in
            DetailTabPage(maxWidth: 1200) {
                MetricChartGrid(charts: charts, reloadKey: dbInstanceId)
                Text("Last 24 hours")
                    .font(.subheadline.bold())
                    .padding(.top, 8)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    MetricTile(title: "CPU utilization", value: "\(Formatters.formatNumber(m.cpuUtilizationAverage))%", caption: "avg · max \(Formatters.formatNumber(m.cpuUtilizationMax))%", tint: (m.cpuUtilizationMax ?? 0) > 85 ? .orange : .primary)
                    MetricTile(title: "DB connections", value: Formatters.formatNumber(m.databaseConnectionsAverage), caption: "avg · max \(Formatters.formatNumber(m.databaseConnectionsMax, decimals: 0))")
                    MetricTile(title: "Free storage", value: Formatters.formatByteCount(m.freeStorageSpaceMin), caption: "lowest")
                    MetricTile(title: "Freeable memory", value: Formatters.formatByteCount(m.freeableMemoryMin), caption: "lowest")
                    MetricTile(title: "Read IOPS", value: Formatters.formatNumber(m.readIopsAverage), caption: "avg")
                    MetricTile(title: "Write IOPS", value: Formatters.formatNumber(m.writeIopsAverage), caption: "avg")
                }
                HStack {
                    Spacer()
                    RefreshButton("Refresh") { Task { await load() } }
                }
            }
        }
        .task(id: dbInstanceId) { await load() }
    }

    /// The console's Monitoring graphs (AWS/RDS, per instance).
    private var charts: [MetricChartSpec] {
        let dims = ["DBInstanceIdentifier": dbInstanceId]
        return [
            MetricChartSpec("CPU utilization", unit: "%", namespace: "AWS/RDS", dimensions: dims, [("CPUUtilization", "Average", nil)]),
            MetricChartSpec("Database connections", namespace: "AWS/RDS", dimensions: dims, [("DatabaseConnections", "Maximum", nil)]),
            MetricChartSpec("Free storage space", unit: "Bytes", namespace: "AWS/RDS", dimensions: dims, [("FreeStorageSpace", "Minimum", nil)]),
            MetricChartSpec("Freeable memory", unit: "Bytes", namespace: "AWS/RDS", dimensions: dims, [("FreeableMemory", "Minimum", nil)]),
            MetricChartSpec("IOPS", namespace: "AWS/RDS", dimensions: dims, [("ReadIOPS", "Average", "Read"), ("WriteIOPS", "Average", "Write")]),
            MetricChartSpec("Latency", unit: "Seconds", namespace: "AWS/RDS", dimensions: dims, [("ReadLatency", "Average", "Read"), ("WriteLatency", "Average", "Write")]),
        ]
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await api.getRDSMetrics(profile: appState.currentProfile, region: appState.currentRegion, id: dbInstanceId))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct RdsLogsTab: View {
    let dbInstanceId: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var eventsState: LoadState<[RdsEvent]> = .loading
    @State private var logsState: LoadState<[RdsLogFile]> = .loading
    @State private var viewingLog: RdsLogFile?

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Recent events") {
                Text("Last 7 days").font(.caption).foregroundStyle(.tertiary)
                LoadableContent(eventsState, retry: { Task { await loadEvents() } }, emptyMessage: "No events in the last 7 days", minHeight: 80) { events in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Text(Formatters.formatISODate(event.date))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 140, alignment: .leading)
                                Text(event.message)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                if let category = event.categories.first {
                                    Text(category).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                }
            }

            DetailSection(title: "Logs") {
                LoadableContent(logsState, retry: { Task { await loadLogs() } }, emptyMessage: "No log files", minHeight: 80) { files in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            HStack {
                                Image(systemName: "doc.plaintext").foregroundStyle(.secondary)
                                Text(file.logFileName).font(.caption.monospaced())
                                Spacer()
                                Text(Formatters.formatBytes(file.size)).font(.caption2).foregroundStyle(.secondary)
                                Text(Formatters.formatISODate(file.lastWritten)).font(.caption2).foregroundStyle(.secondary)
                                    .frame(width: 140, alignment: .trailing)
                                SecondaryButton("View", systemImage: "doc.text.magnifyingglass") { viewingLog = file }
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
            }
        }
        .task(id: dbInstanceId) {
            async let events: Void = loadEvents()
            async let logs: Void = loadLogs()
            _ = await (events, logs)
        }
        .sheet(item: $viewingLog) { file in
            RdsLogViewer(dbInstanceId: dbInstanceId, file: file)
        }
    }

    private func loadEvents() async {
        eventsState = .loading
        do {
            let events = try await api.getRDSEvents(profile: appState.currentProfile, region: appState.currentRegion, id: dbInstanceId)
            eventsState = events.isEmpty ? .empty : .loaded(events)
        } catch {
            eventsState = .failed(error.friendlyMessage)
        }
    }

    private func loadLogs() async {
        logsState = .loading
        do {
            let files = try await api.getRDSLogFiles(profile: appState.currentProfile, region: appState.currentRegion, id: dbInstanceId)
            logsState = files.isEmpty ? .empty : .loaded(files)
        } catch {
            logsState = .failed(error.friendlyMessage)
        }
    }
}

private struct RdsLogViewer: View {
    let dbInstanceId: String
    let file: RdsLogFile

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var state: LoadState<RdsLogContent> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(file.logFileName).font(.headline.monospaced())
                Spacer()
                RefreshButton(compactSize: 22, help: "Reload") { Task { await load() } }
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
            LoadableContent(state, retry: { Task { await load() } }) { log in
                VStack(alignment: .leading, spacing: 4) {
                    if log.truncated {
                        Text("Showing the last 500 lines.").font(.caption).foregroundStyle(.secondary)
                    }
                    SelectableTextView(attributedString: NSAttributedString(
                        string: log.content.isEmpty ? "(empty)" : log.content,
                        attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]
                    ))
                }
            }
        }
        .padding()
        .frame(minWidth: 760, idealWidth: 960, minHeight: 480, idealHeight: 640)
        .task { await load() }
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await api.getRDSLogTail(profile: appState.currentProfile, region: appState.currentRegion, id: dbInstanceId, file: file.logFileName))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct RdsConfigurationTab: View {
    let detail: RdsInstanceDetail
    var onUpdated: (RdsInstanceDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var isToggling = false
    @State private var error: String?

    var body: some View {
        DetailTabPage {
            DetailSection(title: "Instance") {
                HStack(spacing: 24) {
                    DetailField("Engine", "\(detail.engine) \(detail.engineVersion)")
                    DetailField("Class", detail.dbInstanceClass)
                    DetailField("Multi-AZ", detail.multiAZ ? "Yes" : "No")
                }
                DetailField("ARN", detail.dbInstanceArn)
                HStack(spacing: 24) {
                    DetailField("Master username", detail.masterUsername ?? "-")
                    DetailField("DB name", detail.dbName ?? "-")
                    DetailField("Created", Formatters.formatISODate(detail.createdAt), monospaced: false)
                }
                DetailField("Parameter groups", detail.parameterGroups.joined(separator: "\n"))
                DetailField("Option groups", detail.optionGroups.joined(separator: "\n"))
                DetailField("Performance Insights", detail.performanceInsightsEnabled ? "Enabled" : "Disabled")
                if !detail.pendingModifiedValues.isEmpty {
                    DetailField("Pending modifications", detail.pendingModifiedValues.joined(separator: "\n"))
                }
            }

            DetailSection(title: "Storage") {
                HStack(spacing: 24) {
                    DetailField("Type", detail.storageType)
                    DetailField("Allocated", "\(detail.allocatedStorage) GiB")
                    DetailField("Autoscaling max", detail.maxAllocatedStorage.map { "\($0) GiB" } ?? "Off")
                    if let iops = detail.iops { DetailField("Provisioned IOPS", "\(iops)") }
                }
                DetailField("Encryption", detail.storageEncrypted ? "Enabled\(detail.kmsKeyId.map { " (\($0))" } ?? "")" : "Not enabled")
            }

            DetailSection(title: "Deletion protection", spacing: 10) {
                LabeledSwitchBox(title: "Prevent this database from being deleted", isOn: Binding(
                    get: { detail.deletionProtection },
                    set: { newValue in Task { await setDeletionProtection(newValue) } }
                ), onColor: .green)
                .disabled(isToggling)
                .frame(maxWidth: 460)
                Text("Applied immediately, without a restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func setDeletionProtection(_ enabled: Bool) async {
        isToggling = true
        error = nil
        do {
            onUpdated(try await api.modifyRDSInstance(profile: appState.currentProfile, region: appState.currentRegion, id: detail.dbInstanceId, deletionProtection: enabled))
        } catch {
            self.error = error.friendlyMessage
        }
        isToggling = false
    }
}

private struct RdsMaintenanceTab: View {
    let detail: RdsInstanceDetail
    var onUpdated: (RdsInstanceDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var retention = 1
    @State private var isSavingRetention = false
    @State private var retentionError: String?
    @State private var retentionSaved = false

    @State private var snapshotsState: LoadState<[RdsSnapshot]> = .loading
    @State private var newSnapshotId = ""
    @State private var isCreatingSnapshot = false
    @State private var snapshotMessage: String?
    @State private var snapshotError: String?

    var body: some View {
        DetailTabPage(maxWidth: 860) {
            DetailSection(title: "Maintenance") {
                HStack(spacing: 24) {
                    DetailField("Maintenance window", detail.preferredMaintenanceWindow ?? "-")
                    DetailField("Auto minor version upgrade", detail.autoMinorVersionUpgrade ? "Enabled" : "Disabled")
                }
            }

            DetailSection(title: "Backup", spacing: 10) {
                HStack(spacing: 24) {
                    DetailField("Backup window", detail.preferredBackupWindow ?? "-")
                    DetailField("Latest restorable time", Formatters.formatISODate(detail.latestRestorableTime), monospaced: false)
                }
                if detail.backupRetentionPeriod == 0 {
                    Text("Automated backups are disabled on this instance. Turning them on causes an outage, so it's left to the AWS console.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    HStack(spacing: 10) {
                        Text("Retention period")
                        Stepper("\(retention) day\(retention == 1 ? "" : "s")", value: $retention, in: 1...35)
                        SaveButton("Save", isLoading: isSavingRetention, isDisabled: retention == detail.backupRetentionPeriod) {
                            Task { await saveRetention() }
                        }
                        if retentionSaved {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    if let retentionError {
                        Text(retentionError).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            DetailSection(title: "Snapshots", spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Snapshot name", text: $newSnapshotId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                    NewButton("Take Snapshot", systemImage: "camera", isLoading: isCreatingSnapshot, isDisabled: newSnapshotId.trimmingCharacters(in: .whitespaces).isEmpty || detail.status != "available") {
                        Task { await createSnapshot() }
                    }
                    Spacer()
                    RefreshButton(compactSize: 22, help: "Refresh") { Task { await loadSnapshots() } }
                }
                if let snapshotError { Text(snapshotError).font(.caption).foregroundStyle(.red) }
                if let snapshotMessage { Text(snapshotMessage).font(.caption).foregroundStyle(.green) }

                LoadableContent(snapshotsState, retry: { Task { await loadSnapshots() } }, emptyMessage: "No snapshots", minHeight: 80) { snapshots in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(snapshots) { snapshot in
                            HStack(spacing: 10) {
                                Text(snapshot.snapshotId)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                Spacer()
                                if let type = snapshot.snapshotType { Text(type).font(.caption2).foregroundStyle(.secondary) }
                                if let status = snapshot.status {
                                    StatusBadge(status == "creating" ? "creating \(snapshot.percentProgress ?? 0)%" : status)
                                }
                                Text(Formatters.formatISODate(snapshot.createdAt))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 140, alignment: .trailing)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
            }
        }
        .task(id: detail.dbInstanceId) {
            retention = max(detail.backupRetentionPeriod, 1)
            newSnapshotId = defaultSnapshotName
            await loadSnapshots()
        }
    }

    private var defaultSnapshotName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "\(detail.dbInstanceId)-manual-\(formatter.string(from: Date()))"
    }

    private func saveRetention() async {
        isSavingRetention = true
        retentionError = nil
        retentionSaved = false
        do {
            onUpdated(try await api.modifyRDSInstance(profile: appState.currentProfile, region: appState.currentRegion, id: detail.dbInstanceId, backupRetentionPeriod: retention))
            retentionSaved = true
        } catch {
            retentionError = error.friendlyMessage
        }
        isSavingRetention = false
    }

    private func loadSnapshots() async {
        snapshotsState = .loading
        do {
            let snapshots = try await api.getRDSSnapshots(profile: appState.currentProfile, region: appState.currentRegion, id: detail.dbInstanceId)
            snapshotsState = snapshots.isEmpty ? .empty : .loaded(snapshots)
        } catch {
            snapshotsState = .failed(error.friendlyMessage)
        }
    }

    private func createSnapshot() async {
        isCreatingSnapshot = true
        snapshotError = nil
        snapshotMessage = nil
        do {
            try await api.createRDSSnapshot(profile: appState.currentProfile, region: appState.currentRegion, id: detail.dbInstanceId, snapshotId: newSnapshotId.trimmingCharacters(in: .whitespaces))
            snapshotMessage = "Snapshot started - it appears below as \"creating\"."
            newSnapshotId = defaultSnapshotName
            await loadSnapshots()
        } catch {
            snapshotError = error.friendlyMessage
        }
        isCreatingSnapshot = false
    }
}
