import SwiftUI

private enum BackupItem: Hashable {
    case jobs
    case plan(String)
    case vault(String)
    case resource(String)
}

/// AWS Backup: the list panel groups backup plans, vaults and protected
/// resources (plus a Jobs entry) the way the console's left menu does.
struct BackupView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<BackupOverview> = .loading
    @State private var selection: BackupItem?

    private var detailTitle: String? {
        guard case .loaded(let o) = state else { return nil }
        switch selection {
        case .jobs: return "Jobs"
        case .plan(let id): return o.plans.first { $0.backupPlanId == id }?.backupPlanName
        case .vault(let name): return name
        case .resource(let arn): return o.protectedResources.first { $0.resourceArn == arn }?.resourceName ?? ComputeFormat.arnResourceName(arn)
        case nil: return nil
        }
    }

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 320, minWidth: 240, maxWidth: 500, isDetailActive: selection != nil, onBack: { selection = nil }, backTitle: "Backup", detailTitle: detailTitle) {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle("AWS Backup")
                    ScreenFilterField(text: $filter)
                    LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No backup plans or vaults in this region") { o in
                        List(selection: $selection) {
                            Label("Jobs (last 30 days)", systemImage: "clock.arrow.circlepath").tag(BackupItem.jobs)
                            Section("Backup plans · \(o.plans.count)") {
                                ForEach(o.plans.matching(filter)) { p in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.backupPlanName ?? p.backupPlanId).font(.body.bold()).lineLimit(1)
                                        Text("Last run \(p.lastExecutionDate.map(Formatters.formatISODate) ?? "never")").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                    .tag(BackupItem.plan(p.backupPlanId))
                                }
                            }
                            Section("Backup vaults · \(o.vaults.count)") {
                                ForEach(o.vaults.matching(filter)) { v in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(v.backupVaultName).font(.body.bold()).lineLimit(1)
                                            Text("\(v.numberOfRecoveryPoints ?? 0) recovery points").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if v.locked == true { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Vault lock") }
                                    }
                                    .padding(.vertical, 2)
                                    .tag(BackupItem.vault(v.backupVaultName))
                                }
                            }
                            Section("Protected resources · \(o.protectedResources.count)") {
                                ForEach(o.protectedResources.matching(filter)) { r in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.resourceName ?? ComputeFormat.arnResourceName(r.resourceArn)).font(.body).lineLimit(1).truncationMode(.middle)
                                        Text("\(r.resourceType ?? "-") · \(Formatters.formatISODate(r.lastBackupTime))").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                    .tag(BackupItem.resource(r.resourceArn))
                                }
                            }
                        }
                        .listStyle(.sidebar)
                        PartialErrorsView(errors: o.errors).padding(.horizontal, 12).padding(.vertical, 4)
                    }
                    PanelActionBar {
                        RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
                    }
                }
            } detail: {
                switch selection {
                case .jobs:
                    BackupJobsView()
                case .plan(let id):
                    BackupPlanDetailView(planId: id).id(id)
                case .vault(let name):
                    BackupVaultDetailView(vaultName: name).id(name)
                case .resource(let arn):
                    if case .loaded(let o) = state, let r = o.protectedResources.first(where: { $0.resourceArn == arn }) {
                        ProtectedResourceView(resource: r, onOpenVault: { selection = .vault($0) })
                    }
                case nil:
                    EmptyStateView(message: "Select a plan, vault, resource or Jobs")
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
            let o = try await api.getBackupOverview(profile: appState.currentProfile, region: appState.currentRegion)
            state = o.plans.isEmpty && o.vaults.isEmpty && o.protectedResources.isEmpty && o.errors.isEmpty ? .empty : .loaded(o)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct ProtectedResourceView: View {
    let resource: BackupProtectedResource
    let onOpenVault: (String) -> Void

    enum DetailTab: String, CaseIterable { case details = "Details" }
    @State private var tab: DetailTab = .details

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(title: resource.resourceName ?? ComputeFormat.arnResourceName(resource.resourceArn), subtitle: resource.resourceType, tab: $tab)
            DetailTabPage(maxWidth: 900) {
                DetailGrid(items: [
                    DetailItem("Resource type", resource.resourceType),
                    DetailItem("Last backup", Formatters.formatISODate(resource.lastBackupTime), monospaced: false),
                    DetailItem("Last backup vault", resource.lastBackupVault),
                ])
                if let vault = resource.lastBackupVault {
                    AppButton("Open vault \(vault)", kind: .open) { onOpenVault(vault) }
                }
                DetailSection(title: "Resource ARN") { CopyableBlock(text: resource.resourceArn) }
            }
        }
    }
}

private struct BackupPlanDetailView: View {
    let planId: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case rules = "Backup rules"
        case assignments = "Resource assignments"
        case details = "Details"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .rules
    @State private var state: LoadState<BackupPlanDetail> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { p in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(title: p.backupPlanName ?? p.backupPlanId, subtitle: "\(p.rules.count) rules · \(p.selections.count) resource assignments", tab: $tab)
                Group {
                    switch tab {
                    case .rules:
                        DetailTabPage(maxWidth: 1000) {
                            if p.rules.isEmpty { Text("This plan has no rules.").font(.caption).foregroundStyle(.secondary) }
                            ForEach(p.rules) { r in
                                DetailSection(title: r.ruleName) {
                                    DetailGrid(items: [
                                        DetailItem("Schedule", r.schedule.map { "\($0)\(r.timezone.map { " (\($0))" } ?? "")" } ?? "On demand"),
                                        DetailItem("Target vault", r.targetVault),
                                        DetailItem("Start within", r.startWindowMinutes.map { "\($0) min" }),
                                        DetailItem("Complete within", r.completionWindowMinutes.map { "\($0) min" }),
                                        DetailItem("Cold storage after", r.moveToColdStorageAfterDays.map { "\($0) days" } ?? "Never"),
                                        DetailItem("Retention", r.deleteAfterDays.map { "\($0) days" } ?? "Always"),
                                        DetailItem("Continuous backup (PITR)", ComputeFormat.bool(r.continuousBackup)),
                                    ])
                                    if !r.copyTo.isEmpty { DetailChipsField("Copy to", r.copyTo) }
                                }
                                Divider()
                            }
                        }
                    case .assignments:
                        DetailTabPage(maxWidth: 1000) {
                            if p.selections.isEmpty { Text("No resources are assigned - the plan backs up nothing.").font(.caption).foregroundStyle(.secondary) }
                            ForEach(p.selections) { s in
                                DetailSection(title: s.selectionName ?? s.selectionId) {
                                    DetailField("IAM role", s.iamRoleArn.map(ComputeFormat.arnResourceName) ?? "-")
                                    if !s.resources.isEmpty { DetailChipsField("Include resources", s.resources) }
                                    if !s.notResources.isEmpty { DetailChipsField("Exclude resources", s.notResources) }
                                    if !s.conditions.isEmpty { DetailChipsField("Conditions", s.conditions) }
                                }
                                Divider()
                            }
                        }
                    case .details:
                        DetailTabPage(maxWidth: 900) {
                            DetailGrid(items: [
                                DetailItem("Plan ID", p.backupPlanId),
                                DetailItem("Version", p.versionId),
                                DetailItem("Created", Formatters.formatISODate(p.creationDate), monospaced: false),
                                DetailItem("Last run", Formatters.formatISODate(p.lastExecutionDate), monospaced: false),
                            ])
                            if !p.advancedSettings.isEmpty { DetailChipsField("Advanced settings", p.advancedSettings) }
                            if let arn = p.backupPlanArn { DetailSection(title: "ARN") { CopyableBlock(text: arn) } }
                        }
                    case .tags:
                        ResourceTagsEditor(tags: p.tags, resourceNoun: "backup plan", onAdd: { key, value in
                            try await api.addBackupTag(profile: appState.currentProfile, region: appState.currentRegion, arn: p.backupPlanArn ?? "", key: key, value: value)
                            await load()
                        }, onRemove: { key in
                            try await api.removeBackupTag(profile: appState.currentProfile, region: appState.currentRegion, arn: p.backupPlanArn ?? "", key: key)
                            await load()
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: planId) { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await api.getBackupPlan(profile: appState.currentProfile, region: appState.currentRegion, id: planId))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct BackupVaultDetailView: View {
    let vaultName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case recoveryPoints = "Recovery points"
        case details = "Details"
        case policy = "Access policy"
        case notifications = "Notifications"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .recoveryPoints
    @State private var state: LoadState<BackupVaultDetail> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { v in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(title: v.backupVaultName, subtitle: "\(v.numberOfRecoveryPoints ?? 0) recovery points\(v.locked == true ? " · locked" : "")", status: v.vaultState, tab: $tab)
                if !v.errors.isEmpty { PartialErrorsView(errors: v.errors).padding(.horizontal, 16).padding(.vertical, 4) }
                Group {
                    switch tab {
                    case .recoveryPoints:
                        if v.recoveryPoints.isEmpty {
                            EmptyStateView(message: "No recovery points in this vault")
                        } else {
                            VStack(spacing: 0) {
                                Table(v.recoveryPoints) {
                                    TableColumn("Resource") { r in
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(r.resourceName ?? r.resourceArn.map(ComputeFormat.arnResourceName) ?? "-").font(.caption.bold()).lineLimit(1)
                                            Text(r.resourceType ?? "-").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    TableColumn("Created") { r in Text(Formatters.formatISODate(r.creationDate)).font(.caption) }
                                    TableColumn("Size") { r in Text(StorageFormat.bytes(r.backupSizeInBytes)).font(.caption) }.width(min: 60, ideal: 80)
                                    TableColumn("Expires") { r in Text(r.deleteAt.map(Formatters.formatISODate) ?? "Never").font(.caption) }
                                    TableColumn("Status") { r in StatusBadge(r.status ?? "-") }.width(min: 80, ideal: 100)
                                    TableColumn("ARN") { r in Text(r.recoveryPointArn).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                                }
                                if v.recoveryPointsTruncated {
                                    Label("Showing the first 500 recovery points.", systemImage: "exclamationmark.triangle")
                                        .font(.caption2).foregroundStyle(.orange).padding(6)
                                }
                            }
                        }
                    case .details:
                        DetailTabPage(maxWidth: 900) {
                            DetailGrid(items: [
                                DetailItem("Vault type", v.vaultType),
                                DetailItem("State", v.vaultState),
                                DetailItem("Encryption key", v.encryptionKeyArn.map(ComputeFormat.arnResourceName)),
                                DetailItem("Created", Formatters.formatISODate(v.creationDate), monospaced: false),
                                DetailItem("Vault lock", v.locked == true ? "Locked" : "Not locked", monospaced: false),
                                DetailItem("Min retention", v.minRetentionDays.map { "\($0) days" }),
                                DetailItem("Max retention", v.maxRetentionDays.map { "\($0) days" }),
                                DetailItem("Lock date (immutable from)", v.lockDate.map(Formatters.formatISODate), monospaced: false),
                            ])
                            if let arn = v.backupVaultArn { DetailSection(title: "ARN") { CopyableBlock(text: arn) } }
                        }
                    case .policy:
                        PolicyDocumentView(policy: v.accessPolicy, emptyMessage: "No vault access policy.")
                    case .notifications:
                        DetailTabPage(maxWidth: 900) {
                            if let n = v.notifications {
                                DetailField("SNS topic", n.snsTopicArn ?? "-")
                                DetailChipsField("Events", n.events)
                            } else {
                                Text("No notifications configured for this vault.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    case .tags:
                        ResourceTagsEditor(tags: v.tags, resourceNoun: "vault", onAdd: { key, value in
                            try await api.addBackupTag(profile: appState.currentProfile, region: appState.currentRegion, arn: v.backupVaultArn ?? "", key: key, value: value)
                            await load()
                        }, onRemove: { key in
                            try await api.removeBackupTag(profile: appState.currentProfile, region: appState.currentRegion, arn: v.backupVaultArn ?? "", key: key)
                            await load()
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
            state = .loaded(try await api.getBackupVault(profile: appState.currentProfile, region: appState.currentRegion, name: vaultName))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct BackupJobsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case backup = "Backup jobs"
        case restore = "Restore jobs"
        case copy = "Copy jobs"

        var kind: String {
            switch self {
            case .backup: return "backup"
            case .restore: return "restore"
            case .copy: return "copy"
            }
        }
    }

    @State private var tab: DetailTab = .backup
    @State private var state: LoadState<[BackupJobInfo]> = .loading
    @State private var failedOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(title: "Jobs", subtitle: "Created in the last 30 days", tab: $tab)
            DetailActionBar(onRefresh: { Task { await load() } }) {
                Toggle("Failed / aborted only", isOn: $failedOnly).toggleStyle(.checkbox).font(.caption)
            }
            LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No \(tab.rawValue.lowercased()) in the last 30 days") { jobs in
                let shown = failedOnly ? jobs.filter { ["FAILED", "ABORTED", "EXPIRED", "PARTIAL"].contains($0.state ?? "") } : jobs
                Table(shown) {
                    TableColumn("Resource") { j in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(j.resourceName ?? j.resourceArn.map(ComputeFormat.arnResourceName) ?? "-").font(.caption.bold()).lineLimit(1)
                            Text(j.resourceType ?? "-").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("Status") { j in
                        HStack(spacing: 4) {
                            StatusBadge(j.state ?? "-")
                            if let p = j.percentDone, j.state == "RUNNING" { Text("\(p)%").font(.caption2) }
                        }
                    }
                    .width(min: 90, ideal: 120)
                    TableColumn("Vault") { j in Text(j.vault ?? "-").font(.caption).lineLimit(1) }
                    TableColumn("Created") { j in Text(Formatters.formatISODate(j.creationDate)).font(.caption) }
                    TableColumn("Completed") { j in Text(Formatters.formatISODate(j.completionDate)).font(.caption) }
                    TableColumn("Size") { j in Text(StorageFormat.bytes(j.sizeInBytes)).font(.caption) }.width(min: 60, ideal: 80)
                    TableColumn("Message") { j in Text(j.statusMessage ?? "").font(.caption2).foregroundStyle(.orange).lineLimit(2).help(j.statusMessage ?? "") }
                }
            }
        }
        .task(id: tab) { await load() }
    }

    private func load() async {
        state = .loading
        do {
            let jobs = try await api.getBackupJobs(profile: appState.currentProfile, region: appState.currentRegion, kind: tab.kind)
            state = jobs.isEmpty ? .empty : .loaded(jobs)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
