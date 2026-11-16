import SwiftUI

/// App Runner services: list on the left, the console's service page on
/// the right (Overview, Activity, Configuration, Custom domains, Tags).
struct AppRunnerView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[AppRunnerServiceSummary]> = .loading
    @State private var selectedArn: String?

    private var selectedName: String? {
        guard case .loaded(let services) = state else { return nil }
        return services.first { $0.serviceArn == selectedArn }?.serviceName
    }

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 300, minWidth: 220, maxWidth: 480, isDetailActive: selectedArn != nil, onBack: { selectedArn = nil }, backTitle: "Services", detailTitle: selectedName) {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle("App Runner")
                    ScreenFilterField(text: $filter)
                    LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No App Runner services in this region") { unfilteredServices in
                        let services = unfilteredServices.matching(filter)
                        List(services, selection: $selectedArn) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(s.serviceName).font(.body.bold()).lineLimit(1)
                                    Spacer()
                                    StatusBadge(s.status ?? "-")
                                }
                                Text(s.serviceUrl ?? "-").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .padding(.vertical, 2)
                            .tag(s.serviceArn)
                        }
                        .listStyle(.sidebar)
                    }
                    PanelActionBar {
                        RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
                    }
                }
            } detail: {
                if let selectedArn {
                    AppRunnerServiceDetailView(arn: selectedArn, onChanged: { Task { await loadData() } }).id(selectedArn)
                } else {
                    EmptyStateView(message: "Select a service")
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
            let services = try await api.getAppRunnerServices(profile: appState.currentProfile, region: appState.currentRegion)
            state = services.isEmpty ? .empty : .loaded(services)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

struct AppRunnerServiceDetailView: View {
    let arn: String
    let onChanged: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case overview = "Overview"
        case activity = "Activity"
        case configuration = "Configuration"
        case domains = "Custom domains"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .overview
    @State private var state: LoadState<AppRunnerServiceDetail> = .loading
    @State private var pending: String?
    @State private var actionError: String?
    @State private var note: String?

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { s in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(title: s.serviceName, subtitle: s.serviceUrl, status: s.status, tab: $tab)
                actionBar(s)
                Group {
                    switch tab {
                    case .overview: overview(s)
                    case .activity: AppRunnerActivityTab(arn: arn, mode: .operations)
                    case .configuration: configuration(s)
                    case .domains: AppRunnerActivityTab(arn: arn, mode: .domains)
                    case .tags:
                        ResourceTagsEditor(tags: s.tags, resourceNoun: "service", onAdd: { key, value in
                            state = .loaded(try await api.addAppRunnerTag(profile: appState.currentProfile, region: appState.currentRegion, arn: arn, key: key, value: value))
                        }, onRemove: { key in
                            state = .loaded(try await api.removeAppRunnerTag(profile: appState.currentProfile, region: appState.currentRegion, arn: arn, key: key))
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: arn) { await load() }
    }

    private func actionBar(_ s: AppRunnerServiceDetail) -> some View {
        let running = s.status == "RUNNING"
        let paused = s.status == "PAUSED"
        return DetailActionBar(error: actionError, note: note, onRefresh: { Task { await load() } }) {
            ConfirmedActionButton(
                title: "Deploy", systemImage: "arrow.up.circle",
                confirmationTitle: "Deploy \(s.serviceName)?",
                confirmationMessage: s.sourceType == "Container image"
                    ? "Pulls the latest \(s.imageIdentifier ?? "image") and rolls it out with no downtime."
                    : "Builds the latest commit of \(s.branch ?? "the branch") and rolls it out with no downtime.",
                isLoading: pending == "deploy", isDisabled: !running || pending != nil, role: nil
            ) { Task { await run("deploy") } }
            if paused {
                ConfirmedActionButton(
                    title: "Resume", systemImage: "play.fill",
                    confirmationTitle: "Resume \(s.serviceName)?",
                    confirmationMessage: "The service starts serving traffic again and billing for provisioned instances resumes.",
                    isLoading: pending == "resume", isDisabled: pending != nil, role: nil
                ) { Task { await run("resume") } }
            } else {
                ConfirmedActionButton(
                    title: "Pause", systemImage: "pause.fill",
                    confirmationTitle: "Pause \(s.serviceName)?",
                    confirmationMessage: "The service stops serving traffic (requests fail) until resumed. Configuration and URL are kept.",
                    isLoading: pending == "pause", isDisabled: !running || pending != nil
                ) { Task { await run("pause") } }
            }
        }
    }

    private func overview(_ s: AppRunnerServiceDetail) -> some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Default domain") {
                if let url = s.serviceUrl {
                    CopyableBlock(text: "https://\(url)")
                    ExternalLinkButton(title: "Open", urlString: "https://\(url)")
                }
            }
            DetailSection(title: "Service overview") {
                DetailGrid(items: [
                    DetailItem("Status", s.status),
                    DetailItem("Service ID", s.serviceId),
                    DetailItem("Source", s.sourceType, monospaced: false),
                    DetailItem(s.sourceType == "Container image" ? "Image" : "Repository", s.imageIdentifier ?? s.repositoryUrl),
                    DetailItem("Branch", s.branch),
                    DetailItem("Automatic deployment", ComputeFormat.bool(s.autoDeploymentsEnabled)),
                    DetailItem("Created", Formatters.formatISODate(s.createdAt), monospaced: false),
                    DetailItem("Updated", Formatters.formatISODate(s.updatedAt), monospaced: false),
                ])
            }
            if let id = s.serviceId {
                DetailSection(title: "Application logs (CloudWatch)") {
                    CopyableBlock(text: "/aws/apprunner/\(s.serviceName)/\(id)/application")
                }
            }
            DetailSection(title: "ARN") { CopyableBlock(text: s.serviceArn) }
        }
    }

    private func configuration(_ s: AppRunnerServiceDetail) -> some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Source and deployment") {
                DetailGrid(items: [
                    DetailItem("Source", s.sourceType, monospaced: false),
                    DetailItem("Repository type", s.imageRepositoryType),
                    DetailItem("Image / repository", s.imageIdentifier ?? s.repositoryUrl),
                    DetailItem("Branch", s.branch),
                    DetailItem("Deployment trigger", s.autoDeploymentsEnabled == true ? "Automatic" : "Manual", monospaced: false),
                ])
            }
            DetailSection(title: "Build and service settings") {
                DetailGrid(items: [
                    DetailItem("Runtime", s.runtime),
                    DetailItem("Build command", s.buildCommand),
                    DetailItem("Start command", s.startCommand),
                    DetailItem("Port", s.port),
                ])
                if !s.environmentVariables.isEmpty {
                    DetailChipsField("Environment variables", s.environmentVariables.map { "\($0.key)=\($0.value)" })
                }
                if !s.secretNames.isEmpty {
                    DetailChipsField("Secrets (references, values not shown)", s.secretNames)
                }
            }
            DetailSection(title: "Instance") {
                DetailGrid(items: [
                    DetailItem("CPU", s.cpu.map(formatCpu)),
                    DetailItem("Memory", s.memory.map(formatMemory)),
                    DetailItem("Instance role", s.instanceRoleArn.map(ComputeFormat.arnResourceName)),
                ])
            }
            DetailSection(title: "Auto scaling") {
                DetailField("Configuration", s.autoScalingConfigurationName ?? s.autoScalingConfigurationArn.map(ComputeFormat.arnResourceName) ?? "-")
            }
            DetailSection(title: "Health check") {
                DetailField("Settings", s.healthCheck ?? "-")
            }
            DetailSection(title: "Networking") {
                DetailGrid(items: [
                    DetailItem("Incoming traffic", s.isPubliclyAccessible == false ? "Private endpoint" : "Public endpoint", monospaced: false),
                    DetailItem("Outgoing traffic", s.egressType == "VPC" ? "Custom VPC" : "Public access", monospaced: false),
                    DetailItem("VPC connector", s.vpcConnectorArn.map(ComputeFormat.arnResourceName)),
                    DetailItem("IP address type", s.ipAddressType),
                ])
            }
            DetailSection(title: "Observability and security") {
                DetailGrid(items: [
                    DetailItem("Tracing", s.observabilityEnabled == true ? "On" : "Off", monospaced: false),
                    DetailItem("Encryption key", s.kmsKey.map(ComputeFormat.arnResourceName) ?? "AWS-owned key"),
                ])
            }
        }
    }

    /// App Runner reports "1024" (vCPU units) or "1 vCPU".
    private func formatCpu(_ raw: String) -> String {
        if let units = Double(raw) { return "\(Formatters.formatNumber(units / 1024, decimals: units.truncatingRemainder(dividingBy: 1024) == 0 ? 0 : 2)) vCPU" }
        return raw
    }

    private func formatMemory(_ raw: String) -> String {
        if let mb = Double(raw) { return mb >= 1024 ? "\(Formatters.formatNumber(mb / 1024, decimals: mb.truncatingRemainder(dividingBy: 1024) == 0 ? 0 : 1)) GB" : "\(Int(mb)) MB" }
        return raw
    }

    private func run(_ action: String) async {
        pending = action
        actionError = nil
        note = nil
        do {
            state = .loaded(try await api.runAppRunnerAction(profile: appState.currentProfile, region: appState.currentRegion, arn: arn, action: action))
            note = action == "deploy" ? "Deployment started - follow it under Activity." : nil
            onChanged()
        } catch {
            actionError = error.friendlyMessage
        }
        pending = nil
    }

    private func load() async {
        do {
            state = .loaded(try await api.getAppRunnerService(profile: appState.currentProfile, region: appState.currentRegion, arn: arn))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

/// Activity (operations) or Custom domains - both come from one call.
private struct AppRunnerActivityTab: View {
    enum Mode { case operations, domains }

    let arn: String
    let mode: Mode

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<AppRunnerActivity> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { activity in
            switch mode {
            case .operations:
                if activity.operations.isEmpty {
                    EmptyStateView(message: "No operations yet")
                } else {
                    Table(activity.operations) {
                        TableColumn("Operation") { o in Text(o.type ?? "-").font(.caption.bold()) }
                        TableColumn("Status") { o in StatusBadge(o.status ?? "-") }
                            .width(min: 90, ideal: 120)
                        TableColumn("Started") { o in Text(Formatters.formatISODate(o.startedAt)).font(.caption) }
                        TableColumn("Ended") { o in Text(Formatters.formatISODate(o.endedAt)).font(.caption) }
                        TableColumn("ID") { o in Text(o.id).font(.caption2.monospaced()).lineLimit(1) }
                    }
                }
            case .domains:
                DetailTabPage {
                    if let target = activity.dnsTarget {
                        DetailSection(title: "DNS target (CNAME your domain here)") { CopyableBlock(text: target) }
                    }
                    if activity.customDomains.isEmpty {
                        Text("No custom domains linked.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(activity.customDomains) { d in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(d.domainName).font(.body.bold().monospaced())
                                if d.enableWWWSubdomain == true { Text("+ www").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                StatusBadge(d.status ?? "-")
                            }
                            ForEach(d.validationRecords, id: \.self) { r in
                                Text(r).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Divider()
                    }
                }
            }
        }
        .task(id: arn) { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await api.getAppRunnerActivity(profile: appState.currentProfile, region: appState.currentRegion, arn: arn))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
