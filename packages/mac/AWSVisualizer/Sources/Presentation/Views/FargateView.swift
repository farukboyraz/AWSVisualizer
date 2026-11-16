import SwiftUI

private enum FargateItem: Hashable {
    case task(String)
    case profile(String)
}

/// Fargate isn't a console of its own: it's ECS tasks running on Fargate
/// plus EKS Fargate profiles. Both are gathered across every cluster in
/// the region.
struct FargateView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<FargateOverview> = .loading
    @State private var selection: FargateItem?

    private var detailTitle: String? {
        switch selection {
        case .task(let arn): return arn.split(separator: "/").last.map(String.init)
        case .profile(let id): return id
        case nil: return nil
        }
    }

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 340, minWidth: 260, maxWidth: 520, isDetailActive: selection != nil, onBack: { selection = nil }, backTitle: "Fargate", detailTitle: detailTitle) {
                listPanel
            } detail: {
                if case .loaded(let overview) = state {
                    switch selection {
                    case .task(let arn):
                        if let task = overview.tasks.first(where: { $0.taskArn == arn }) {
                            FargateTaskDetailView(task: task, onStopped: { Task { await loadData() } }).id(arn)
                        }
                    case .profile(let id):
                        if let profile = overview.profiles.first(where: { $0.id == id }) {
                            DetailTabPage { FargateProfileCard(profile: profile) }
                        }
                    case nil:
                        EmptyStateView(message: "Select a task or Fargate profile")
                    }
                } else {
                    EmptyStateView(message: "Select a task or Fargate profile")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Fargate")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No Fargate tasks or profiles in this region") { overview in
                let clusters = Dictionary(grouping: overview.tasks.matching(filter), by: \.clusterName).sorted { $0.key < $1.key }
                List(selection: $selection) {
                    ForEach(clusters, id: \.key) { cluster, tasks in
                        Section("ECS · \(cluster) · \(tasks.count) running") {
                            ForEach(tasks) { task in
                                taskRow(task).tag(FargateItem.task(task.taskArn))
                            }
                        }
                    }
                    if overview.tasks.isEmpty {
                        Section("ECS tasks") {
                            Text("No running Fargate tasks.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("EKS Fargate profiles · \(overview.profiles.count)") {
                        ForEach(overview.profiles.matching(filter)) { profile in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(profile.name).font(.body.bold())
                                    Spacer()
                                    StatusBadge(profile.status ?? "-")
                                }
                                Text("\(profile.clusterName ?? "-") · \(profile.selectors.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.vertical, 2)
                            .tag(FargateItem.profile(profile.id))
                        }
                    }
                }
                .listStyle(.sidebar)
                ForEach(overview.errors + (overview.truncated ? ["Some clusters have more than 200 running tasks - only the first 200 are listed."] : []), id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                }
            }
            PanelActionBar {
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
            } trailing: {
                if case .loaded(let o) = state {
                    Text("\(o.tasks.count) tasks").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func taskRow(_ task: FargateTask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(task.group?.replacingOccurrences(of: "service:", with: "") ?? task.taskId)
                    .font(.body.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if task.capacityProviderName == "FARGATE_SPOT" {
                    Text("Spot").font(.caption2.bold()).foregroundStyle(.purple)
                }
                StatusBadge(task.lastStatus ?? "-")
            }
            Text([String(task.taskId.prefix(12)), task.cpu.map { "\($0) CPU" }, task.memory.map { "\($0) MiB" }, task.privateIp].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func loadData() async {
        if case .loaded = state {} else { state = .loading }
        do {
            let overview = try await api.getFargateOverview(profile: appState.currentProfile, region: appState.currentRegion)
            state = overview.tasks.isEmpty && overview.profiles.isEmpty && overview.errors.isEmpty ? .empty : .loaded(overview)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct FargateTaskDetailView: View {
    let task: FargateTask
    let onStopped: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case containers = "Containers"
    }

    @State private var tab: DetailTab = .details
    @State private var isStopping = false
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(title: task.taskId, subtitle: "\(task.clusterName) · \(task.group ?? "standalone task")", status: task.lastStatus, tab: $tab)
            DetailActionBar(error: actionError, note: task.group?.hasPrefix("service:") == true ? "This task belongs to a service - ECS starts a replacement after it stops." : nil) {
                ConfirmedActionButton(
                    title: "Stop task",
                    systemImage: "stop.fill",
                    confirmationTitle: "Stop task \(String(task.taskId.prefix(12)))?",
                    confirmationMessage: "The containers receive SIGTERM, then SIGKILL after the stop timeout.",
                    isLoading: isStopping,
                    isDisabled: isStopping || task.lastStatus == "STOPPED"
                ) { Task { await stop() } }
            }
            Group {
                switch tab {
                case .details:
                    DetailTabPage {
                        DetailGrid(items: [
                            DetailItem("Cluster", task.clusterName),
                            DetailItem("Group", task.group),
                            DetailItem("Task definition", task.taskDefinition),
                            DetailItem("Capacity provider", task.capacityProviderName ?? task.launchType),
                            DetailItem("Platform version", task.platformVersion),
                            DetailItem("CPU / memory", "\(task.cpu ?? "-") / \(task.memory ?? "-") MiB"),
                            DetailItem("Health", task.healthStatus),
                            DetailItem("Private IP", task.privateIp),
                            DetailItem("Availability Zone", task.availabilityZone),
                            DetailItem("Started", Formatters.formatISODate(task.startedAt), monospaced: false),
                        ])
                        DetailSection(title: "Task ARN") { CopyableBlock(text: task.taskArn) }
                    }
                case .containers:
                    DetailTabPage {
                        ForEach(task.containers, id: \.name) { c in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(c.name).font(.body.bold())
                                    Spacer()
                                    if let health = c.healthStatus, health != "UNKNOWN" { StatusBadge(health) }
                                    StatusBadge(c.lastStatus ?? "-")
                                }
                                Text(c.image ?? "-").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                if let reason = c.reason { Text(reason).font(.caption).foregroundStyle(.orange) }
                            }
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stop() async {
        isStopping = true
        actionError = nil
        do {
            try await api.stopECSTask(profile: appState.currentProfile, region: appState.currentRegion, cluster: task.clusterArn, task: task.taskArn)
            onStopped()
        } catch {
            actionError = error.friendlyMessage
        }
        isStopping = false
    }
}
