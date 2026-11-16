import SwiftUI

/// Mirrors a stack's page in the CloudFormation console: Info (status,
/// termination protection, parameters, tags), Events (the deployment
/// timeline), Resources (physical resources managed by the stack),
/// Outputs, and the raw Template.
struct CloudFormationStackDetailView: View {
    let stackName: String
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    private enum DetailTab: String, CaseIterable {
        case info = "Info"
        case events = "Events"
        case resources = "Resources"
        case outputs = "Outputs"
        case template = "Template"
    }

    @State private var tab: DetailTab = .info
    @State private var detailState: LoadState<CloudFormationStackDetail> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeader(title: detail.stackName, status: detail.status, tab: $tab)

                    Group {
                        switch tab {
                        case .info:
                            CloudFormationInfoView(detail: detail, onUpdated: { detailState = .loaded($0) }, onDeleted: onDeleted)
                        case .events:
                            CloudFormationEventsView(stackName: stackName)
                        case .resources:
                            CloudFormationResourcesView(stackName: stackName)
                        case .outputs:
                            CloudFormationOutputsView(outputs: detail.outputs)
                        case .template:
                            CloudFormationTemplateView(stackName: stackName)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: stackName) {
            await loadDetail()
        }
    }

    private func loadDetail() async {
        detailState = .loading
        do {
            let detail = try await api.getStackDetail(profile: appState.currentProfile, region: appState.currentRegion, name: stackName)
            detailState = .loaded(detail)
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

private struct CloudFormationInfoView: View {
    let detail: CloudFormationStackDetail
    var onUpdated: (CloudFormationStackDetail) -> Void
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var isTogglingProtection = false
    @State private var toggleError: String?
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let statusReason = detail.statusReason, !statusReason.isEmpty {
                    Text(statusReason)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let description = detail.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Stack settings")
                        .font(.headline)

                    Toggle("Termination protection", isOn: Binding(
                        get: { detail.enableTerminationProtection },
                        set: { newValue in Task { await setProtection(newValue) } }
                    ))
                    .disabled(isTogglingProtection)

                    if let toggleError {
                        Text(toggleError).font(.caption).foregroundStyle(.red)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Details")
                        .font(.headline)
                    DetailField("Stack ID", detail.stackId)
                    if let roleArn = detail.roleArn { DetailField("Role ARN", roleArn) }
                    if let drift = detail.driftStatus { DetailField("Drift status", drift) }
                    if let created = detail.creationTime { DetailField("Created", Formatters.formatDate(created)) }
                    if let updated = detail.lastUpdatedTime { DetailField("Last updated", Formatters.formatDate(updated)) }
                }

                if !detail.parameters.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Parameters")
                            .font(.headline)
                        ForEach(detail.parameters) { param in
                            HStack {
                                Text(param.key)
                                    .font(.caption.monospaced().bold())
                                Spacer()
                                Text(param.value ?? "-")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if !detail.tags.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags")
                            .font(.headline)
                        ForEach(detail.tags) { tag in
                            HStack {
                                Text(tag.key)
                                    .font(.caption.monospaced().bold())
                                Spacer()
                                Text(tag.value)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Danger zone")
                        .font(.headline)
                        .foregroundStyle(.red)
                    DeleteButton("Delete Stack", isLoading: isDeleting, isDisabled: detail.enableTerminationProtection) {
                        Task { await deleteStack() }
                    }
                    if detail.enableTerminationProtection {
                        Text("Turn off termination protection to delete this stack.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let deleteError {
                        Text(deleteError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }


    private func setProtection(_ enabled: Bool) async {
        isTogglingProtection = true
        toggleError = nil
        do {
            let updated = try await api.setStackTerminationProtection(profile: appState.currentProfile, region: appState.currentRegion, name: detail.stackName, enabled: enabled)
            onUpdated(updated)
        } catch {
            toggleError = error.friendlyMessage
        }
        isTogglingProtection = false
    }

    private func deleteStack() async {
        isDeleting = true
        deleteError = nil
        do {
            try await api.deleteStack(profile: appState.currentProfile, region: appState.currentRegion, name: detail.stackName)
            onDeleted()
        } catch {
            deleteError = error.friendlyMessage
        }
        isDeleting = false
    }
}

private struct CloudFormationEventsView: View {
    let stackName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var eventsState: LoadState<[CloudFormationStackEvent]> = .loading

    var body: some View {
        LoadableContent(eventsState, retry: { Task { await load() } }, emptyMessage: "No events") { events in
            Table(events) {
                TableColumn("Time") { e in
                    Text(Formatters.formatDate(e.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .width(min: 130, ideal: 160)

                TableColumn("Logical ID") { e in
                    Text(e.logicalResourceId ?? "-")
                        .font(.caption.monospaced())
                }
                .width(min: 120, ideal: 180)

                TableColumn("Type") { e in
                    Text(e.resourceType ?? "-")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
                .width(min: 140, ideal: 220)

                TableColumn("Status") { e in
                    StatusBadge(e.resourceStatus ?? "-")
                }
                .width(min: 110, ideal: 160)

                TableColumn("Reason") { e in
                    Text(e.resourceStatusReason ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(e.resourceStatusReason ?? "")
                }
                .width(min: 140, ideal: 260)
            }
        }
        .task { await load() }
    }

    private func load() async {
        eventsState = .loading
        do {
            let events = try await api.getStackEvents(profile: appState.currentProfile, region: appState.currentRegion, name: stackName)
            eventsState = events.isEmpty ? .empty : .loaded(events)
        } catch {
            eventsState = .failed(error.friendlyMessage)
        }
    }
}

private struct CloudFormationResourcesView: View {
    let stackName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var resourcesState: LoadState<[CloudFormationStackResource]> = .loading

    var body: some View {
        LoadableContent(resourcesState, retry: { Task { await load() } }, emptyMessage: "No resources") { resources in
            Table(resources) {
                TableColumn("Logical ID") { r in
                    Text(r.logicalResourceId)
                        .font(.caption.monospaced().bold())
                }
                .width(min: 140, ideal: 200)

                TableColumn("Type") { r in
                    Text(r.resourceType)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
                .width(min: 160, ideal: 240)

                TableColumn("Physical ID") { r in
                    Text(r.physicalResourceId ?? "-")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 160, ideal: 260)

                TableColumn("Status") { r in
                    StatusBadge(r.resourceStatus)
                }
                .width(min: 110, ideal: 160)
            }
        }
        .task { await load() }
    }

    private func load() async {
        resourcesState = .loading
        do {
            let resources = try await api.getStackResources(profile: appState.currentProfile, region: appState.currentRegion, name: stackName)
            resourcesState = resources.isEmpty ? .empty : .loaded(resources)
        } catch {
            resourcesState = .failed(error.friendlyMessage)
        }
    }
}

private struct CloudFormationOutputsView: View {
    let outputs: [CloudFormationOutput]

    var body: some View {
        if outputs.isEmpty {
            EmptyStateView(message: "No outputs")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(outputs) { output in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(output.key)
                                .font(.body.bold().monospaced())
                            Text(output.value ?? "-")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let description = output.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            if let exportName = output.exportName, !exportName.isEmpty {
                                Text("Exported as \(exportName)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.bottom, 8)
                        Divider()
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct CloudFormationTemplateView: View {
    let stackName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var templateState: LoadState<String> = .loading

    var body: some View {
        LoadableContent(templateState, retry: { Task { await load() } }) { template in
            StructuredContentView(text: template, kind: template.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") ? .json : .plain)
        }
        .task { await load() }
    }

    private func load() async {
        templateState = .loading
        do {
            let template = try await api.getStackTemplate(profile: appState.currentProfile, region: appState.currentRegion, name: stackName)
            templateState = .loaded(template)
        } catch {
            templateState = .failed(error.friendlyMessage)
        }
    }
}
