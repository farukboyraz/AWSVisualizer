import SwiftUI

/// Mirrors a REST API's page in the API Gateway console: Resources (the
/// path/method tree, with delete), Stages (deploy + manage), and Settings
/// (name/description, delete API).
struct ApiGatewayDetailView: View {
    let api: RestApi
    var onDeleted: () -> Void

    private enum DetailTab: String, CaseIterable {
        case resources = "Resources"
        case stages = "Stages"
        case settings = "Settings"
    }

    @State private var tab: DetailTab = .resources
    @State private var currentApi: RestApi

    init(api: RestApi, onDeleted: @escaping () -> Void) {
        self.api = api
        self.onDeleted = onDeleted
        _currentApi = State(initialValue: api)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(title: currentApi.name, subtitle: "REST API · \(currentApi.id)", tab: $tab)

            Group {
                switch tab {
                case .resources:
                    ApiGatewayResourcesView(apiId: currentApi.id)
                case .stages:
                    ApiGatewayStagesView(apiId: currentApi.id)
                case .settings:
                    ApiGatewaySettingsView(api: currentApi, onUpdated: { currentApi = $0 }, onDeleted: onDeleted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ApiGatewayResourcesView: View {
    let apiId: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var resourcesState: LoadState<[ApiGatewayResource]> = .loading
    @State private var deletingResourceId: String?
    @State private var deletingMethodKey: String?
    @State private var actionError: String?

    var body: some View {
        LoadableContent(resourcesState, retry: { Task { await load() } }, emptyMessage: "No resources") { resources in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let actionError {
                        Text(actionError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    ForEach(resources) { resource in
                        resourceRow(resource)
                    }
                }
                .padding()
            }
        }
        .task { await load() }
    }

    private func resourceRow(_ resource: ApiGatewayResource) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(resource.methods) { method in
                    HStack {
                        methodBadge(method.httpMethod)
                        Text(method.integrationType ?? "-")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if let uri = method.integrationUri {
                            Text(uri)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        DeleteButton(compactSize: 20, isLoading: deletingMethodKey == "\(resource.id)-\(method.httpMethod)", help: "Delete Method") {
                            Task { await deleteMethod(resource, method) }
                        }
                    }
                }
                if resource.path != "/" {
                    DeleteButton("Delete Resource", isLoading: deletingResourceId == resource.id) {
                        Task { await deleteResource(resource) }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.leading, 8)
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Text(resource.path)
                    .font(.body.monospaced())
                ForEach(resource.methods) { method in
                    methodBadge(method.httpMethod)
                }
            }
        }
    }

    private func methodBadge(_ method: String) -> some View {
        Text(method)
            .font(.caption2.bold().monospaced())
            .foregroundStyle(methodColor(method))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(methodColor(method).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "PUT", "PATCH": return .orange
        case "DELETE": return .red
        default: return .secondary
        }
    }

    private func load() async {
        resourcesState = .loading
        do {
            let resources = try await api.getApiGatewayResources(profile: appState.currentProfile, region: appState.currentRegion, apiId: apiId)
            resourcesState = resources.isEmpty ? .empty : .loaded(resources)
        } catch {
            resourcesState = .failed(error.friendlyMessage)
        }
    }

    private func deleteResource(_ resource: ApiGatewayResource) async {
        deletingResourceId = resource.id
        actionError = nil
        do {
            try await api.deleteApiGatewayResource(profile: appState.currentProfile, region: appState.currentRegion, apiId: apiId, resourceId: resource.id)
            await load()
        } catch {
            actionError = error.friendlyMessage
        }
        deletingResourceId = nil
    }

    private func deleteMethod(_ resource: ApiGatewayResource, _ method: ApiGatewayMethod) async {
        deletingMethodKey = "\(resource.id)-\(method.httpMethod)"
        actionError = nil
        do {
            try await api.deleteApiGatewayMethod(profile: appState.currentProfile, region: appState.currentRegion, apiId: apiId, resourceId: resource.id, httpMethod: method.httpMethod)
            await load()
        } catch {
            actionError = error.friendlyMessage
        }
        deletingMethodKey = nil
    }
}

private struct ApiGatewayStagesView: View {
    let apiId: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var stagesState: LoadState<[ApiGatewayStage]> = .loading
    @State private var newStageName = ""
    @State private var deployDescription = ""
    @State private var isDeploying = false
    @State private var deployError: String?
    @State private var deletingStage: String?
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                deploySection
                Divider()
                if let actionError {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                LoadableContent(stagesState, retry: { Task { await load() } }, emptyMessage: "No stages yet") { stages in
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(stages) { stage in
                            stageRow(stage)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await load() }
    }

    private var deploySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Deploy API")
                .font(.headline)
            HStack(spacing: 12) {
                TextField("Stage name (e.g. prod)", text: $newStageName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                TextField("Description (optional)", text: $deployDescription)
                    .textFieldStyle(.roundedBorder)
                NewButton("Deploy", isLoading: isDeploying, isDisabled: newStageName.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await deploy() }
                }
            }
            if let deployError {
                Text(deployError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func stageRow(_ stage: ApiGatewayStage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(stage.stageName)
                    .font(.body.bold())
                Spacer()
                DeleteButton(compactSize: 20, isLoading: deletingStage == stage.stageName, isDisabled: deletingStage != nil, help: "Delete Stage") {
                    Task { await deleteStage(stage) }
                }
            }
            Text(invokeURL(for: stage))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let description = stage.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.tertiary)
            }
            if !stage.variables.isEmpty {
                Text(stage.variables.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            if let updated = stage.lastUpdatedDate {
                Text("Updated \(Formatters.formatDate(updated))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func invokeURL(for stage: ApiGatewayStage) -> String {
        "https://\(apiId).execute-api.\(appState.currentRegion).amazonaws.com/\(stage.stageName)"
    }

    private func load() async {
        stagesState = .loading
        do {
            let stages = try await api.getApiGatewayStages(profile: appState.currentProfile, region: appState.currentRegion, apiId: apiId)
            stagesState = stages.isEmpty ? .empty : .loaded(stages)
        } catch {
            stagesState = .failed(error.friendlyMessage)
        }
    }

    private func deploy() async {
        isDeploying = true
        deployError = nil
        do {
            let stages = try await api.deployApiGateway(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                apiId: apiId,
                stageName: newStageName.trimmingCharacters(in: .whitespaces),
                description: deployDescription.isEmpty ? nil : deployDescription
            )
            stagesState = stages.isEmpty ? .empty : .loaded(stages)
            newStageName = ""
            deployDescription = ""
        } catch {
            deployError = error.friendlyMessage
        }
        isDeploying = false
    }

    private func deleteStage(_ stage: ApiGatewayStage) async {
        deletingStage = stage.stageName
        actionError = nil
        do {
            try await api.deleteApiGatewayStage(profile: appState.currentProfile, region: appState.currentRegion, apiId: apiId, stageName: stage.stageName)
            await load()
        } catch {
            actionError = error.friendlyMessage
        }
        deletingStage = nil
    }
}

private struct ApiGatewaySettingsView: View {
    let api: RestApi
    var onUpdated: (RestApi) -> Void
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var apiService

    @State private var nameField = ""
    @State private var descriptionField = ""
    @State private var isSavingName = false
    @State private var isSavingDescription = false
    @State private var nameError: String?
    @State private var descriptionError: String?
    @State private var nameSaved = false
    @State private var descriptionSaved = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("General")
                        .font(.headline)
                    SettingsFieldRow(label: "Name", isSaving: isSavingName, error: nameError, saved: nameSaved, save: { Task { await saveName() } }) {
                        TextField("Name", text: $nameField)
                            .textFieldStyle(.roundedBorder)
                    }
                    SettingsFieldRow(label: "Description", isSaving: isSavingDescription, error: descriptionError, saved: descriptionSaved, save: { Task { await saveDescription() } }) {
                        TextField("Description", text: $descriptionField)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Details")
                        .font(.headline)
                    DetailField("API ID", api.id)
                    if let endpointType = api.endpointType { DetailField("Endpoint type", endpointType) }
                    if let created = api.createdDate { DetailField("Created", Formatters.formatDate(created)) }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Danger zone")
                        .font(.headline)
                        .foregroundStyle(.red)
                    DeleteButton("Delete API", isLoading: isDeleting) {
                        Task { await deleteApi() }
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
        .task(id: api.id) {
            nameField = api.name
            descriptionField = api.description ?? ""
        }
    }


    private func saveName() async {
        let trimmed = nameField.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSavingName = true
        nameError = nil
        nameSaved = false
        do {
            let updated = try await apiService.updateRestApi(profile: appState.currentProfile, region: appState.currentRegion, apiId: api.id, name: trimmed, description: nil)
            onUpdated(updated)
            nameSaved = true
        } catch {
            nameError = error.friendlyMessage
        }
        isSavingName = false
    }

    private func saveDescription() async {
        isSavingDescription = true
        descriptionError = nil
        descriptionSaved = false
        do {
            let updated = try await apiService.updateRestApi(profile: appState.currentProfile, region: appState.currentRegion, apiId: api.id, name: nil, description: descriptionField)
            onUpdated(updated)
            descriptionSaved = true
        } catch {
            descriptionError = error.friendlyMessage
        }
        isSavingDescription = false
    }

    private func deleteApi() async {
        isDeleting = true
        deleteError = nil
        do {
            try await apiService.deleteRestApi(profile: appState.currentProfile, region: appState.currentRegion, apiId: api.id)
            onDeleted()
        } catch {
            deleteError = error.friendlyMessage
        }
        isDeleting = false
    }
}
