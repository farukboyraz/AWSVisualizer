import SwiftUI

/// Mirrors an environment's page in the Elastic Beanstalk console: the
/// Actions menu (Restart app servers, Rebuild, Swap environment domain,
/// Terminate) above the tabs, then Overview, Health, Events,
/// Configuration, Application versions, Logs, Managed updates,
/// Environment variables and Tags.
struct EBEnvironmentDetailView: View {
    let environmentName: String
    var onTerminated: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    private enum DetailTab: String, CaseIterable {
        case overview = "Overview"
        case health = "Health"
        case events = "Events"
        case configuration = "Configuration"
        case versions = "Application versions"
        case logs = "Logs"
        case managedUpdates = "Managed updates"
        case variables = "Environment variables"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .overview
    @State private var detailState: LoadState<EbEnvironmentDetail> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeader(title: detail.environmentName, subtitle: "\(detail.applicationName) · \(detail.status)", status: detail.healthStatus ?? detail.health, tab: $tab)
                    EBActionBar(detail: detail, onRefresh: { Task { await loadDetail(showLoading: false) } }, onTerminated: onTerminated)

                    Group {
                        switch tab {
                        case .overview:
                            EBOverviewView(detail: detail, showHealth: { tab = .health }, showEvents: { tab = .events })
                        case .health:
                            EBHealthView(environmentName: environmentName)
                        case .events:
                            EBEventsView(environmentName: environmentName)
                        case .configuration:
                            EBConfigurationView(environmentName: environmentName)
                        case .versions:
                            EBApplicationVersionsView(detail: detail, onDeployed: { detailState = .loaded($0) })
                        case .logs:
                            EBLogsView(environmentName: environmentName)
                        case .managedUpdates:
                            EBManagedUpdatesView(environmentName: environmentName)
                        case .variables:
                            EBEnvironmentVariablesView(detail: detail, onUpdated: { detailState = .loaded($0) })
                        case .tags:
                            ResourceTagsEditor(tags: detail.tags, resourceNoun: "environment", onAdd: { key, value in
                                guard let arn = detail.environmentArn else { return }
                                detailState = .loaded(try await api.addEbEnvironmentTag(profile: appState.currentProfile, region: appState.currentRegion, environmentName: detail.environmentName, environmentArn: arn, key: key, value: value))
                            }, onRemove: { key in
                                guard let arn = detail.environmentArn else { return }
                                detailState = .loaded(try await api.removeEbEnvironmentTag(profile: appState.currentProfile, region: appState.currentRegion, environmentName: detail.environmentName, environmentArn: arn, key: key))
                            })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: environmentName) {
            await loadDetail()
        }
    }

    private func loadDetail(showLoading: Bool = true) async {
        if showLoading { detailState = .loading }
        do {
            let detail = try await api.getEbEnvironmentDetail(profile: appState.currentProfile, region: appState.currentRegion, environmentName: environmentName)
            detailState = .loaded(detail)
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

/// The console's "Actions" menu as a row of buttons.
private struct EBActionBar: View {
    let detail: EbEnvironmentDetail
    let onRefresh: () -> Void
    let onTerminated: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var pending: String?
    @State private var actionError: String?
    @State private var note: String?
    @State private var showSwap = false
    @State private var otherEnvironments: [EBEnvironment] = []
    @State private var swapTarget = ""

    private var isTerminal: Bool { detail.status == "Terminated" || detail.status == "Terminating" }

    var body: some View {
        DetailActionBar(error: actionError, note: note, onRefresh: onRefresh) {
            ConfirmedActionButton(
                title: "Restart app servers",
                systemImage: "arrow.clockwise",
                confirmationTitle: "Restart the app servers of \(detail.environmentName)?",
                confirmationMessage: "The web/app server process restarts on every instance. Instances aren't replaced.",
                isLoading: pending == "restart",
                isDisabled: isTerminal || pending != nil
            ) { Task { await run("restart") } }
            ConfirmedActionButton(
                title: "Rebuild",
                systemImage: "hammer",
                confirmationTitle: "Rebuild \(detail.environmentName)?",
                confirmationMessage: "Every resource in the environment (instances, load balancer, Auto Scaling group) is terminated and recreated. Expect downtime.",
                isLoading: pending == "rebuild",
                isDisabled: isTerminal || pending != nil
            ) { Task { await run("rebuild") } }
            AppButton("Swap domain", kind: .warning, systemImage: "arrow.left.arrow.right", isLoading: pending == "swap", isDisabled: isTerminal || pending != nil) {
                showSwap = true
            }
            .popover(isPresented: $showSwap, arrowEdge: .bottom) { swapPopover }
            if !isTerminal {
                DeleteButton("Terminate", isLoading: pending == "terminate", isDisabled: pending != nil) {
                    Task { await run("terminate") }
                }
            }
        }
    }

    private var swapPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Swap environment domain").font(.headline)
            Text("Exchanges the CNAMEs of \(detail.environmentName) and the chosen environment - the usual blue/green cut-over.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $swapTarget) {
                Text("Select environment").tag("")
                ForEach(otherEnvironments) { env in
                    Text(env.environmentName ?? "-").tag(env.environmentName ?? "")
                }
            }
            .labelsHidden()
            HStack {
                Spacer()
                SecondaryButton("Cancel") { showSwap = false }
                WarningButton("Swap", systemImage: "arrow.left.arrow.right", isDisabled: swapTarget.isEmpty) {
                    showSwap = false
                    Task { await run("swap") }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .task {
            let all = (try? await api.getEnvironments(profile: appState.currentProfile, region: appState.currentRegion)) ?? []
            otherEnvironments = all.filter { $0.environmentName != detail.environmentName && $0.status != "Terminated" }
        }
    }

    private func run(_ action: String) async {
        pending = action
        actionError = nil
        note = nil
        let profile = appState.currentProfile
        let region = appState.currentRegion
        do {
            switch action {
            case "restart":
                try await api.restartEbAppServer(profile: profile, region: region, environmentName: detail.environmentName)
                note = "Restart requested - follow it under Events."
            case "rebuild":
                try await api.rebuildEbEnvironment(profile: profile, region: region, environmentName: detail.environmentName)
                note = "Rebuild started - follow it under Events."
            case "swap":
                try await api.swapEbEnvironmentCnames(profile: profile, region: region, sourceEnvironmentName: detail.environmentName, destinationEnvironmentName: swapTarget)
                note = "Domains swapped with \(swapTarget). DNS can take a few minutes to follow."
                swapTarget = ""
            case "terminate":
                try await api.terminateEbEnvironment(profile: profile, region: region, environmentName: detail.environmentName)
                onTerminated()
            default:
                break
            }
            if action != "terminate" { onRefresh() }
        } catch {
            actionError = error.friendlyMessage
        }
        pending = nil
    }
}

/// "Environment overview" + "Platform" cards, the AWS resources behind the
/// environment, and the latest events.
private struct EBOverviewView: View {
    let detail: EbEnvironmentDetail
    let showHealth: () -> Void
    let showEvents: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var resources: LoadState<EbEnvironmentResources> = .loading
    @State private var events: [EbEvent] = []

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Environment overview") {
                DetailGrid(items: [
                    DetailItem("Health", [detail.health, detail.healthStatus].compactMap { $0 }.joined(separator: " · ")),
                    DetailItem("Environment ID", detail.environmentId),
                    DetailItem("Domain", detail.cname),
                    DetailItem("Application name", detail.applicationName),
                    DetailItem("Running version", detail.versionLabel),
                    DetailItem("Status", detail.status),
                ])
                HStack(spacing: 16) {
                    Button("View health", action: showHealth).buttonStyle(.link).font(.caption)
                    if let cname = detail.cname {
                        ExternalLinkButton(title: "Open domain", urlString: "http://\(cname)")
                    }
                }
            }

            DetailSection(title: "Platform") {
                DetailGrid(items: [
                    DetailItem("Platform", detail.solutionStackName),
                    DetailItem("Platform ARN", detail.platformArn.map(ComputeFormat.arnResourceName)),
                    DetailItem("Tier", detail.tier.map { "\($0.name) (\($0.type))" }),
                    DetailItem("Endpoint", detail.endpointURL),
                    DetailItem("Created", Formatters.formatISODate(detail.dateCreated), monospaced: false),
                    DetailItem("Last updated", Formatters.formatISODate(detail.dateUpdated), monospaced: false),
                ])
            }

            DetailSection(title: "Resources") {
                switch resources {
                case .loaded(let r):
                    DetailChipsField("EC2 instances", r.instances)
                    DetailChipsField("Auto Scaling groups", r.autoScalingGroups)
                    if !r.loadBalancers.isEmpty { DetailChipsField("Load balancers", r.loadBalancers.map(ComputeFormat.arnResourceName)) }
                    if !r.launchTemplates.isEmpty { DetailChipsField("Launch templates", r.launchTemplates) }
                    if !r.launchConfigurations.isEmpty { DetailChipsField("Launch configurations", r.launchConfigurations) }
                    if !r.queues.isEmpty { DetailChipsField("SQS queues (worker)", r.queues.map(\.name)) }
                    if !r.triggers.isEmpty { DetailChipsField("Triggers", r.triggers) }
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.orange)
                default:
                    ProgressView().controlSize(.small)
                }
            }

            DetailSection(title: "Recent events") {
                if events.isEmpty {
                    Text("No recent events.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(events.prefix(5)) { event in
                    HStack(alignment: .top, spacing: 8) {
                        StatusBadge(event.severity ?? "-")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.message ?? "").font(.caption).fixedSize(horizontal: false, vertical: true)
                            Text(Formatters.formatDate(event.eventDate)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Button("All events", action: showEvents).buttonStyle(.link).font(.caption)
            }
        }
        .task(id: detail.environmentName) { await load() }
    }

    private func load() async {
        let profile = appState.currentProfile
        let region = appState.currentRegion
        async let r = api.getEbEnvironmentResources(profile: profile, region: region, environmentName: detail.environmentName)
        async let e = api.getEvents(profile: profile, region: region, environment: detail.environmentName)
        do { resources = .loaded(try await r) } catch { resources = .failed(error.friendlyMessage) }
        events = (try? await e) ?? []
    }
}

private struct EBEventsView: View {
    let environmentName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var eventsState: LoadState<[EbEvent]> = .loading

    var body: some View {
        LoadableContent(eventsState, retry: { Task { await load() } }, emptyMessage: "No events") { events in
            Table(events) {
                TableColumn("Status") { event in
                    if let severity = event.severity {
                        StatusBadge(severity)
                    } else {
                        Text("-")
                    }
                }
                .width(min: 50, ideal: 65, max: 80)

                TableColumn("Date") { event in
                    Text(Formatters.formatDate(event.eventDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 130, max: 160)

                TableColumn("Description") { event in
                    Text(event.message ?? "")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(event.message ?? "")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        eventsState = .loading
        do {
            let events = try await api.getEvents(profile: appState.currentProfile, region: appState.currentRegion, environment: environmentName)
            eventsState = events.isEmpty ? .empty : .loaded(events)
        } catch {
            eventsState = .failed(error.friendlyMessage)
        }
    }
}

private struct EBEnvironmentVariablesView: View {
    let detail: EbEnvironmentDetail
    var onUpdated: (EbEnvironmentDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var newKey = ""
    @State private var newValue = ""
    @State private var isAdding = false
    @State private var removingKey: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Environment variables")
                    .font(.headline)
                Text("Deployed to every instance in this environment as process environment variables. Changing these triggers a new deployment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if detail.environmentVariables.isEmpty {
                    Text("No environment variables set.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(detail.environmentVariables) { variable in
                            HStack {
                                Text(variable.key)
                                    .font(.caption.monospaced().bold())
                                Text(variable.value)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                DeleteButton(compactSize: 20, isLoading: removingKey == variable.key, isDisabled: removingKey != nil, help: "Remove Variable") {
                                    Task { await remove(variable.key) }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("KEY", text: $newKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 180)
                    TextField("Value", text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    NewButton("Set", isLoading: isAdding, isDisabled: newKey.trimmingCharacters(in: .whitespaces).isEmpty) {
                        Task { await add() }
                    }
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func add() async {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        isAdding = true
        error = nil
        do {
            let updated = try await api.setEbEnvironmentVariable(profile: appState.currentProfile, region: appState.currentRegion, environmentName: detail.environmentName, key: key, value: newValue)
            onUpdated(updated)
            newKey = ""
            newValue = ""
        } catch {
            self.error = error.friendlyMessage
        }
        isAdding = false
    }

    private func remove(_ key: String) async {
        removingKey = key
        error = nil
        do {
            let updated = try await api.removeEbEnvironmentVariable(profile: appState.currentProfile, region: appState.currentRegion, environmentName: detail.environmentName, key: key)
            onUpdated(updated)
        } catch {
            self.error = error.friendlyMessage
        }
        removingKey = nil
    }
}
