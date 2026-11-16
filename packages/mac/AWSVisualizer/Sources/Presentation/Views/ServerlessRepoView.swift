import SwiftUI

/// Serverless Application Repository - the applications this account
/// published ("My applications" in the console), read-only.
struct ServerlessRepoView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[SarApplication]> = .loading
    @State private var selectedId: String?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 320, minWidth: 240, maxWidth: 500, isDetailActive: selectedId != nil, onBack: { selectedId = nil }, backTitle: "Applications", detailTitle: selectedName) {
                listPanel
            } detail: {
                if let selectedId {
                    SarApplicationDetailView(applicationId: selectedId).id(selectedId)
                } else {
                    EmptyStateView(message: "Select an application")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private var selectedName: String? {
        guard case .loaded(let apps) = state else { return nil }
        return apps.first { $0.applicationId == selectedId }?.name
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Serverless Application Repository")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "This account hasn't published applications in this region") { unfilteredApps in
                let apps = unfilteredApps.matching(filter)
                List(apps, selection: $selectedId) { app in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.body.bold()).lineLimit(1)
                        Text(app.description ?? app.author ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                    .tag(app.applicationId)
                }
                .listStyle(.sidebar)
            }
            PanelActionBar {
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
            }
        }
    }

    private func loadData() async {
        state = .loading
        do {
            let apps = try await api.getSarApplications(profile: appState.currentProfile, region: appState.currentRegion)
            state = apps.isEmpty ? .empty : .loaded(apps)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

/// An application's page: Details, Parameters (of the latest version),
/// Versions, Sharing (application policy).
struct SarApplicationDetailView: View {
    let applicationId: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case parameters = "Parameters"
        case versions = "Versions"
        case sharing = "Sharing"
    }

    @State private var tab: DetailTab = .details
    @State private var state: LoadState<SarApplicationDetail> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { app in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(
                    title: app.name,
                    subtitle: [app.author.map { "by \($0)" }, app.semanticVersion.map { "v\($0)" }].compactMap { $0 }.joined(separator: " · "),
                    status: app.policy.contains { $0.principals.contains("*") } ? "Public" : "Private",
                    tab: $tab
                )
                Group {
                    switch tab {
                    case .details: details(app)
                    case .parameters: parameters(app)
                    case .versions: versions(app)
                    case .sharing: sharing(app)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: applicationId) { await load() }
    }

    private func details(_ app: SarApplicationDetail) -> some View {
        DetailTabPage {
            if let description = app.description {
                Text(description).font(.body).textSelection(.enabled)
            }
            DetailGrid(items: [
                DetailItem("Author", app.author, monospaced: false),
                DetailItem("Verified author", ComputeFormat.bool(app.isVerifiedAuthor)),
                DetailItem("Latest version", app.semanticVersion),
                DetailItem("License", app.spdxLicenseId),
                DetailItem("Created", Formatters.formatISODate(app.creationTime), monospaced: false),
                DetailItem("Custom IAM resources", ComputeFormat.bool(app.resourcesSupported.map { !$0 })),
            ])
            DetailChipsField("Labels", app.labels, monospaced: false)
            DetailChipsField("Required capabilities", app.requiredCapabilities)
            HStack(spacing: 16) {
                ExternalLinkButton(title: "Home page", urlString: app.homePageUrl)
                ExternalLinkButton(title: "Source code", urlString: app.sourceCodeUrl)
                ExternalLinkButton(title: "README", urlString: app.readmeUrl)
                ExternalLinkButton(title: "License", urlString: app.licenseUrl)
                ExternalLinkButton(title: "Template", urlString: app.templateUrl)
            }
            DetailSection(title: "Application ARN") { CopyableBlock(text: app.applicationId) }
        }
    }

    @ViewBuilder
    private func parameters(_ app: SarApplicationDetail) -> some View {
        if app.parameters.isEmpty {
            EmptyStateView(message: "The latest version has no template parameters")
        } else {
            Table(app.parameters) {
                TableColumn("Name") { p in Text(p.name).font(.caption.monospaced().bold()) }
                    .width(min: 120, ideal: 180)
                TableColumn("Type") { p in Text(p.type ?? "-").font(.caption.monospaced()) }
                    .width(min: 60, ideal: 90)
                TableColumn("Default") { p in Text(p.defaultValue ?? "-").font(.caption.monospaced()) }
                    .width(min: 80, ideal: 140)
                TableColumn("Description") { p in
                    Text(p.allowedValues.isEmpty ? (p.description ?? "-") : "\(p.description ?? "") [\(p.allowedValues.joined(separator: ", "))]")
                        .font(.caption)
                        .lineLimit(3)
                }
            }
        }
    }

    @ViewBuilder
    private func versions(_ app: SarApplicationDetail) -> some View {
        if app.versions.isEmpty {
            EmptyStateView(message: "No versions")
        } else {
            Table(app.versions) {
                TableColumn("Version") { v in Text(v.semanticVersion).font(.caption.monospaced().bold()) }
                    .width(min: 80, ideal: 110)
                TableColumn("Created") { v in Text(Formatters.formatISODate(v.creationTime)).font(.caption) }
                    .width(min: 120, ideal: 160)
                TableColumn("Source code") { v in Text(v.sourceCodeUrl ?? "-").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle) }
            }
        }
    }

    private func sharing(_ app: SarApplicationDetail) -> some View {
        DetailTabPage {
            DetailNote("Who can deploy this application. \"*\" as a principal means it's public.")
            if let error = app.policyError {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else if app.policy.isEmpty {
                Text("Private - only this account can deploy it.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(app.policy.enumerated()), id: \.offset) { _, statement in
                VStack(alignment: .leading, spacing: 6) {
                    if let sid = statement.statementId {
                        Text(sid).font(.caption.monospaced().bold())
                    }
                    DetailChipsField("Principals", statement.principals)
                    DetailChipsField("Actions", statement.actions)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await api.getSarApplication(profile: appState.currentProfile, region: appState.currentRegion, applicationId: applicationId))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
