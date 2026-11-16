import SwiftUI

// Elastic Beanstalk environment tabs beyond Overview / Events / variables:
// Health, Configuration, Application versions, Logs, Managed updates.

// MARK: - Health

/// The console's Health page: overall status and causes, request metrics,
/// and the per-instance table (enhanced health only).
struct EBHealthView: View {
    let environmentName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<EbEnvironmentHealth> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { health in
            VStack(alignment: .leading, spacing: 0) {
                summary(health)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                Divider()
                if health.instances.isEmpty {
                    EmptyStateView(message: "No instances")
                } else if health.enhanced {
                    Table(health.instances) {
                        TableColumn("Instance") { i in Text(i.instanceId).font(.caption.monospaced()) }
                            .width(min: 140, ideal: 160)
                        TableColumn("Status") { i in StatusBadge(i.healthStatus ?? i.color ?? "-") }
                            .width(min: 70, ideal: 90)
                        TableColumn("Running") { i in Text(Formatters.formatISODate(i.launchedAt)).font(.caption) }
                            .width(min: 110, ideal: 130)
                        TableColumn("Version") { i in Text(i.deploymentVersion ?? "-").font(.caption.monospaced()).lineLimit(1) }
                        TableColumn("Requests") { i in Text(ComputeFormat.int(i.requestCount)).font(.caption.monospaced()) }
                            .width(60)
                        TableColumn("P90") { i in Text(i.latencyP90.map { String(format: "%.3f s", $0) } ?? "-").font(.caption.monospaced()) }
                            .width(70)
                        TableColumn("CPU") { i in
                            Text(i.cpuIdle.map { String(format: "%.0f%%", 100 - $0) } ?? "-").font(.caption.monospaced())
                        }
                        .width(50)
                        TableColumn("Load 1m") { i in Text(i.loadAverage1.map { String(format: "%.2f", $0) } ?? "-").font(.caption.monospaced()) }
                            .width(60)
                        TableColumn("Causes") { i in
                            Text(i.causes.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .help(i.causes.joined(separator: "\n"))
                        }
                    }
                } else {
                    DetailTabPage {
                        DetailNote("This environment uses basic health reporting - only the overall color is known. Turn on enhanced health under Configuration › Monitoring for per-instance status and request metrics.")
                        DetailChipsField("Instances", health.instances.map(\.instanceId))
                    }
                }
            }
        }
        .task(id: environmentName) { await load() }
    }

    @ViewBuilder
    private func summary(_ h: EbEnvironmentHealth) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatusBadge(h.healthStatus ?? h.color ?? "-")
                if let status = h.status { Text(status).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let refreshed = h.refreshedAt {
                    Text("Refreshed \(Formatters.formatISODate(refreshed))").font(.caption2).foregroundStyle(.tertiary)
                }
                RefreshButton(compactSize: 22, help: "Refresh") { Task { await load() } }
            }
            ForEach(h.causes, id: \.self) { cause in
                Label(cause, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if h.enhanced {
                HStack(spacing: 12) {
                    MetricTile(title: "Requests / \(h.durationSeconds.map { "\($0)s" } ?? "-")", value: ComputeFormat.int(h.requestCount))
                    MetricTile(title: "2xx", value: ComputeFormat.int(h.statusCodes?.status2xx), tint: .green)
                    MetricTile(title: "3xx", value: ComputeFormat.int(h.statusCodes?.status3xx))
                    MetricTile(title: "4xx", value: ComputeFormat.int(h.statusCodes?.status4xx), tint: .orange)
                    MetricTile(title: "5xx", value: ComputeFormat.int(h.statusCodes?.status5xx), tint: .red)
                    MetricTile(title: "P99 / P90 / P50", value: latencyText(h.latency))
                }
                if let c = h.instanceCounts {
                    Text(instanceCountsText(c)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func latencyText(_ l: EbLatency?) -> String {
        guard let l else { return "-" }
        return [l.p99, l.p90, l.p50].map { $0.map { String(format: "%.2f", $0) } ?? "-" }.joined(separator: " / ")
    }

    private func instanceCountsText(_ c: EbInstanceCounts) -> String {
        let parts: [(String, Int?)] = [("Ok", c.ok), ("Info", c.info), ("Warning", c.warning), ("Degraded", c.degraded),
                                       ("Severe", c.severe), ("Pending", c.pending), ("Unknown", c.unknown), ("No data", c.noData)]
        return "Instances: " + parts.compactMap { name, value in
            guard let value, value > 0 else { return nil }
            return "\(value) \(name)"
        }.joined(separator: " · ")
    }

    private func load() async {
        do {
            state = .loaded(try await api.getEbEnvironmentHealth(profile: appState.currentProfile, region: appState.currentRegion, environmentName: environmentName))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Configuration

/// The console's Configuration page: the same category cards (service
/// access, networking, capacity, updates/monitoring), then every option
/// grouped by namespace with a filter. Read-only.
struct EBConfigurationView: View {
    let environmentName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<EbConfiguration> = .loading
    @State private var filter = ""
    @State private var showAll = false

    private struct Category {
        let title: String
        let options: [(label: String, namespace: String, option: String)]
    }

    private static let categories: [Category] = [
        Category(title: "Service access", options: [
            ("Service role", "aws:elasticbeanstalk:environment", "ServiceRole"),
            ("EC2 instance profile", "aws:autoscaling:launchconfiguration", "IamInstanceProfile"),
            ("EC2 key pair", "aws:autoscaling:launchconfiguration", "EC2KeyName"),
        ]),
        Category(title: "Networking", options: [
            ("VPC", "aws:ec2:vpc", "VPCId"),
            ("Instance subnets", "aws:ec2:vpc", "Subnets"),
            ("Load balancer subnets", "aws:ec2:vpc", "ELBSubnets"),
            ("Public IP address", "aws:ec2:vpc", "AssociatePublicIpAddress"),
            ("Load balancer visibility", "aws:ec2:vpc", "ELBScheme"),
        ]),
        Category(title: "Instance traffic and scaling", options: [
            ("Environment type", "aws:elasticbeanstalk:environment", "EnvironmentType"),
            ("Load balancer type", "aws:elasticbeanstalk:environment", "LoadBalancerType"),
            ("Instance types", "aws:ec2:instances", "InstanceTypes"),
            ("Instance type", "aws:autoscaling:launchconfiguration", "InstanceType"),
            ("Min instances", "aws:autoscaling:asg", "MinSize"),
            ("Max instances", "aws:autoscaling:asg", "MaxSize"),
            ("Scaling metric", "aws:autoscaling:trigger", "MeasureName"),
            ("Upper / lower threshold", "aws:autoscaling:trigger", "UpperThreshold"),
            ("Security groups", "aws:autoscaling:launchconfiguration", "SecurityGroups"),
            ("Spot enabled", "aws:ec2:instances", "EnableSpot"),
        ]),
        Category(title: "Updates, monitoring and logging", options: [
            ("Deployment policy", "aws:elasticbeanstalk:command", "DeploymentPolicy"),
            ("Batch size", "aws:elasticbeanstalk:command", "BatchSize"),
            ("Rolling updates", "aws:autoscaling:updatepolicy:rollingupdate", "RollingUpdateEnabled"),
            ("Health reporting", "aws:elasticbeanstalk:healthreporting:system", "SystemType"),
            ("Managed updates", "aws:elasticbeanstalk:managedactions", "ManagedActionsEnabled"),
            ("Update window", "aws:elasticbeanstalk:managedactions", "PreferredStartTime"),
            ("Update level", "aws:elasticbeanstalk:managedactions:platformupdate", "UpdateLevel"),
            ("Log streaming", "aws:elasticbeanstalk:cloudwatch:logs", "StreamLogs"),
            ("Log retention (days)", "aws:elasticbeanstalk:cloudwatch:logs", "RetentionInDays"),
            ("X-Ray", "aws:elasticbeanstalk:xray", "XRayEnabled"),
        ]),
    ]

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { config in
            DetailTabPage(maxWidth: 960) {
                HStack {
                    DetailNote("Read-only. Changes go through the Elastic Beanstalk console or `eb config` - they redeploy the environment.")
                    Spacer()
                    RefreshButton(compactSize: 22, help: "Refresh") { Task { await load() } }
                }
                if let status = config.deploymentStatus {
                    DetailField("Configuration deployment status", status, monospaced: false)
                }
                ForEach(Self.categories, id: \.title) { category in
                    let items = category.options.compactMap { entry -> DetailItem? in
                        guard let value = config.value(entry.namespace, entry.option), !value.isEmpty else { return nil }
                        return DetailItem(entry.label, value)
                    }
                    if !items.isEmpty {
                        DetailSection(title: category.title) {
                            DetailGrid(items: items, minColumnWidth: 220)
                        }
                    }
                }
                allOptions(config)
            }
        }
        .task(id: environmentName) { await load() }
    }

    private func allOptions(_ config: EbConfiguration) -> some View {
        DetailSection(title: "All options · \(config.options.count)") {
            HStack {
                TextField("Filter namespace, option or value", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Toggle("Expand all", isOn: $showAll).toggleStyle(.checkbox)
            }
            let filtered = filter.isEmpty ? config.options : config.options.filter {
                $0.namespace.localizedCaseInsensitiveContains(filter)
                    || $0.optionName.localizedCaseInsensitiveContains(filter)
                    || ($0.value ?? "").localizedCaseInsensitiveContains(filter)
            }
            let namespaces = Dictionary(grouping: filtered, by: \.namespace).sorted { $0.key < $1.key }
            ForEach(namespaces, id: \.key) { namespace, options in
                EBNamespaceGroup(namespace: namespace, options: options, expanded: showAll || !filter.isEmpty)
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await api.getEbEnvironmentConfiguration(profile: appState.currentProfile, region: appState.currentRegion, environmentName: environmentName))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct EBNamespaceGroup: View {
    let namespace: String
    let options: [EbConfigOption]
    let expanded: Bool

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { isExpanded || expanded }, set: { isExpanded = $0 })) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(options) { option in
                    HStack(alignment: .top) {
                        Text(option.resourceName.map { "\(option.optionName) (\($0))" } ?? option.optionName)
                            .font(.caption.monospaced().bold())
                            .frame(width: 260, alignment: .leading)
                        Text(option.value ?? "-")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.vertical, 4)
        } label: {
            Text("\(namespace) · \(options.count)").font(.caption.monospaced())
        }
    }
}

// MARK: - Application versions

/// The application's versions (newest first) with where each is running,
/// and Deploy to this environment.
struct EBApplicationVersionsView: View {
    let detail: EbEnvironmentDetail
    let onDeployed: (EbEnvironmentDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[EbApplicationVersion]> = .loading
    @State private var selection: String?
    @State private var isDeploying = false
    @State private var actionError: String?
    @State private var note: String?

    private var isTerminal: Bool { detail.status == "Terminated" || detail.status == "Terminating" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailActionBar(error: actionError, note: note ?? "Versions of \(detail.applicationName). Running here: \(detail.versionLabel ?? "-")", onRefresh: { Task { await load() } }) {
                ConfirmedActionButton(
                    title: "Deploy",
                    systemImage: "arrow.up.circle",
                    confirmationTitle: "Deploy \(selection ?? "") to \(detail.environmentName)?",
                    confirmationMessage: "The environment's deployment policy decides how instances are updated; with \"All at once\" there's a short outage.",
                    isLoading: isDeploying,
                    isDisabled: selection == nil || selection == detail.versionLabel || isDeploying || isTerminal,
                    role: nil
                ) { Task { await deploy() } }
            }
            LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No application versions") { versions in
                Table(versions, selection: $selection) {
                    TableColumn("Version label") { v in
                        HStack(spacing: 6) {
                            Text(v.versionLabel).font(.caption.monospaced().bold())
                            if v.versionLabel == detail.versionLabel {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Running in this environment")
                            }
                        }
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn("Deployed to") { v in Text(v.deployedTo.isEmpty ? "-" : v.deployedTo.joined(separator: ", ")).font(.caption) }
                    TableColumn("Created") { v in Text(Formatters.formatISODate(v.dateCreated)).font(.caption) }
                        .width(min: 110, ideal: 140)
                    TableColumn("Status") { v in StatusBadge(v.status ?? "-") }
                        .width(min: 70, ideal: 90)
                    TableColumn("Source") { v in
                        Text(v.sourceBundle ?? v.sourceRepository ?? "-")
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(v.sourceBundle ?? v.sourceRepository ?? "")
                    }
                    TableColumn("Description") { v in Text(v.description ?? "").font(.caption).lineLimit(1).help(v.description ?? "") }
                }
            }
        }
        .task(id: detail.applicationName) { await load() }
    }

    private func deploy() async {
        guard let selection else { return }
        isDeploying = true
        actionError = nil
        do {
            let updated = try await api.deployEbApplicationVersion(profile: appState.currentProfile, region: appState.currentRegion, environmentName: detail.environmentName, versionLabel: selection)
            note = "Deployment of \(selection) started - follow it under Events."
            onDeployed(updated)
        } catch {
            actionError = error.friendlyMessage
        }
        isDeploying = false
    }

    private func load() async {
        do {
            let versions = try await api.getEbApplicationVersions(profile: appState.currentProfile, region: appState.currentRegion, applicationName: detail.applicationName)
            state = versions.isEmpty ? .empty : .loaded(versions)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Logs

/// "Request logs": last 100 lines shown inline per instance, full logs as a
/// download link (presigned S3 URL, valid ~15 minutes).
struct EBLogsView: View {
    let environmentName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var entries: [EbLogEntry] = []
    @State private var infoType: String?
    @State private var pending: String?
    @State private var error: String?
    @State private var selectedInstance: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailActionBar(error: error, note: pending != nil ? "Waiting for the instances to upload their logs - usually 10-30 seconds." : "Logs are collected from every instance on request.") {
                AppButton("Last 100 lines", kind: .run, systemImage: "text.alignleft", isLoading: pending == "tail", isDisabled: pending != nil) {
                    Task { await request("tail") }
                }
                AppButton("Full logs", kind: .download, systemImage: "archivebox", isLoading: pending == "bundle", isDisabled: pending != nil) {
                    Task { await request("bundle") }
                }
            }
            if entries.isEmpty {
                EmptyStateView(message: pending == nil ? "Request logs to see them here" : "Collecting logs…")
            } else if infoType == "bundle" {
                DetailTabPage {
                    DetailNote("Each link downloads a zip of /var/log from one instance. Links expire after about 15 minutes.")
                    ForEach(entries) { entry in
                        HStack {
                            Text(entry.instanceId).font(.caption.monospaced().bold())
                            Text(Formatters.formatISODate(entry.sampleTimestamp)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            ExternalLinkButton(title: "Download", urlString: entry.url)
                        }
                        Divider()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Picker("Instance", selection: Binding(get: { selectedInstance ?? entries.first?.instanceId ?? "" }, set: { selectedInstance = $0 })) {
                        ForEach(entries) { Text($0.instanceId).tag($0.instanceId) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    if let entry = entries.first(where: { $0.instanceId == (selectedInstance ?? entries.first?.instanceId) }) {
                        if let content = entry.content {
                            ScrollView([.vertical, .horizontal]) {
                                Text(content)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            .background(Color.secondary.opacity(0.05))
                        } else {
                            VStack(alignment: .leading) {
                                Text("Couldn't download the log text.").font(.caption).foregroundStyle(.secondary)
                                ExternalLinkButton(title: "Open in browser", urlString: entry.url)
                            }
                            .padding()
                        }
                    }
                }
            }
        }
    }

    private func request(_ type: String) async {
        pending = type
        error = nil
        do {
            let result = try await api.fetchEbEnvironmentLogs(profile: appState.currentProfile, region: appState.currentRegion, environmentName: environmentName, infoType: type)
            entries = result
            infoType = type
            selectedInstance = result.first?.instanceId
            if result.isEmpty { error = "No instance uploaded logs in time - try again in a moment." }
        } catch {
            self.error = error.friendlyMessage
        }
        pending = nil
    }
}

// MARK: - Managed updates

/// Scheduled platform updates (with Apply now) and the update history.
struct EBManagedUpdatesView: View {
    let environmentName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<EbManagedUpdates> = .loading
    @State private var applying: String?
    @State private var actionError: String?

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { updates in
            DetailTabPage(maxWidth: 900) {
                DetailSection(title: "Scheduled updates · \(updates.pending.count)") {
                    if updates.pending.isEmpty {
                        Text("Nothing scheduled. Managed updates are configured under Configuration › Updates.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(updates.pending) { action in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.actionDescription ?? action.actionType ?? action.actionId).font(.body)
                                Text("\(action.actionType ?? "-") · window \(Formatters.formatISODate(action.windowStartTime))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusBadge(action.status ?? "-")
                            ConfirmedActionButton(
                                title: "Apply now",
                                systemImage: "bolt",
                                confirmationTitle: "Apply this update now?",
                                confirmationMessage: "The platform update runs immediately instead of in the maintenance window, using the environment's deployment policy.",
                                isLoading: applying == action.actionId,
                                isDisabled: applying != nil || action.status != "Scheduled",
                                role: nil
                            ) { Task { await apply(action.actionId) } }
                            .controlSize(.small)
                        }
                        Divider()
                    }
                    if let actionError {
                        Text(actionError).font(.caption).foregroundStyle(.red)
                    }
                }

                DetailSection(title: "Update history") {
                    if updates.history.isEmpty {
                        Text("No managed updates have run yet.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(updates.history) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.actionDescription ?? item.actionType ?? item.actionId).font(.body)
                                Spacer()
                                StatusBadge(item.status ?? "-")
                            }
                            Text("\(Formatters.formatISODate(item.executedTime)) → \(Formatters.formatISODate(item.finishedTime))")
                                .font(.caption2).foregroundStyle(.tertiary)
                            if let failure = item.failureDescription {
                                Text("\(item.failureType ?? "Failure"): \(failure)").font(.caption).foregroundStyle(.red)
                            }
                        }
                        Divider()
                    }
                }
            }
        }
        .task(id: environmentName) { await load() }
    }

    private func apply(_ actionId: String) async {
        applying = actionId
        actionError = nil
        do {
            state = .loaded(try await api.applyEbManagedAction(profile: appState.currentProfile, region: appState.currentRegion, environmentName: environmentName, actionId: actionId))
        } catch {
            actionError = error.friendlyMessage
        }
        applying = nil
    }

    private func load() async {
        do {
            state = .loaded(try await api.getEbManagedUpdates(profile: appState.currentProfile, region: appState.currentRegion, environmentName: environmentName))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
