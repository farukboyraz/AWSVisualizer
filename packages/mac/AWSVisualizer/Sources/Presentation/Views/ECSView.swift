import SwiftUI

/// Clusters on the left; the right panel shows the selected cluster's
/// services and drills into one service's page (console order: cluster →
/// services → service), with a Back button to return to the service list.
struct ECSView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[EcsCluster]> = .loading
    @State private var selectedCluster: EcsCluster?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 280, minWidth: 220, maxWidth: 460, isDetailActive: selectedCluster != nil, onBack: { selectedCluster = nil }, backTitle: "Clusters", detailTitle: selectedCluster?.clusterName) {
                clusterListPanel
            } detail: {
                if let selectedCluster, let arn = selectedCluster.clusterArn {
                    EcsClusterServicesView(cluster: selectedCluster, clusterArn: arn)
                        .id(arn)
                } else {
                    EmptyStateView(message: "Select a cluster")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private var clusterListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("ECS Clusters")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }) { unfilteredClusters in
                let clusters = unfilteredClusters.matching(filter)
                List(clusters, selection: Binding(
                    get: { selectedCluster?.id },
                    set: { id in selectedCluster = clusters.first { $0.id == id } }
                )) { cluster in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(cluster.clusterName ?? "-")
                                .font(.body.bold())
                            Spacer()
                            if let status = cluster.status, status != "ACTIVE" {
                                StatusBadge(status)
                            }
                        }
                        HStack(spacing: 10) {
                            Label("\(cluster.activeServicesCount ?? 0)", systemImage: "square.stack.3d.up")
                                .help("Active services")
                            Label("\(cluster.runningTasksCount ?? 0)", systemImage: "play.circle")
                                .help("Running tasks")
                            if let pending = cluster.pendingTasksCount, pending > 0 {
                                Label("\(pending)", systemImage: "hourglass")
                                    .help("Pending tasks")
                            }
                            if let instances = cluster.registeredContainerInstancesCount, instances > 0 {
                                Label("\(instances)", systemImage: "server.rack")
                                    .help("Container instances")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(cluster.id)
                }
                .listStyle(.sidebar)
            }
            PanelActionBar {
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
            }
        }
    }

    private func loadData() async {
        state = .loading
        selectedCluster = nil
        do {
            let response = try await api.getECSClusters(profile: appState.currentProfile, region: appState.currentRegion)
            state = response.loadState()
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct EcsClusterServicesView: View {
    let cluster: EcsCluster
    let clusterArn: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[EcsServiceSummary]> = .loading
    @State private var openService: EcsServiceSummary?

    var body: some View {
        Group {
            if let openService {
                EcsServiceDetailView(clusterArn: clusterArn, serviceName: openService.serviceName, onBack: {
                    self.openService = nil
                    Task { await load() }
                })
                .id(openService.id)
            } else {
                servicesList
            }
        }
        .task(id: clusterArn) {
            await load()
        }
    }

    private var servicesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cluster.clusterName ?? "-")
                        .font(.title2.bold())
                    Text("Services")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await load() } }
            }
            .padding()

            HStack(spacing: 12) {
                MetricTile(title: "Services", value: "\(cluster.activeServicesCount ?? 0)")
                MetricTile(title: "Running tasks", value: "\(cluster.runningTasksCount ?? 0)", tint: .green)
                MetricTile(title: "Pending tasks", value: "\(cluster.pendingTasksCount ?? 0)", tint: (cluster.pendingTasksCount ?? 0) > 0 ? .orange : .primary)
                MetricTile(title: "Container instances", value: "\(cluster.registeredContainerInstancesCount ?? 0)")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No services in this cluster") { services in
                Table(services) {
                    TableColumn("Service") { s in
                        Text(s.serviceName).font(.body.bold())
                    }
                    .width(min: 160, ideal: 240)
                    TableColumn("Status") { s in StatusBadge(s.status) }
                        .width(min: 70, ideal: 90)
                    TableColumn("Tasks") { s in
                        Text("\(s.runningCount)/\(s.desiredCount)")
                            .monospacedDigit()
                            .foregroundStyle(s.runningCount < s.desiredCount ? .orange : .primary)
                            .help("Running / desired")
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("Launch type") { s in Text(s.launchType ?? "-") }
                        .width(min: 80, ideal: 110)
                    TableColumn("Task definition") { s in
                        Text(s.taskDefinition.split(separator: "/").last.map(String.init) ?? s.taskDefinition)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                    }
                    .width(min: 140, ideal: 220)
                }
                .contextMenu(forSelectionType: EcsServiceSummary.ID.self) { _ in
                } primaryAction: { ids in
                    if let id = ids.first { openService = services.first { $0.id == id } }
                }
                .overlay(alignment: .bottom) {
                    Text("Double-click a service to open it")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(6)
                }
            }
        }
    }

    private func load() async {
        state = .loading
        do {
            let services = try await api.getECSServices(profile: appState.currentProfile, region: appState.currentRegion, cluster: clusterArn)
            state = services.isEmpty ? .empty : .loaded(services)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
