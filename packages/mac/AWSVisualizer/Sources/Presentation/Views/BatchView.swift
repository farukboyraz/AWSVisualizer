import SwiftUI

/// One row of the Batch list - the console's left nav has Job queues,
/// Compute environments and Job definitions as separate pages; here they
/// are sections of one list.
enum BatchItem: Hashable {
    case queue(String)
    case computeEnvironment(String)
    case jobDefinition(String)
}

struct BatchView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<BatchOverview> = .loading
    @State private var selection: BatchItem?

    private var detailTitle: String? {
        switch selection {
        case .queue(let name), .computeEnvironment(let name): return name
        case .jobDefinition(let arn): return ComputeFormat.arnResourceName(arn)
        case nil: return nil
        }
    }

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 320, minWidth: 240, maxWidth: 500, isDetailActive: selection != nil, onBack: { selection = nil }, backTitle: "Batch", detailTitle: detailTitle) {
                listPanel
            } detail: {
                switch selection {
                case .queue(let name):
                    BatchJobQueueDetailView(name: name).id("q-\(name)")
                case .computeEnvironment(let name):
                    BatchComputeEnvironmentDetailView(name: name).id("ce-\(name)")
                case .jobDefinition(let arn):
                    BatchJobDefinitionDetailView(arn: arn).id("jd-\(arn)")
                case nil:
                    EmptyStateView(message: "Select a job queue, compute environment or job definition")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Batch")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No Batch resources in this region") { overview in
                List(selection: $selection) {
                    Section("Job queues · \(overview.jobQueues.count)") {
                        ForEach(overview.jobQueues.matching(filter)) { q in
                            row(q.jobQueueName, caption: "Priority \(ComputeFormat.int(q.priority)) · \(q.computeEnvironments.joined(separator: ", "))", status: q.state)
                                .tag(BatchItem.queue(q.jobQueueName))
                        }
                    }
                    Section("Compute environments · \(overview.computeEnvironments.count)") {
                        ForEach(overview.computeEnvironments.matching(filter)) { ce in
                            row(ce.computeEnvironmentName, caption: [ce.type, ce.resourceType, ce.maxvCpus.map { "max \($0) vCPU" }].compactMap { $0 }.joined(separator: " · "), status: ce.state)
                                .tag(BatchItem.computeEnvironment(ce.computeEnvironmentName))
                        }
                    }
                    Section("Job definitions · \(overview.jobDefinitions.count)") {
                        ForEach(overview.jobDefinitions.matching(filter)) { jd in
                            row("\(jd.jobDefinitionName):\(jd.revision)", caption: jd.image ?? jd.type ?? "", status: nil)
                                .tag(BatchItem.jobDefinition(jd.jobDefinitionArn))
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            PanelActionBar {
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
            }
        }
    }

    private func row(_ title: String, caption: String, status: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.body.bold()).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let status { StatusBadge(status) }
            }
            if !caption.isEmpty {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private func loadData() async {
        state = .loading
        do {
            let overview = try await api.getBatchOverview(profile: appState.currentProfile, region: appState.currentRegion)
            let isEmpty = overview.jobQueues.isEmpty && overview.computeEnvironments.isEmpty && overview.jobDefinitions.isEmpty
            state = isEmpty ? .empty : .loaded(overview)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Job queue

struct BatchJobQueueDetailView: View {
    let name: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case jobs = "Jobs"
        case details = "Details"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .jobs
    @State private var detailState: LoadState<BatchJobQueue> = .loading
    @State private var isToggling = false
    @State private var actionError: String?

    var body: some View {
        LoadableContent(detailState, retry: { Task { await load() } }) { queue in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(title: queue.jobQueueName, subtitle: "Job queue · priority \(ComputeFormat.int(queue.priority))", status: queue.state, tab: $tab)
                DetailActionBar(error: actionError, note: queue.statusReason.flatMap { $0 == "JobQueue Healthy" ? nil : $0 }, onRefresh: { Task { await load() } }) {
                    let enabled = queue.state == "ENABLED"
                    ConfirmedActionButton(
                        title: enabled ? "Disable" : "Enable",
                        systemImage: enabled ? "pause.circle" : "play.circle",
                        confirmationTitle: "\(enabled ? "Disable" : "Enable") \(queue.jobQueueName)?",
                        confirmationMessage: enabled
                            ? "New jobs can't be submitted to a disabled queue. Jobs already in it keep running."
                            : "The queue accepts new jobs again.",
                        isLoading: isToggling,
                        isDisabled: isToggling,
                        role: enabled ? .destructive : nil
                    ) { Task { await toggle(!enabled) } }
                }
                Group {
                    switch tab {
                    case .jobs:
                        BatchJobsTab(queueName: queue.jobQueueName)
                    case .details:
                        DetailTabPage {
                            DetailSection(title: "Job queue overview") {
                                DetailGrid(items: [
                                    DetailItem("State", queue.state),
                                    DetailItem("Status", queue.status),
                                    DetailItem("Priority", ComputeFormat.int(queue.priority)),
                                    DetailItem("Scheduling policy", queue.schedulingPolicyArn.map(ComputeFormat.arnResourceName) ?? "FIFO"),
                                ])
                                DetailField("Status reason", queue.statusReason ?? "-", monospaced: false)
                            }
                            DetailSection(title: "Connected compute environments (in order)") {
                                ValueChips(values: queue.computeEnvironments)
                            }
                            DetailSection(title: "ARN") { CopyableBlock(text: queue.jobQueueArn) }
                        }
                    case .tags:
                        BatchTagsTab(arn: queue.jobQueueArn, tags: queue.tags, noun: "job queue", reload: load)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: name) { await load() }
    }

    private func toggle(_ enabled: Bool) async {
        isToggling = true
        actionError = nil
        do {
            detailState = .loaded(try await api.setBatchJobQueueEnabled(profile: appState.currentProfile, region: appState.currentRegion, name: name, enabled: enabled))
        } catch {
            actionError = error.friendlyMessage
        }
        isToggling = false
    }

    private func load() async {
        do {
            detailState = .loaded(try await api.getBatchJobQueue(profile: appState.currentProfile, region: appState.currentRegion, name: name))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

/// Jobs in a queue, one status at a time like the console's filter.
private struct BatchJobsTab: View {
    let queueName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    static let statuses = ["SUBMITTED", "PENDING", "RUNNABLE", "STARTING", "RUNNING", "SUCCEEDED", "FAILED"]

    @State private var status = "RUNNING"
    @State private var state: LoadState<[BatchJobSummary]> = .loading
    @State private var selectedJobId: String?
    @State private var openJobId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Status", selection: $status) {
                    ForEach(Self.statuses, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                RefreshButton(compactSize: 22, help: "Refresh") { Task { await load() } }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No \(status.lowercased()) jobs") { jobs in
                Table(jobs, selection: $selectedJobId) {
                    TableColumn("Job name") { j in Text(j.jobName).font(.caption.bold()) }
                    TableColumn("Job ID") { j in Text(j.jobId).font(.caption2.monospaced()) }
                    TableColumn("Status") { j in StatusBadge(j.status ?? "-") }
                        .width(min: 80, ideal: 100)
                    TableColumn("Created") { j in Text(Formatters.formatISODate(j.createdAt)).font(.caption) }
                    TableColumn("Exit code") { j in Text(j.exitCode.map(String.init) ?? "-").font(.caption.monospaced()) }
                        .width(60)
                    TableColumn("Job definition") { j in Text(j.jobDefinition ?? "-").font(.caption) }
                }
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                    openJobId = ids.first
                }
            }
            if selectedJobId != nil {
                HStack {
                    Text("Double-click a job, or").font(.caption).foregroundStyle(.secondary)
                    OpenButton("Open job") { openJobId = selectedJobId }
                        .controlSize(.small)
                    Spacer()
                }
                .padding(8)
            }
        }
        .task(id: "\(queueName)-\(status)") { await load() }
        .sheet(item: Binding(get: { openJobId.map(IdentifiedString.init) }, set: { openJobId = $0?.value })) { item in
            BatchJobDetailSheet(jobId: item.value, onChanged: { Task { await load() } })
        }
    }

    private func load() async {
        state = .loading
        do {
            let jobs = try await api.getBatchJobs(profile: appState.currentProfile, region: appState.currentRegion, queue: queueName, status: status)
            state = jobs.isEmpty ? .empty : .loaded(jobs)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

struct IdentifiedString: Identifiable {
    var id: String { value }
    let value: String
}

/// A job's page: overview, container, environment, with Terminate.
private struct BatchJobDetailSheet: View {
    let jobId: String
    let onChanged: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case container = "Container"
        case environment = "Environment"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .details
    @State private var state: LoadState<BatchJobDetail> = .loading
    @State private var isTerminating = false
    @State private var actionError: String?

    private static let finished: Set<String> = ["SUCCEEDED", "FAILED"]

    var body: some View {
        VStack(spacing: 0) {
            LoadableContent(state, retry: { Task { await load() } }) { job in
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeader(title: job.jobName, subtitle: job.jobId, status: job.status, tab: $tab)
                    DetailActionBar(error: actionError, onRefresh: { Task { await load() } }) {
                        ConfirmedActionButton(
                            title: "Terminate job",
                            systemImage: "xmark.octagon",
                            confirmationTitle: "Terminate \(job.jobName)?",
                            confirmationMessage: "Running jobs are stopped and pending jobs are cancelled. The job moves to FAILED.",
                            isLoading: isTerminating,
                            isDisabled: isTerminating || Self.finished.contains(job.status ?? "")
                        ) { Task { await terminate() } }
                    }
                    Group {
                        switch tab {
                        case .details:
                            DetailTabPage {
                                DetailGrid(items: [
                                    DetailItem("Status", job.status),
                                    DetailItem("Job queue", job.jobQueue),
                                    DetailItem("Job definition", job.jobDefinition),
                                    DetailItem("Attempts", "\(job.attempts)"),
                                    DetailItem("Exit code", job.exitCode.map(String.init)),
                                    DetailItem("Array size", job.arraySize.map(String.init)),
                                    DetailItem("Created", Formatters.formatISODate(job.createdAt), monospaced: false),
                                    DetailItem("Started", Formatters.formatISODate(job.startedAt), monospaced: false),
                                    DetailItem("Stopped", Formatters.formatISODate(job.stoppedAt), monospaced: false),
                                ])
                                DetailField("Status reason", job.statusReason ?? job.reason ?? "-", monospaced: false)
                                if !job.dependsOn.isEmpty {
                                    DetailChipsField("Depends on", job.dependsOn)
                                }
                                if let arn = job.jobArn {
                                    DetailSection(title: "ARN") { CopyableBlock(text: arn) }
                                }
                            }
                        case .container:
                            DetailTabPage {
                                DetailGrid(items: [
                                    DetailItem("Image", job.image),
                                    DetailItem("vCPUs", job.vcpus),
                                    DetailItem("Memory (MiB)", job.memory),
                                ])
                                DetailSection(title: "Command") {
                                    CopyableBlock(text: job.command.isEmpty ? "(image default)" : job.command.joined(separator: " "))
                                }
                                if let stream = job.logStreamName {
                                    DetailSection(title: "CloudWatch log stream (/aws/batch/job)") { CopyableBlock(text: stream) }
                                }
                            }
                        case .environment:
                            DetailTabPage {
                                if job.environment.isEmpty {
                                    Text("No environment variables.").font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(job.environment) { env in
                                    DetailField(env.key, env.value)
                                }
                            }
                        case .tags:
                            DetailTabPage {
                                if job.tags.isEmpty { Text("No tags.").font(.caption).foregroundStyle(.secondary) }
                                ForEach(job.tags) { tag in DetailField(tag.key, tag.value) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Spacer()
                SecondaryButton("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 520)
        .resizableSheet(minWidth: 720, minHeight: 520)
        .task(id: jobId) { await load() }
    }

    private func terminate() async {
        isTerminating = true
        actionError = nil
        do {
            state = .loaded(try await api.terminateBatchJob(profile: appState.currentProfile, region: appState.currentRegion, jobId: jobId, reason: "Terminated from AWS Visualizer"))
            onChanged()
        } catch {
            actionError = error.friendlyMessage
        }
        isTerminating = false
    }

    private func load() async {
        do {
            state = .loaded(try await api.getBatchJob(profile: appState.currentProfile, region: appState.currentRegion, jobId: jobId))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Compute environment

struct BatchComputeEnvironmentDetailView: View {
    let name: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case resources = "Compute resources"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .details
    @State private var detailState: LoadState<BatchComputeEnvironment> = .loading
    @State private var isToggling = false
    @State private var actionError: String?

    var body: some View {
        LoadableContent(detailState, retry: { Task { await load() } }) { ce in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(title: ce.computeEnvironmentName, subtitle: "Compute environment · \(ce.type ?? "-") · \(ce.resourceType ?? "-")", status: ce.state, tab: $tab)
                DetailActionBar(error: actionError, onRefresh: { Task { await load() } }) {
                    let enabled = ce.state == "ENABLED"
                    ConfirmedActionButton(
                        title: enabled ? "Disable" : "Enable",
                        systemImage: enabled ? "pause.circle" : "play.circle",
                        confirmationTitle: "\(enabled ? "Disable" : "Enable") \(ce.computeEnvironmentName)?",
                        confirmationMessage: enabled
                            ? "Queues stop placing new jobs here; running jobs finish, then managed instances scale down."
                            : "Queues can place jobs in this environment again.",
                        isLoading: isToggling,
                        isDisabled: isToggling,
                        role: enabled ? .destructive : nil
                    ) { Task { await toggle(!enabled) } }
                }
                Group {
                    switch tab {
                    case .details:
                        DetailTabPage {
                            DetailSection(title: "Compute environment overview") {
                                DetailGrid(items: [
                                    DetailItem("Type", ce.type),
                                    DetailItem("State", ce.state),
                                    DetailItem("Status", ce.status),
                                    DetailItem("Service role", ce.serviceRole.map(ComputeFormat.arnResourceName)),
                                    DetailItem("ECS cluster", ce.ecsClusterArn.map(ComputeFormat.arnResourceName)),
                                    DetailItem("EKS cluster", ce.eksClusterArn.map(ComputeFormat.arnResourceName)),
                                ])
                                DetailField("Status reason", ce.statusReason ?? "-", monospaced: false)
                            }
                            DetailSection(title: "ARN") { CopyableBlock(text: ce.computeEnvironmentArn) }
                        }
                    case .resources:
                        DetailTabPage {
                            if ce.resourceType == nil {
                                DetailNote("Unmanaged environment - you manage the ECS container instances yourself.")
                            } else {
                                HStack(spacing: 12) {
                                    MetricTile(title: "Minimum vCPUs", value: ComputeFormat.int(ce.minvCpus))
                                    MetricTile(title: "Desired vCPUs", value: ComputeFormat.int(ce.desiredvCpus))
                                    MetricTile(title: "Maximum vCPUs", value: ComputeFormat.int(ce.maxvCpus))
                                }
                                DetailGrid(items: [
                                    DetailItem("Provisioning model", ce.resourceType),
                                    DetailItem("Allocation strategy", ce.allocationStrategy),
                                    DetailItem("Instance role", ce.instanceRole.map(ComputeFormat.arnResourceName)),
                                    DetailItem("Launch template", ce.launchTemplate),
                                ])
                                DetailChipsField("Instance types", ce.instanceTypes)
                                DetailChipsField("Subnets", ce.subnets)
                                DetailChipsField("Security groups", ce.securityGroupIds)
                            }
                        }
                    case .tags:
                        BatchTagsTab(arn: ce.computeEnvironmentArn, tags: ce.tags, noun: "compute environment", reload: load)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: name) { await load() }
    }

    private func toggle(_ enabled: Bool) async {
        isToggling = true
        actionError = nil
        do {
            detailState = .loaded(try await api.setBatchComputeEnvironmentEnabled(profile: appState.currentProfile, region: appState.currentRegion, name: name, enabled: enabled))
        } catch {
            actionError = error.friendlyMessage
        }
        isToggling = false
    }

    private func load() async {
        do {
            detailState = .loaded(try await api.getBatchComputeEnvironment(profile: appState.currentProfile, region: appState.currentRegion, name: name))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Job definition

struct BatchJobDefinitionDetailView: View {
    let arn: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case json = "Properties JSON"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .details
    @State private var detailState: LoadState<BatchJobDefinition> = .loading

    var body: some View {
        LoadableContent(detailState, retry: { Task { await load() } }) { jd in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(title: "\(jd.jobDefinitionName):\(jd.revision)", subtitle: "Job definition · \(jd.type ?? "-")", status: jd.status, tab: $tab)
                Group {
                    switch tab {
                    case .details:
                        DetailTabPage {
                            DetailSection(title: "Overview") {
                                DetailGrid(items: [
                                    DetailItem("Revision", "\(jd.revision)"),
                                    DetailItem("Type", jd.type),
                                    DetailItem("Image", jd.image),
                                    DetailItem("vCPUs", jd.vcpus),
                                    DetailItem("Memory (MiB)", jd.memory),
                                    DetailItem("Timeout", ComputeFormat.seconds(jd.timeoutSeconds)),
                                    DetailItem("Retry attempts", ComputeFormat.int(jd.retryAttempts)),
                                    DetailItem("Propagate tags", ComputeFormat.bool(jd.propagateTags)),
                                ])
                                DetailChipsField("Platform capabilities", jd.platformCapabilities)
                            }
                            if !jd.parameters.isEmpty {
                                DetailSection(title: "Parameters") {
                                    ForEach(jd.parameters) { p in DetailField(p.key, p.value) }
                                }
                            }
                            DetailSection(title: "ARN") { CopyableBlock(text: jd.jobDefinitionArn) }
                        }
                    case .json:
                        if let json = jd.propertiesJson {
                            StructuredContentView(text: json, kind: .json)
                        } else {
                            EmptyStateView(message: "No container / node properties")
                        }
                    case .tags:
                        BatchTagsTab(arn: jd.jobDefinitionArn, tags: jd.tags, noun: "job definition", reload: load)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: arn) { await load() }
    }

    private func load() async {
        do {
            detailState = .loaded(try await api.getBatchJobDefinition(profile: appState.currentProfile, region: appState.currentRegion, arn: arn))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

private struct BatchTagsTab: View {
    let arn: String
    let tags: [ResourceTag]
    let noun: String
    let reload: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    var body: some View {
        ResourceTagsEditor(tags: tags, resourceNoun: noun, onAdd: { key, value in
            try await api.addBatchTag(profile: appState.currentProfile, region: appState.currentRegion, arn: arn, key: key, value: value)
            await reload()
        }, onRemove: { key in
            try await api.removeBatchTag(profile: appState.currentProfile, region: appState.currentRegion, arn: arn, key: key)
            await reload()
        })
    }
}
