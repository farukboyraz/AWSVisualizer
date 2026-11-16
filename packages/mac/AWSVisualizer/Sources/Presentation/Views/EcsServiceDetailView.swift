import SwiftUI

/// Mirrors an ECS service's console page: Health (counts + desired-count
/// editor + service events), Tasks, Deployments, Configuration (task
/// definition + networking + load balancers) and Tags.
struct EcsServiceDetailView: View {
    let clusterArn: String
    let serviceName: String
    var onBack: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case health = "Health"
        case tasks = "Tasks"
        case deployments = "Deployments"
        case configuration = "Configuration"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .health
    @State private var detailState: LoadState<EcsServiceDetail> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeader(
                        title: detail.serviceName,
                        subtitle: clusterArn.split(separator: "/").last.map { "Cluster \($0)" },
                        status: detail.status,
                        tab: $tab,
                        onBack: onBack
                    )

                    Group {
                        switch tab {
                        case .health:
                            EcsHealthTab(clusterArn: clusterArn, detail: detail, onUpdated: { detailState = .loaded($0) }, onRefresh: { Task { await loadDetail() } })
                        case .tasks:
                            EcsTasksTab(clusterArn: clusterArn, serviceName: detail.serviceName)
                        case .deployments:
                            EcsDeploymentsTab(detail: detail)
                        case .configuration:
                            EcsConfigurationTab(detail: detail)
                        case .tags:
                            ResourceTagsEditor(tags: detail.tags, resourceNoun: "service", onAdd: { key, value in
                                detailState = .loaded(try await api.addECSServiceTag(profile: appState.currentProfile, region: appState.currentRegion, cluster: clusterArn, service: detail.serviceName, serviceArn: detail.serviceArn, key: key, value: value))
                            }, onRemove: { key in
                                detailState = .loaded(try await api.removeECSServiceTag(profile: appState.currentProfile, region: appState.currentRegion, cluster: clusterArn, service: detail.serviceName, serviceArn: detail.serviceArn, key: key))
                            })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: serviceName) {
            await loadDetail()
        }
    }

    private func loadDetail() async {
        do {
            let detail = try await api.getECSServiceDetail(profile: appState.currentProfile, region: appState.currentRegion, cluster: clusterArn, service: serviceName)
            detailState = .loaded(detail)
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

private struct EcsHealthTab: View {
    let clusterArn: String
    let detail: EcsServiceDetail
    var onUpdated: (EcsServiceDetail) -> Void
    var onRefresh: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var desiredCount = 0
    @State private var isSavingCount = false
    @State private var isDeploying = false
    @State private var actionError: String?
    @State private var actionMessage: String?

    var body: some View {
        DetailTabPage {
            HStack(spacing: 12) {
                MetricTile(title: "Desired", value: "\(detail.desiredCount)")
                MetricTile(title: "Running", value: "\(detail.runningCount)", tint: detail.runningCount < detail.desiredCount ? .orange : .green)
                MetricTile(title: "Pending", value: "\(detail.pendingCount)", tint: detail.pendingCount > 0 ? .orange : .primary)
            }

            DetailSection(title: "Update service", spacing: 10) {
                HStack(spacing: 10) {
                    Text("Desired tasks")
                    TextField("", value: $desiredCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Stepper("", value: $desiredCount, in: 0...1000)
                        .labelsHidden()
                    SaveButton("Save", isLoading: isSavingCount, isDisabled: desiredCount == detail.desiredCount || desiredCount < 0) {
                        Task { await saveDesiredCount() }
                    }
                    Spacer()
                    ConfirmedActionButton(
                        title: "Force new deployment",
                        systemImage: "arrow.triangle.2.circlepath",
                        confirmationTitle: "Force a new deployment?",
                        confirmationMessage: "ECS replaces every task of \(detail.serviceName) with fresh ones on the same task definition, following the service's deployment settings.",
                        isLoading: isDeploying,
                        role: nil
                    ) {
                        Task { await forceDeployment() }
                    }
                }
                if desiredCount == 0 && detail.desiredCount != 0 {
                    Text("Setting desired tasks to 0 stops every task of this service.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(.red)
                }
                if let actionMessage {
                    Text(actionMessage).font(.caption).foregroundStyle(.green)
                }
            }

            DetailSection(title: "Events") {
                HStack {
                    Text("Most recent first - ECS keeps the last 100.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    RefreshButton(compactSize: 22, help: "Refresh") { onRefresh() }
                }
                if detail.events.isEmpty {
                    Text("No events.").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(detail.events) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Formatters.formatISODate(event.createdAt))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(event.message)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }
        }
        .task(id: detail.desiredCount) {
            desiredCount = detail.desiredCount
        }
    }

    private func saveDesiredCount() async {
        isSavingCount = true
        actionError = nil
        actionMessage = nil
        do {
            onUpdated(try await api.setECSDesiredCount(profile: appState.currentProfile, region: appState.currentRegion, cluster: clusterArn, service: detail.serviceName, desiredCount: desiredCount))
            actionMessage = "Desired count updated - ECS is reconciling tasks."
        } catch {
            actionError = error.friendlyMessage
        }
        isSavingCount = false
    }

    private func forceDeployment() async {
        isDeploying = true
        actionError = nil
        actionMessage = nil
        do {
            onUpdated(try await api.forceECSDeployment(profile: appState.currentProfile, region: appState.currentRegion, cluster: clusterArn, service: detail.serviceName))
            actionMessage = "New deployment started - follow it in the Deployments tab."
        } catch {
            actionError = error.friendlyMessage
        }
        isDeploying = false
    }
}

private struct EcsTasksTab: View {
    let clusterArn: String
    let serviceName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var showStopped = false
    @State private var state: LoadState<[EcsTask]> = .loading
    @State private var stoppingTask: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TabBar(tabs: [false, true], selection: $showStopped, style: .pills, title: { $0 ? "Stopped" : "Running" })
                if showStopped {
                    Text("ECS keeps stopped tasks for about an hour.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                RefreshButton(compactSize: 22, help: "Refresh") { Task { await load() } }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 24)
            }

            LoadableContent(state, retry: { Task { await load() } }, emptyMessage: showStopped ? "No recently stopped tasks" : "No running tasks") { tasks in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(tasks) { task in
                            taskCard(task)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .task(id: showStopped) {
            await load()
        }
    }

    private func taskCard(_ task: EcsTask) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(task.taskId)
                    .font(.caption.monospaced().bold())
                    .textSelection(.enabled)
                if let status = task.lastStatus { StatusBadge(status) }
                if let health = task.healthStatus, health != "UNKNOWN" { StatusBadge(health) }
                Spacer()
                if task.desiredStatus == "RUNNING" {
                    ConfirmedActionButton(
                        title: "Stop",
                        systemImage: "stop.fill",
                        confirmationTitle: "Stop this task?",
                        confirmationMessage: "The service scheduler will start a replacement task to keep the desired count.",
                        isLoading: stoppingTask == task.taskArn,
                        isDisabled: stoppingTask != nil
                    ) {
                        Task { await stop(task) }
                    }
                    .controlSize(.small)
                }
            }
            HStack(spacing: 14) {
                if let td = task.taskDefinition { Label(td, systemImage: "doc.text") }
                if let ip = task.privateIp { Label(ip, systemImage: "network") }
                if let az = task.availabilityZone { Label(az, systemImage: "mappin") }
                if let cpu = task.cpu, let memory = task.memory { Label("\(cpu) CPU / \(memory) MiB", systemImage: "cpu") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(task.stoppedAt != nil
                 ? "Started \(Formatters.formatISODate(task.startedAt)) · Stopped \(Formatters.formatISODate(task.stoppedAt))"
                 : "Started \(Formatters.formatISODate(task.startedAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let reason = task.stoppedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            ForEach(task.containers, id: \.name) { container in
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.secondary)
                    Text(container.name).font(.caption.bold())
                    if let status = container.lastStatus { Text(status).font(.caption2).foregroundStyle(.secondary) }
                    if let exit = container.exitCode {
                        Text("exit \(exit)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(exit == 0 ? .secondary : Color.red)
                    }
                    if let reason = container.reason {
                        Text(reason).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                    }
                    Spacer()
                    if let image = container.image {
                        Text(image)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .padding(.leading, 8)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func load() async {
        state = .loading
        error = nil
        do {
            let tasks = try await api.getECSServiceTasks(profile: appState.currentProfile, region: appState.currentRegion, cluster: clusterArn, service: serviceName, stopped: showStopped)
            state = tasks.isEmpty ? .empty : .loaded(tasks)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }

    private func stop(_ task: EcsTask) async {
        stoppingTask = task.taskArn
        error = nil
        do {
            try await api.stopECSTask(profile: appState.currentProfile, region: appState.currentRegion, cluster: clusterArn, task: task.taskArn)
            await load()
        } catch {
            self.error = error.friendlyMessage
        }
        stoppingTask = nil
    }
}

private struct EcsDeploymentsTab: View {
    let detail: EcsServiceDetail

    var body: some View {
        DetailTabPage {
            DetailSection(title: "Deployment configuration") {
                HStack(spacing: 24) {
                    DetailField("Minimum healthy", detail.minimumHealthyPercent.map { "\($0)%" } ?? "-")
                    DetailField("Maximum", detail.maximumPercent.map { "\($0)%" } ?? "-")
                    DetailField("Circuit breaker", circuitBreakerText)
                }
            }

            DetailSection(title: "Deployments", spacing: 10) {
                if detail.deployments.isEmpty {
                    Text("No deployments.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(detail.deployments) { deployment in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            StatusBadge(deployment.status, color: deployment.status == "PRIMARY" ? .blue : .secondary)
                            if let rollout = deployment.rolloutState { StatusBadge(rollout) }
                            Spacer()
                            Text(Formatters.formatISODate(deployment.createdAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(deployment.taskDefinition.split(separator: "/").last.map(String.init) ?? deployment.taskDefinition)
                            .font(.caption.monospaced())
                        HStack(spacing: 16) {
                            Text("Desired \(deployment.desiredCount)")
                            Text("Running \(deployment.runningCount)")
                            Text("Pending \(deployment.pendingCount)")
                            if deployment.failedTasks > 0 {
                                Text("Failed \(deployment.failedTasks)").foregroundStyle(.red)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        if let reason = deployment.rolloutStateReason {
                            Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var circuitBreakerText: String {
        guard let enabled = detail.circuitBreakerEnabled else { return "-" }
        guard enabled else { return "Off" }
        return detail.circuitBreakerRollback == true ? "On, with rollback" : "On"
    }
}

private struct EcsConfigurationTab: View {
    let detail: EcsServiceDetail

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var taskDefinitionState: LoadState<EcsTaskDefinitionSummary> = .loading

    var body: some View {
        DetailTabPage {
            DetailSection(title: "Service") {
                DetailField("ARN", detail.serviceArn)
                HStack(spacing: 24) {
                    DetailField("Launch type", detail.launchType ?? "-")
                    DetailField("Platform version", detail.platformVersion ?? "-")
                    DetailField("Scheduling", detail.schedulingStrategy ?? "-")
                }
                if !detail.capacityProviders.isEmpty {
                    DetailField("Capacity providers", detail.capacityProviders.joined(separator: "\n"))
                }
                HStack(spacing: 24) {
                    DetailField("Created", Formatters.formatISODate(detail.createdAt), monospaced: false)
                    if let createdBy = detail.createdBy { DetailField("Created by", createdBy) }
                }
            }

            Divider()

            DetailSection(title: "Task definition", spacing: 10) {
                LoadableContent(taskDefinitionState, retry: { Task { await loadTaskDefinition() } }) { td in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 24) {
                            DetailField("Family:revision", "\(td.family):\(td.revision)")
                            DetailField("CPU / Memory", "\(td.cpu ?? "-") / \(td.memory ?? "-")")
                            DetailField("Network mode", td.networkMode ?? "-")
                            DetailField("Compatibility", td.requiresCompatibilities.joined(separator: ", "))
                        }
                        if let role = td.taskRoleArn { DetailField("Task role", role) }
                        if let role = td.executionRoleArn { DetailField("Execution role", role) }
                        ForEach(td.containers) { container in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "shippingbox")
                                    Text(container.name).font(.caption.bold())
                                    if container.essential == true {
                                        Text("essential").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                if let image = container.image {
                                    Text(image).font(.caption.monospaced()).textSelection(.enabled)
                                }
                                HStack(spacing: 14) {
                                    if !container.portMappings.isEmpty { Text("Ports \(container.portMappings.joined(separator: ", "))") }
                                    if let cpu = container.cpu { Text("CPU \(cpu)") }
                                    if let memory = container.memory ?? container.memoryReservation { Text("Memory \(memory) MiB") }
                                    Text("\(container.environmentCount) env vars")
                                    if container.secretsCount > 0 { Text("\(container.secretsCount) secrets") }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                if let logGroup = container.logGroup {
                                    Text("Logs: \(logGroup) (open it under CloudWatch → Log Groups)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .frame(minHeight: 80)
            }

            Divider()

            DetailSection(title: "Networking") {
                DetailField("Subnets", detail.subnets.isEmpty ? "-" : detail.subnets.joined(separator: "\n"))
                DetailField("Security groups", detail.securityGroups.isEmpty ? "-" : detail.securityGroups.joined(separator: "\n"))
                DetailField("Public IP", detail.assignPublicIp ?? "-")
            }

            if !detail.loadBalancers.isEmpty {
                Divider()
                DetailSection(title: "Load balancing") {
                    ForEach(detail.loadBalancers, id: \.self) { lb in
                        DetailField(
                            lb.containerName.map { "\($0):\(lb.containerPort ?? 0)" } ?? "Target",
                            lb.targetGroupArn ?? lb.loadBalancerName ?? "-"
                        )
                    }
                }
            }
        }
        .task(id: detail.taskDefinition) {
            await loadTaskDefinition()
        }
    }

    private func loadTaskDefinition() async {
        taskDefinitionState = .loading
        do {
            taskDefinitionState = .loaded(try await api.getECSTaskDefinition(profile: appState.currentProfile, region: appState.currentRegion, taskDefinition: detail.taskDefinition))
        } catch {
            taskDefinitionState = .failed(error.friendlyMessage)
        }
    }
}
