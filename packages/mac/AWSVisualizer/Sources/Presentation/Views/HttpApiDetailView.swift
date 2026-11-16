import SwiftUI

/// An HTTP or WebSocket API (API Gateway v2), laid out like the console's
/// HTTP API page: API details, then Develop (Routes, Integrations,
/// Authorization, CORS) and Deploy (Stages), plus Tags. Deploy and Delete
/// sit in the action bar. Built from the shared detail components.
struct HttpApiDetailView: View {
    let apiId: String
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case routes = "Routes"
        case integrations = "Integrations"
        case authorization = "Authorization"
        case cors = "CORS"
        case stages = "Stages"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .details
    @State private var detailState: LoadState<HttpApiDetail> = .loading
    @State private var pendingAction: String?
    @State private var actionError: String?
    @State private var actionNote: String?

    var body: some View {
        LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(
                    title: detail.name,
                    subtitle: "\(detail.isWebSocket ? "WebSocket" : "HTTP") API · \(detail.apiId)",
                    tab: $tab
                )
                actionBar(detail)

                Group {
                    switch tab {
                    case .details:
                        HttpApiDetailsTab(detail: detail)
                    case .routes:
                        HttpApiRoutesTab(detail: detail)
                    case .integrations:
                        HttpApiIntegrationsTab(detail: detail)
                    case .authorization:
                        HttpApiAuthorizationTab(detail: detail)
                    case .cors:
                        HttpApiCorsTab(detail: detail)
                    case .stages:
                        HttpApiStagesTab(stages: detail.stages)
                    case .tags:
                        ResourceTagsEditor(tags: detail.tags, resourceNoun: "API", onAdd: { key, value in
                            detailState = .loaded(try await api.addHttpApiTag(profile: appState.currentProfile, region: appState.currentRegion, apiId: apiId, key: key, value: value))
                        }, onRemove: { key in
                            detailState = .loaded(try await api.removeHttpApiTag(profile: appState.currentProfile, region: appState.currentRegion, apiId: apiId, key: key))
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: apiId) {
            await loadDetail()
        }
    }

    /// "Deploy" only matters for stages without auto-deploy - auto-deploy
    /// stages pick up every change on their own.
    private func actionBar(_ detail: HttpApiDetail) -> some View {
        let manualStages = detail.stages.filter { !$0.autoDeploy }
        return DetailActionBar(
            error: actionError,
            note: actionNote ?? (detail.stages.isEmpty ? "No stages yet - the API isn't callable until it has one." : (manualStages.isEmpty ? "All stages auto-deploy - changes go live automatically." : nil)),
            onRefresh: { Task { await loadDetail() } }
        ) {
            if !manualStages.isEmpty {
                Menu {
                    ForEach(manualStages) { stage in
                        Button("Deploy to \(stage.stageName)") {
                            Task { await deploy(stage.stageName) }
                        }
                    }
                } label: {
                    Label(pendingAction == "deploy" ? "Deploying..." : "Deploy", systemImage: "arrow.up.circle")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .disabled(pendingAction != nil)
            }
            DeleteButton("Delete API", isLoading: pendingAction == "delete", isDisabled: pendingAction != nil) {
                Task { await deleteApi() }
            }
        }
    }

    private func deploy(_ stageName: String) async {
        pendingAction = "deploy"
        actionError = nil
        actionNote = nil
        do {
            detailState = .loaded(try await api.deployHttpApi(profile: appState.currentProfile, region: appState.currentRegion, apiId: apiId, stageName: stageName, description: "Deployed from AWS Visualizer"))
            actionNote = "Deployed to \(stageName)."
        } catch {
            actionError = error.friendlyMessage
        }
        pendingAction = nil
    }

    private func deleteApi() async {
        pendingAction = "delete"
        actionError = nil
        do {
            try await api.deleteHttpApi(profile: appState.currentProfile, region: appState.currentRegion, apiId: apiId)
            onDeleted()
        } catch {
            actionError = error.friendlyMessage
        }
        pendingAction = nil
    }

    private func loadDetail() async {
        do {
            detailState = .loaded(try await api.getHttpApiDetail(profile: appState.currentProfile, region: appState.currentRegion, apiId: apiId))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

private struct HttpApiDetailsTab: View {
    let detail: HttpApiDetail

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            if let endpoint = detail.apiEndpoint {
                DetailSection(title: detail.disableExecuteApiEndpoint ? "Default endpoint (disabled)" : "Default endpoint", spacing: 6) {
                    CopyableBlock(text: endpoint)
                    if detail.disableExecuteApiEndpoint {
                        Text("The execute-api endpoint is turned off - clients must use a custom domain name.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            DetailSection(title: "API details", spacing: 12) {
                DetailGrid(items: [
                    DetailItem("API ID", detail.apiId),
                    DetailItem("Protocol", detail.isWebSocket ? "WebSocket" : "HTTP", monospaced: false),
                    DetailItem("Description", detail.description?.isEmpty == false ? detail.description : nil, monospaced: false),
                    DetailItem("Created", Formatters.formatISODate(detail.createdDate), monospaced: false),
                    DetailItem("Version", detail.version),
                    DetailItem("ARN", detail.arn),
                ] + (detail.isWebSocket ? [
                    DetailItem("Route selection expression", detail.routeSelectionExpression),
                    DetailItem("API key selection expression", detail.apiKeySelectionExpression),
                ] : []))
            }
            DetailSection(title: "Summary", spacing: 8) {
                HStack(spacing: 10) {
                    MetricTile(title: "Routes", value: "\(detail.routes.count)")
                    MetricTile(title: "Integrations", value: "\(detail.integrations.count)")
                    MetricTile(title: "Authorizers", value: "\(detail.authorizers.count)")
                    MetricTile(title: "Stages", value: "\(detail.stages.count)")
                }
            }
            if !detail.stages.isEmpty {
                DetailSection(title: "Invoke URLs", spacing: 6) {
                    ForEach(detail.stages.filter { $0.invokeUrl != nil }) { stage in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stage.stageName).font(.caption2).foregroundStyle(.tertiary)
                            CopyableBlock(text: stage.invokeUrl ?? "")
                        }
                    }
                }
            }
        }
    }
}

/// Colored HTTP method label, same palette everywhere routes are listed.
struct HttpMethodBadge: View {
    let method: String

    private var color: Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "PUT": return .orange
        case "PATCH": return .teal
        case "DELETE": return .red
        case "ANY": return .purple
        default: return .secondary
        }
    }

    var body: some View {
        Text(method)
            .font(.caption2.monospaced().bold())
            .foregroundStyle(color)
            .frame(minWidth: 54)
            .padding(.vertical, 2)
            .background(color.opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct HttpApiRoutesTab: View {
    let detail: HttpApiDetail
    @State private var selectedRouteId: String?

    private var integrationsById: [String: HttpApiIntegration] {
        Dictionary(uniqueKeysWithValues: detail.integrations.map { ($0.integrationId, $0) })
    }
    private var authorizersById: [String: HttpApiAuthorizer] {
        Dictionary(uniqueKeysWithValues: detail.authorizers.map { ($0.authorizerId, $0) })
    }

    var body: some View {
        if detail.routes.isEmpty {
            EmptyStateView(message: "No routes - requests to this API return 404.")
        } else {
            VStack(spacing: 0) {
                Table(detail.routes, selection: $selectedRouteId) {
                    TableColumn("Method") { route in
                        HttpMethodBadge(method: route.method ?? (detail.isWebSocket ? "WS" : "-"))
                    }
                    .width(min: 60, ideal: 70, max: 90)
                    TableColumn("Route") { route in
                        Text(route.path).font(.body.monospaced())
                    }
                    .width(min: 160, ideal: 280)
                    TableColumn("Authorization") { route in
                        Text(authorizationLabel(route)).font(.caption)
                            .foregroundStyle(route.authorizationType == nil || route.authorizationType == "NONE" ? .secondary : .primary)
                    }
                    .width(min: 100, ideal: 160)
                    TableColumn("Integration") { route in
                        Text(integrationLabel(route)).font(.caption.monospaced())
                            .foregroundStyle(route.integrationId == nil ? .orange : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 140, ideal: 320)
                }
                if let route = detail.routes.first(where: { $0.id == selectedRouteId }) {
                    Divider()
                    routeDetail(route)
                }
            }
        }
    }

    private func routeDetail(_ route: HttpApiRoute) -> some View {
        let integration = route.integrationId.flatMap { integrationsById[$0] }
        return DetailGrid(items: [
            DetailItem("Route key", route.routeKey),
            DetailItem("Route ID", route.routeId),
            DetailItem("Authorization", authorizationLabel(route), monospaced: false),
            DetailItem("Scopes", route.authorizationScopes.isEmpty ? nil : route.authorizationScopes.joined(separator: ", ")),
            DetailItem("Integration type", integration?.integrationType),
            DetailItem("Integration target", integration?.target),
        ] + (detail.isWebSocket ? [DetailItem("API key required", route.apiKeyRequired == true ? "Yes" : "No", monospaced: false)] : []))
        .padding()
    }

    private func authorizationLabel(_ route: HttpApiRoute) -> String {
        guard let type = route.authorizationType, type != "NONE" else { return "None" }
        if let id = route.authorizerId, let authorizer = authorizersById[id] {
            return "\(authorizer.name) (\(type == "CUSTOM" ? "Lambda" : type))"
        }
        return type == "AWS_IAM" ? "IAM" : type
    }

    private func integrationLabel(_ route: HttpApiRoute) -> String {
        guard let id = route.integrationId else { return "No integration attached" }
        guard let integration = integrationsById[id] else { return id }
        return integration.target.map(HttpApiIntegrationsTab.shortTarget) ?? integration.integrationType
    }
}

private struct HttpApiIntegrationsTab: View {
    let detail: HttpApiDetail

    var body: some View {
        if detail.integrations.isEmpty {
            EmptyStateView(message: "No integrations")
        } else {
            Table(detail.integrations) {
                TableColumn("Type") { i in
                    Text(Self.typeName(i.integrationType)).font(.caption)
                }
                .width(min: 100, ideal: 140)
                TableColumn("Target") { i in
                    Text(i.target.map(Self.shortTarget) ?? "-").font(.caption.monospaced())
                        .help(i.target ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 180, ideal: 340)
                TableColumn("Method") { i in
                    Text(i.integrationMethod ?? "-").font(.caption.monospaced())
                }
                .width(min: 60, ideal: 70)
                TableColumn("Payload") { i in
                    Text(i.payloadFormatVersion ?? "-").font(.caption)
                }
                .width(min: 50, ideal: 60)
                TableColumn("Timeout") { i in
                    Text(i.timeoutInMillis.map { "\($0 / 1000) s" } ?? "-").font(.caption)
                }
                .width(min: 50, ideal: 60)
                TableColumn("Connection") { i in
                    Text(i.connectionType == "VPC_LINK" ? "VPC link" : "Internet").font(.caption)
                }
                .width(min: 70, ideal: 80)
                TableColumn("ID") { i in
                    Text(i.integrationId).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)
            }
        }
    }

    static func typeName(_ raw: String) -> String {
        switch raw {
        case "AWS_PROXY": return "Lambda / AWS proxy"
        case "HTTP_PROXY": return "HTTP proxy"
        case "MOCK": return "Mock"
        case "AWS": return "AWS service"
        case "HTTP": return "HTTP"
        default: return raw
        }
    }

    /// Lambda invoke URIs are long; show "function:name" when possible.
    static func shortTarget(_ target: String) -> String {
        if let range = target.range(of: ":function:") {
            let rest = target[range.upperBound...]
            let name = rest.split(separator: "/").first.map(String.init) ?? String(rest)
            return "λ \(name)"
        }
        return target
    }
}

private struct HttpApiAuthorizationTab: View {
    let detail: HttpApiDetail

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            if detail.authorizers.isEmpty {
                DetailSection(title: "Authorizers", spacing: 6) {
                    Text("No authorizers. Routes are open unless they use IAM authorization.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(detail.authorizers) { authorizer in
                    let routes = detail.routes.filter { $0.authorizerId == authorizer.authorizerId }
                    DetailSection(title: "\(authorizer.name) · \(authorizer.authorizerType == "JWT" ? "JWT" : "Lambda")", spacing: 10) {
                        DetailGrid(items: authorizer.authorizerType == "JWT" ? [
                            DetailItem("Issuer", authorizer.issuer),
                            DetailItem("Audience", authorizer.audience.joined(separator: ", ")),
                            DetailItem("Identity source", authorizer.identitySource.joined(separator: ", ")),
                            DetailItem("Authorizer ID", authorizer.authorizerId),
                        ] : [
                            DetailItem("Lambda function", authorizer.authorizerUri.map(HttpApiIntegrationsTab.shortTarget)),
                            DetailItem("Payload format", authorizer.payloadFormatVersion),
                            DetailItem("Simple responses", authorizer.enableSimpleResponses.map { $0 ? "Enabled" : "Disabled" }, monospaced: false),
                            DetailItem("Result cache TTL", authorizer.resultTtlInSeconds.map { "\($0) s" }),
                            DetailItem("Identity source", authorizer.identitySource.joined(separator: ", ")),
                            DetailItem("Authorizer ID", authorizer.authorizerId),
                        ])
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Attached routes (\(routes.count))").font(.caption2).foregroundStyle(.tertiary)
                            ForEach(routes) { route in
                                HStack(spacing: 6) {
                                    HttpMethodBadge(method: route.method ?? "WS")
                                    Text(route.path).font(.caption.monospaced())
                                }
                            }
                        }
                    }
                }
            }
            let iamRoutes = detail.routes.filter { $0.authorizationType == "AWS_IAM" }
            if !iamRoutes.isEmpty {
                DetailSection(title: "IAM authorization", spacing: 4) {
                    ForEach(iamRoutes) { route in
                        HStack(spacing: 6) {
                            HttpMethodBadge(method: route.method ?? "WS")
                            Text(route.path).font(.caption.monospaced())
                        }
                    }
                }
            }
        }
    }
}

private struct HttpApiCorsTab: View {
    let detail: HttpApiDetail

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            if detail.isWebSocket {
                Text("CORS doesn't apply to WebSocket APIs.").font(.caption).foregroundStyle(.secondary)
            } else if let cors = detail.cors {
                DetailSection(title: "Cross-origin resource sharing (CORS)", spacing: 12) {
                    DetailGrid(items: [
                        DetailItem("Access-Control-Allow-Origin", list(cors.allowOrigins)),
                        DetailItem("Access-Control-Allow-Methods", list(cors.allowMethods)),
                        DetailItem("Access-Control-Allow-Headers", list(cors.allowHeaders)),
                        DetailItem("Access-Control-Expose-Headers", list(cors.exposeHeaders)),
                        DetailItem("Access-Control-Allow-Credentials", cors.allowCredentials ? "Yes" : "No", monospaced: false),
                        DetailItem("Access-Control-Max-Age", cors.maxAge.map { "\($0) s" }),
                    ], minColumnWidth: 260)
                    if cors.allowCredentials && cors.allowOrigins.contains("*") {
                        Label("Browsers reject credentialed requests when the allowed origin is \"*\".", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                DetailSection(title: "Cross-origin resource sharing (CORS)", spacing: 6) {
                    Text("CORS isn't configured - API Gateway won't answer preflight requests; the integration has to send CORS headers itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func list(_ values: [String]) -> String {
        values.isEmpty ? "-" : values.joined(separator: ", ")
    }
}

private struct HttpApiStagesTab: View {
    let stages: [HttpApiStage]

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            if stages.isEmpty {
                Text("No stages.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(stages) { stage in
                DetailSection(title: stage.stageName, spacing: 10) {
                    if let url = stage.invokeUrl {
                        CopyableBlock(text: url)
                    }
                    DetailGrid(items: [
                        DetailItem("Automatic deployment", stage.autoDeploy ? "Enabled" : "Disabled", monospaced: false),
                        DetailItem("Deployment ID", stage.deploymentId),
                        DetailItem("Last updated", Formatters.formatISODate(stage.lastUpdatedDate), monospaced: false),
                        DetailItem("Throttling (rate / burst)", throttling(stage)),
                        DetailItem("Detailed metrics", stage.detailedMetricsEnabled.map { $0 ? "Enabled" : "Disabled" }, monospaced: false),
                        DetailItem("Access logging", stage.accessLogDestination ?? "Off"),
                        DetailItem("Description", stage.description, monospaced: false),
                    ])
                    if let message = stage.lastDeploymentStatusMessage, !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if !stage.stageVariables.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stage variables").font(.caption2).foregroundStyle(.tertiary)
                            ForEach(stage.stageVariables) { variable in
                                HStack {
                                    Text(variable.key).font(.caption.monospaced().bold())
                                    Text(variable.value).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                Divider()
            }
        }
    }

    private func throttling(_ stage: HttpApiStage) -> String? {
        guard stage.throttlingRateLimit != nil || stage.throttlingBurstLimit != nil else { return nil }
        let rate = stage.throttlingRateLimit.map { String(format: "%.0f", $0) } ?? "-"
        let burst = stage.throttlingBurstLimit.map(String.init) ?? "-"
        return "\(rate) / \(burst)"
    }
}
