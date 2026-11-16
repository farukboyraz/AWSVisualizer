import SwiftUI

/// EC2 Auto Scaling groups: list on the left (capacity at a glance), the
/// console's group page on the right.
struct AutoScalingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[AsgSummary]> = .loading
    @State private var selectedName: String?
    @State private var search = ""

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 320, minWidth: 240, maxWidth: 500, isDetailActive: selectedName != nil, onBack: { selectedName = nil }, backTitle: "Groups", detailTitle: selectedName) {
                listPanel
            } detail: {
                if let selectedName {
                    AutoScalingGroupDetailView(name: selectedName)
                        .id(selectedName)
                } else {
                    EmptyStateView(message: "Select an Auto Scaling group")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Auto Scaling groups")
            ScreenFilterField(text: $search, prompt: "Filter groups")
            LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No Auto Scaling groups in this region") { groups in
                let filtered = search.isEmpty ? groups : groups.filter { $0.name.localizedCaseInsensitiveContains(search) }
                List(filtered, selection: $selectedName) { group in
                    row(group).tag(group.name)
                }
                .listStyle(.sidebar)
            }
            PanelActionBar {
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
            } trailing: {
                if case .loaded(let groups) = state {
                    Text("\(groups.count) groups").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ group: AsgSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(group.name)
                    .font(.body.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let status = group.status {
                    StatusBadge(status)
                }
            }
            HStack(spacing: 10) {
                Label("\(group.instanceCount)/\(group.desiredCapacity)", systemImage: "server.rack")
                    .help("Instances / desired capacity")
                Text("min \(group.minSize) · max \(group.maxSize)")
                if group.healthyCount < group.instanceCount {
                    Label("\(group.instanceCount - group.healthyCount) not healthy", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func loadData() async {
        state = .loading
        do {
            let groups = try await api.getAutoScalingGroups(profile: appState.currentProfile, region: appState.currentRegion)
            state = groups.isEmpty ? .empty : .loaded(groups)
            if let selectedName, !groups.contains(where: { $0.name == selectedName }) { self.selectedName = nil }
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

/// The console's Auto Scaling group page: Details, Activity, Automatic
/// scaling, Instance management, Tags.
struct AutoScalingGroupDetailView: View {
    let name: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case activity = "Activity"
        case scaling = "Automatic scaling"
        case instances = "Instance management"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .details
    @State private var detailState: LoadState<AsgDetail> = .loading

    var body: some View {
        LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(
                    title: detail.name,
                    subtitle: "\(detail.launchSource.kind): \(detail.launchSource.display)",
                    status: detail.status ?? "\(detail.instanceCount)/\(detail.desiredCapacity) InService",
                    tab: $tab
                )
                Group {
                    switch tab {
                    case .details:
                        AsgDetailsTab(detail: detail, onUpdated: { detailState = .loaded($0) }, onRefresh: { Task { await loadDetail() } })
                    case .activity:
                        AsgActivityTab(name: name)
                    case .scaling:
                        AsgScalingTab(name: name)
                    case .instances:
                        AsgInstancesTab(detail: detail, onUpdated: { detailState = .loaded($0) })
                    case .tags:
                        VStack(alignment: .leading, spacing: 0) {
                            DetailNote("New tags propagate to instances launched from now on.")
                                .padding(.horizontal, 24)
                                .padding(.top, 8)
                            ResourceTagsEditor(tags: detail.tags, resourceNoun: "group", onAdd: { key, value in
                                detailState = .loaded(try await api.addAutoScalingTag(profile: appState.currentProfile, region: appState.currentRegion, name: name, key: key, value: value))
                            }, onRemove: { key in
                                detailState = .loaded(try await api.removeAutoScalingTag(profile: appState.currentProfile, region: appState.currentRegion, name: name, key: key))
                            })
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: name) {
            await loadDetail()
        }
    }

    private func loadDetail() async {
        do {
            detailState = .loaded(try await api.getAutoScalingGroup(profile: appState.currentProfile, region: appState.currentRegion, name: name))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Details

private struct AsgDetailsTab: View {
    let detail: AsgDetail
    let onUpdated: (AsgDetail) -> Void
    let onRefresh: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var isEditing = false
    @State private var minSize = 0
    @State private var desired = 0
    @State private var maxSize = 0
    @State private var isSaving = false
    @State private var error: String?

    private var capacityValid: Bool { minSize <= desired && desired <= maxSize }

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Group size") {
                if isEditing {
                    capacityEditor
                } else {
                    HStack(spacing: 12) {
                        MetricTile(title: "Desired", value: "\(detail.desiredCapacity)")
                        MetricTile(title: "Minimum", value: "\(detail.minSize)")
                        MetricTile(title: "Maximum", value: "\(detail.maxSize)")
                        MetricTile(title: "In service", value: "\(detail.instances.filter { $0.lifecycleState == "InService" }.count)")
                    }
                    HStack {
                        EditButton("Edit capacity") {
                            minSize = detail.minSize
                            desired = detail.desiredCapacity
                            maxSize = detail.maxSize
                            error = nil
                            isEditing = true
                        }
                        Spacer()
                        RefreshButton(compactSize: 22, help: "Refresh") { onRefresh() }
                    }
                    .controlSize(.small)
                }
            }

            DetailSection(title: "Launch template") {
                DetailGrid(items: [
                    DetailItem("Source", detail.launchSource.kind, monospaced: false),
                    DetailItem("Name", detail.launchSource.name),
                    DetailItem("ID", detail.launchSource.id),
                    DetailItem("Version", detail.launchSource.version),
                ])
                if !detail.instanceTypeOverrides.isEmpty {
                    DetailChipsField("Instance types (mixed instances)", detail.instanceTypeOverrides)
                    DetailGrid(items: [
                        DetailItem("On-Demand base capacity", ComputeFormat.int(detail.onDemandBaseCapacity)),
                        DetailItem("On-Demand above base", detail.onDemandPercentageAboveBase.map { "\($0)%" }),
                        DetailItem("Spot allocation strategy", detail.spotAllocationStrategy),
                    ])
                }
            }

            DetailSection(title: "Network") {
                DetailChipsField("Availability Zones", detail.availabilityZones)
                DetailChipsField("Subnets", detail.subnetIds)
                if let placement = detail.placementGroup {
                    DetailField("Placement group", placement)
                }
            }

            DetailSection(title: "Load balancing") {
                if detail.targetGroupArns.isEmpty && detail.loadBalancerNames.isEmpty {
                    Text("No load balancer attached.").font(.caption).foregroundStyle(.secondary)
                } else {
                    DetailChipsField("Target groups", detail.targetGroupArns.map(ComputeFormat.arnResourceName))
                    if !detail.loadBalancerNames.isEmpty {
                        DetailChipsField("Classic Load Balancers", detail.loadBalancerNames)
                    }
                }
            }

            DetailSection(title: "Health checks") {
                DetailGrid(items: [
                    DetailItem("Health check type", detail.healthCheckType),
                    DetailItem("Grace period", ComputeFormat.seconds(detail.healthCheckGracePeriod)),
                    DetailItem("Default instance warmup", ComputeFormat.seconds(detail.defaultInstanceWarmup)),
                ])
            }

            DetailSection(title: "Advanced configurations") {
                DetailGrid(items: [
                    DetailItem("Default cooldown", ComputeFormat.seconds(detail.defaultCooldown)),
                    DetailItem("Capacity rebalance", ComputeFormat.bool(detail.capacityRebalance)),
                    DetailItem("Maximum instance lifetime", ComputeFormat.seconds(detail.maxInstanceLifetime)),
                    DetailItem("Scale-in protection for new instances", ComputeFormat.bool(detail.newInstancesProtectedFromScaleIn)),
                    DetailItem("Service-linked role", detail.serviceLinkedRoleArn.map(ComputeFormat.arnResourceName)),
                    DetailItem("Created", Formatters.formatISODate(detail.createdTime), monospaced: false),
                ])
                DetailChipsField("Termination policies", detail.terminationPolicies)
                DetailChipsField("Suspended processes", detail.suspendedProcesses)
                DetailChipsField("Group metrics collection", detail.enabledMetrics)
            }

            DetailSection(title: "ARN") {
                CopyableBlock(text: detail.arn)
            }
        }
    }

    private var capacityEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                capacityField("Desired capacity", value: $desired)
                capacityField("Minimum capacity", value: $minSize)
                capacityField("Maximum capacity", value: $maxSize)
            }
            if !capacityValid {
                Text("Desired capacity must be between the minimum and maximum.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                SaveButton("Update", isLoading: isSaving, isDisabled: !capacityValid || isSaving) {
                    Task { await save() }
                }
                SecondaryButton("Cancel", isDisabled: isSaving) { isEditing = false }
            }
            .controlSize(.small)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func capacityField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Stepper("", value: value, in: 0...10_000)
                    .labelsHidden()
            }
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            let updated = try await api.updateAutoScalingCapacity(profile: appState.currentProfile, region: appState.currentRegion, name: detail.name, minSize: minSize, maxSize: maxSize, desiredCapacity: desired)
            onUpdated(updated)
            isEditing = false
        } catch {
            self.error = error.friendlyMessage
        }
        isSaving = false
    }
}

// MARK: - Activity

private struct AsgActivityTab: View {
    let name: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<AsgActivityPage> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { page in
            DetailTabPage(maxWidth: 900) {
                if !page.instanceRefreshes.isEmpty {
                    DetailSection(title: "Instance refreshes") {
                        ForEach(page.instanceRefreshes) { refresh in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(refresh.instanceRefreshId).font(.caption.monospaced())
                                    Text("\(Formatters.formatISODate(refresh.startTime)) → \(Formatters.formatISODate(refresh.endTime))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if let reason = refresh.statusReason, !reason.isEmpty {
                                        Text(reason).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let pct = refresh.percentageComplete {
                                    Text("\(pct)%").font(.caption.monospaced())
                                }
                                StatusBadge(refresh.status ?? "-")
                            }
                            Divider()
                        }
                    }
                }

                DetailSection(title: "Activity history") {
                    HStack {
                        Text("Latest \(page.activities.count) activities").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        RefreshButton(compactSize: 22, help: "Refresh") { Task { await load() } }
                    }
                    if page.activities.isEmpty {
                        Text("No scaling activity.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(page.activities) { activity in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top) {
                                Text(activity.description ?? activity.activityId)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                StatusBadge(activity.statusCode ?? "-")
                            }
                            if let cause = activity.cause {
                                Text(cause)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let message = activity.statusMessage, !message.isEmpty {
                                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            }
                            Text("\(Formatters.formatISODate(activity.startTime)) → \(Formatters.formatISODate(activity.endTime))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Divider()
                    }
                }
            }
        }
        .task(id: name) { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await api.getAutoScalingGroupActivity(profile: appState.currentProfile, region: appState.currentRegion, name: name))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Automatic scaling

private struct AsgScalingTab: View {
    let name: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<AsgScaling> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { scaling in
            DetailTabPage(maxWidth: 900) {
                DetailSection(title: "Dynamic scaling policies · \(scaling.policies.count)") {
                    if scaling.policies.isEmpty {
                        Text("No scaling policies - the group stays at its desired capacity unless changed manually or by a schedule.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(scaling.policies) { policy in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(policy.name).font(.body.bold())
                                Spacer()
                                StatusBadge(policy.enabled ? "Enabled" : "Disabled")
                            }
                            DetailGrid(items: [
                                DetailItem("Policy type", policy.policyType),
                                DetailItem("Target", policy.targetTracking),
                                DetailItem("Adjustment", policy.scalingAdjustment.map { "\($0) (\(policy.adjustmentType ?? "-"))" }),
                                DetailItem("Cooldown", ComputeFormat.seconds(policy.cooldown)),
                                DetailItem("Scale-in disabled", ComputeFormat.bool(policy.disableScaleIn)),
                            ].filter { $0.value != "-" })
                            if !policy.stepAdjustments.isEmpty {
                                DetailChipsField("Step adjustments", policy.stepAdjustments)
                            }
                            if !policy.alarms.isEmpty {
                                DetailChipsField("CloudWatch alarms", policy.alarms)
                            }
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                DetailSection(title: "Scheduled actions · \(scaling.scheduledActions.count)") {
                    if scaling.scheduledActions.isEmpty {
                        Text("No scheduled actions.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Table(scaling.scheduledActions) {
                            TableColumn("Name") { a in Text(a.name).font(.caption.monospaced()) }
                            TableColumn("Recurrence") { a in Text(a.recurrence ?? "Once").font(.caption.monospaced()) }
                            TableColumn("Desired / Min / Max") { a in
                                Text("\(ComputeFormat.int(a.desiredCapacity)) / \(ComputeFormat.int(a.minSize)) / \(ComputeFormat.int(a.maxSize))").font(.caption.monospaced())
                            }
                            TableColumn("Start") { a in Text(Formatters.formatISODate(a.startTime)).font(.caption) }
                            TableColumn("Time zone") { a in Text(a.timeZone ?? "UTC").font(.caption) }
                        }
                        .frame(minHeight: CGFloat(min(scaling.scheduledActions.count, 8)) * 26 + 32)
                    }
                }
            }
        }
        .task(id: name) { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await api.getAutoScalingGroupScaling(profile: appState.currentProfile, region: appState.currentRegion, name: name))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Instance management

private struct AsgInstancesTab: View {
    let detail: AsgDetail
    let onUpdated: (AsgDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var selection: Set<String> = []
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailActionBar(error: error, note: "Scale-in protection keeps the selected instances when the group scales in.") {
                AppButton("Set scale-in protection", kind: .confirm, systemImage: "lock.shield", isLoading: isSaving, isDisabled: selection.isEmpty || isSaving) {
                    Task { await setProtection(true) }
                }
                AppButton("Remove scale-in protection", kind: .secondary, systemImage: "lock.open", isDisabled: selection.isEmpty || isSaving) {
                    Task { await setProtection(false) }
                }
            }
            if detail.instances.isEmpty {
                EmptyStateView(message: "No instances in this group")
            } else {
                Table(detail.instances, selection: $selection) {
                    TableColumn("Instance ID") { i in Text(i.instanceId).font(.caption.monospaced()) }
                        .width(min: 150, ideal: 170)
                    TableColumn("Lifecycle") { i in StatusBadge(i.lifecycleState ?? "-") }
                        .width(min: 90, ideal: 110)
                    TableColumn("Health") { i in
                        Text(i.healthStatus ?? "-")
                            .font(.caption)
                            .foregroundStyle(i.healthStatus == "Healthy" ? .green : .orange)
                    }
                    .width(min: 60, ideal: 80)
                    TableColumn("Type") { i in Text(i.instanceType ?? "-").font(.caption.monospaced()) }
                        .width(min: 80, ideal: 100)
                    TableColumn("AZ") { i in Text(i.availabilityZone ?? "-").font(.caption.monospaced()) }
                        .width(min: 80, ideal: 100)
                    TableColumn("Launch source") { i in Text(i.launchSource ?? "-").font(.caption).lineLimit(1) }
                    TableColumn("Protected") { i in
                        Image(systemName: i.protectedFromScaleIn ? "lock.fill" : "lock.open")
                            .foregroundStyle(i.protectedFromScaleIn ? Color.accentColor : .secondary)
                    }
                    .width(60)
                }
            }
        }
    }

    private func setProtection(_ protected: Bool) async {
        isSaving = true
        error = nil
        do {
            onUpdated(try await api.setAutoScalingInstanceProtection(profile: appState.currentProfile, region: appState.currentRegion, name: detail.name, instanceIds: Array(selection), protected: protected))
            selection = []
        } catch {
            self.error = error.friendlyMessage
        }
        isSaving = false
    }
}
