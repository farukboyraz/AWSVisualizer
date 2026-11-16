import SwiftUI

/// EKS clusters: list with version/status, the console's cluster page on
/// the right.
struct EksView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[EksClusterSummary]> = .loading
    @State private var selectedName: String?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 300, minWidth: 220, maxWidth: 480, isDetailActive: selectedName != nil, onBack: { selectedName = nil }, backTitle: "Clusters", detailTitle: selectedName) {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle("EKS Clusters")
                    ScreenFilterField(text: $filter)
                    LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No EKS clusters in this region") { unfilteredClusters in
                        let clusters = unfilteredClusters.matching(filter)
                        List(clusters, selection: $selectedName) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(c.name).font(.body.bold()).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if let status = c.status { StatusBadge(status) }
                                }
                                Text(["Kubernetes \(c.version ?? "-")", c.platformVersion].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(c.name)
                        }
                        .listStyle(.sidebar)
                    }
                    PanelActionBar {
                        RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
                    }
                }
            } detail: {
                if let selectedName {
                    EksClusterDetailView(name: selectedName).id(selectedName)
                } else {
                    EmptyStateView(message: "Select a cluster")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private func loadData() async {
        state = .loading
        do {
            let clusters = try await api.getEksClusters(profile: appState.currentProfile, region: appState.currentRegion)
            state = clusters.isEmpty ? .empty : .loaded(clusters)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

/// Tabs of the EKS console's cluster page.
struct EksClusterDetailView: View {
    let name: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case overview = "Overview"
        case compute = "Compute"
        case networking = "Networking"
        case addons = "Add-ons"
        case access = "Access"
        case observability = "Observability"
        case updates = "Update history"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .overview
    @State private var state: LoadState<EksClusterDetail> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { c in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(title: c.name, subtitle: "Kubernetes \(c.version ?? "-") · \(c.platformVersion ?? "-")", status: c.status, tab: $tab)
                Group {
                    switch tab {
                    case .overview: overview(c)
                    case .compute: EksComputeTab(clusterName: name)
                    case .networking: networking(c)
                    case .addons: EksAddonsTab(clusterName: name)
                    case .access: EksAccessTab(cluster: c)
                    case .observability: observability(c)
                    case .updates: EksUpdatesTab(clusterName: name)
                    case .tags:
                        ResourceTagsEditor(tags: c.tags, resourceNoun: "cluster", onAdd: { key, value in
                            guard let arn = c.arn else { return }
                            try await api.addEksTag(profile: appState.currentProfile, region: appState.currentRegion, arn: arn, key: key, value: value)
                            await load()
                        }, onRemove: { key in
                            guard let arn = c.arn else { return }
                            try await api.removeEksTag(profile: appState.currentProfile, region: appState.currentRegion, arn: arn, key: key)
                            await load()
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: name) { await load() }
    }

    private func overview(_ c: EksClusterDetail) -> some View {
        DetailTabPage(maxWidth: 900) {
            if !c.healthIssues.isEmpty {
                DetailSection(title: "Health issues") {
                    ForEach(c.healthIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            DetailSection(title: "Details") {
                DetailGrid(items: [
                    DetailItem("Status", c.status),
                    DetailItem("Kubernetes version", c.version),
                    DetailItem("Platform version", c.platformVersion),
                    DetailItem("Support period", c.supportType),
                    DetailItem("Authentication mode", c.authenticationMode),
                    DetailItem("Cluster IAM role", c.roleArn.map(ComputeFormat.arnResourceName)),
                    DetailItem("Secrets encryption", c.secretsEncryptionKeyArn.map(ComputeFormat.arnResourceName) ?? "Off"),
                    DetailItem("Created", Formatters.formatISODate(c.createdAt), monospaced: false),
                ])
            }
            DetailSection(title: "API server endpoint") { CopyableBlock(text: c.endpoint ?? "-") }
            DetailSection(title: "OpenID Connect provider URL") { CopyableBlock(text: c.oidcIssuer ?? "-") }
            DetailSection(title: "Connect with kubectl") {
                CopyableBlock(text: "aws eks update-kubeconfig --name \(c.name) --region \(appState.currentRegion) --profile \(appState.currentProfile)")
            }
            if let arn = c.arn {
                DetailSection(title: "ARN") { CopyableBlock(text: arn) }
            }
        }
    }

    private func networking(_ c: EksClusterDetail) -> some View {
        DetailTabPage(maxWidth: 900) {
            DetailGrid(items: [
                DetailItem("VPC", c.vpcId),
                DetailItem("Cluster security group", c.clusterSecurityGroupId),
                DetailItem("Service IPv4 range", c.serviceIpv4Cidr),
                DetailItem("IP family", c.ipFamily),
                DetailItem("API server endpoint access", endpointAccess(c), monospaced: false),
            ])
            DetailChipsField("Subnets", c.subnetIds)
            DetailChipsField("Additional security groups", c.securityGroupIds)
            if c.endpointPublicAccess == true {
                DetailChipsField("Public access source allowlist", c.publicAccessCidrs)
            }
        }
    }

    private func endpointAccess(_ c: EksClusterDetail) -> String {
        switch (c.endpointPublicAccess ?? false, c.endpointPrivateAccess ?? false) {
        case (true, true): return "Public and private"
        case (true, false): return "Public"
        case (false, true): return "Private"
        default: return "-"
        }
    }

    private func observability(_ c: EksClusterDetail) -> some View {
        DetailTabPage {
            DetailSection(title: "Control plane logging") {
                DetailNote("Enabled log types are sent to CloudWatch Logs under /aws/eks/\(c.name)/cluster.")
                DetailChipsField("Enabled", c.enabledLogTypes)
                DetailChipsField("Disabled", c.disabledLogTypes)
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await api.getEksCluster(profile: appState.currentProfile, region: appState.currentRegion, name: name))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Compute

private struct EksComputeTab: View {
    let clusterName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<EksCompute> = .loading
    @State private var editing: String?
    @State private var minSize = 0
    @State private var desired = 0
    @State private var maxSize = 1
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { compute in
            DetailTabPage(maxWidth: 960) {
                HStack {
                    Text("Node groups · \(compute.nodegroups.count)").font(.headline)
                    Spacer()
                    RefreshButton(compactSize: 22, help: "Refresh") { Task { await load() } }
                }
                if compute.nodegroups.isEmpty {
                    Text("No managed node groups.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(compute.nodegroups) { ng in nodegroupCard(ng) }

                DetailSection(title: "Fargate profiles · \(compute.fargateProfiles.count)") {
                    if compute.fargateProfiles.isEmpty {
                        Text("No Fargate profiles.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(compute.fargateProfiles) { profile in
                        FargateProfileCard(profile: profile)
                    }
                }
            }
        }
        .task(id: clusterName) { await load() }
    }

    private func nodegroupCard(_ ng: EksNodegroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(ng.name).font(.body.bold())
                Spacer()
                StatusBadge(ng.status ?? "-")
            }
            if editing == ng.name {
                scalingEditor(ng)
            } else {
                HStack(spacing: 12) {
                    MetricTile(title: "Desired", value: ComputeFormat.int(ng.desiredSize))
                    MetricTile(title: "Minimum", value: ComputeFormat.int(ng.minSize))
                    MetricTile(title: "Maximum", value: ComputeFormat.int(ng.maxSize))
                    EditButton("Edit scaling") {
                        minSize = ng.minSize ?? 0
                        desired = ng.desiredSize ?? 0
                        maxSize = ng.maxSize ?? 1
                        error = nil
                        editing = ng.name
                    }
                    .controlSize(.small)
                }
            }
            DetailGrid(items: [
                DetailItem("Capacity type", ng.capacityType),
                DetailItem("AMI type", ng.amiType),
                DetailItem("Kubernetes version", ng.version),
                DetailItem("AMI release", ng.releaseVersion),
                DetailItem("Disk size", ng.diskSize.map { "\($0) GiB" }),
                DetailItem("Launch template", ng.launchTemplate),
                DetailItem("Node IAM role", ng.nodeRole.map(ComputeFormat.arnResourceName)),
            ])
            DetailChipsField("Instance types", ng.instanceTypes ?? [])
            DetailChipsField("Subnets", ng.subnets ?? [])
            if let asgs = ng.autoScalingGroups, !asgs.isEmpty { DetailChipsField("Auto Scaling groups", asgs) }
            if let labels = ng.labels, !labels.isEmpty { DetailChipsField("Kubernetes labels", labels.map { "\($0.key)=\($0.value)" }) }
            if let taints = ng.taints, !taints.isEmpty { DetailChipsField("Taints", taints) }
            ForEach(ng.healthIssues ?? [], id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func scalingEditor(_ ng: EksNodegroup) -> some View {
        let valid = minSize <= desired && desired <= maxSize && maxSize >= 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                field("Desired size", $desired)
                field("Minimum size", $minSize)
                field("Maximum size", $maxSize)
            }
            if !valid {
                Text("Needs min ≤ desired ≤ max and max ≥ 1.").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                SaveButton("Update", isLoading: isSaving, isDisabled: !valid || isSaving) { Task { await save(ng.name) } }
                SecondaryButton("Cancel", isDisabled: isSaving) { editing = nil }
            }
            .controlSize(.small)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func field(_ label: String, _ value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                TextField("", value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                Stepper("", value: value, in: 0...10_000).labelsHidden()
            }
        }
    }

    private func save(_ nodegroup: String) async {
        isSaving = true
        error = nil
        do {
            state = .loaded(try await api.updateEksNodegroupScaling(profile: appState.currentProfile, region: appState.currentRegion, cluster: clusterName, nodegroup: nodegroup, minSize: minSize, maxSize: maxSize, desiredSize: desired))
            editing = nil
        } catch {
            self.error = error.friendlyMessage
        }
        isSaving = false
    }

    private func load() async {
        do {
            state = .loaded(try await api.getEksCompute(profile: appState.currentProfile, region: appState.currentRegion, name: clusterName))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

/// One Fargate profile - used in EKS › Compute and on the Fargate screen.
struct FargateProfileCard: View {
    let profile: EksFargateProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(profile.name).font(.body.bold())
                if let cluster = profile.clusterName {
                    Text("· \(cluster)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(profile.status ?? "-")
            }
            DetailChipsField("Selectors (namespace {labels})", profile.selectors)
            DetailChipsField("Subnets", profile.subnets)
            DetailGrid(items: [
                DetailItem("Pod execution role", profile.podExecutionRoleArn.map(ComputeFormat.arnResourceName)),
                DetailItem("Created", Formatters.formatISODate(profile.createdAt), monospaced: false),
            ])
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Add-ons, Access, Updates

private struct EksAddonsTab: View {
    let clusterName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[EksAddon]> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No EKS add-ons installed") { addons in
            Table(addons) {
                TableColumn("Add-on") { a in Text(a.name).font(.caption.monospaced().bold()) }
                    .width(min: 140, ideal: 180)
                TableColumn("Version") { a in Text(a.version ?? "-").font(.caption.monospaced()) }
                    .width(min: 120, ideal: 160)
                TableColumn("Status") { a in StatusBadge(a.status ?? "-") }
                    .width(min: 80, ideal: 100)
                TableColumn("IAM role") { a in Text(a.serviceAccountRoleArn.map(ComputeFormat.arnResourceName) ?? "Inherited from node").font(.caption) }
                TableColumn("Issues") { a in
                    Text(a.healthIssues.isEmpty ? "-" : a.healthIssues.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(a.healthIssues.isEmpty ? Color.secondary : .orange)
                        .lineLimit(2)
                        .help(a.healthIssues.joined(separator: "\n"))
                }
            }
        }
        .task(id: clusterName) { await load() }
    }

    private func load() async {
        do {
            let addons = try await api.getEksAddons(profile: appState.currentProfile, region: appState.currentRegion, name: clusterName)
            state = addons.isEmpty ? .empty : .loaded(addons)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct EksAccessTab: View {
    let cluster: EksClusterDetail

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[EksAccessEntry]> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailNote("Authentication mode: \(cluster.authenticationMode ?? "-"). Access entries need API or API_AND_CONFIG_MAP; clusters on CONFIG_MAP only use the aws-auth ConfigMap.")
                .padding(.horizontal)
                .padding(.bottom, 8)
            LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No access entries") { entries in
                Table(entries) {
                    TableColumn("IAM principal") { e in
                        Text(e.principalArn).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).help(e.principalArn)
                    }
                    TableColumn("Type") { e in Text(e.type ?? "-").font(.caption) }
                        .width(min: 70, ideal: 90)
                    TableColumn("Username") { e in Text(e.username ?? "-").font(.caption.monospaced()).lineLimit(1) }
                    TableColumn("Groups") { e in Text(e.kubernetesGroups.joined(separator: ", ")).font(.caption) }
                    TableColumn("Created") { e in Text(Formatters.formatISODate(e.createdAt)).font(.caption) }
                        .width(min: 110, ideal: 130)
                }
            }
        }
        .task(id: cluster.name) { await load() }
    }

    private func load() async {
        do {
            let entries = try await api.getEksAccessEntries(profile: appState.currentProfile, region: appState.currentRegion, name: cluster.name)
            state = entries.isEmpty ? .empty : .loaded(entries)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct EksUpdatesTab: View {
    let clusterName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[EksUpdate]> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No cluster updates") { updates in
            DetailTabPage(maxWidth: 900) {
                ForEach(updates) { u in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(u.type ?? "-").font(.body.bold())
                            Spacer()
                            StatusBadge(u.status ?? "-")
                        }
                        Text("\(Formatters.formatISODate(u.createdAt)) · \(u.id)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        if !u.params.isEmpty { ValueChips(values: u.params) }
                        ForEach(u.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                    }
                    Divider()
                }
            }
        }
        .task(id: clusterName) { await load() }
    }

    private func load() async {
        do {
            let updates = try await api.getEksUpdates(profile: appState.currentProfile, region: appState.currentRegion, name: clusterName)
            state = updates.isEmpty ? .empty : .loaded(updates)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
