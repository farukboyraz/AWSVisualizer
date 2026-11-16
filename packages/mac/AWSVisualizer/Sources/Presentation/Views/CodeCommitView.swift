import SwiftUI

struct CodeCommitView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var reposState: LoadState<[CodeCommitRepository]> = .loading
    @State private var selectedRepo: CodeCommitRepository?
    @State private var showNewRepository = false
    /// Preloaded as soon as the tab opens, so the "has a local workspace"
    /// indicator next to each repo name is ready before the user ever picks
    /// one - not fetched lazily per-repo like `WorkspaceView`'s own status.
    @State private var workspaceRepoNames: Set<String> = []
    /// Tab a dashboard card asked for ("commits", "pullRequests"…).
    @State private var deepLinkTab: String?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 240, minWidth: 180, maxWidth: 400, isDetailActive: selectedRepo != nil, onBack: { selectedRepo = nil }, backTitle: "Repositories", detailTitle: selectedRepo?.repositoryName) {
                repoListPanel
            } detail: {
                if let selectedRepo {
                    CodeCommitRepositoryDetailView(repository: selectedRepo, initialTab: deepLinkTab, onRenamed: {
                        self.selectedRepo = nil
                        Task { await loadRepos() }
                    }, onDeleted: {
                        self.selectedRepo = nil
                        Task { await loadRepos() }
                    }, onWorkspaceChanged: {
                        Task { await loadWorkspaceNames() }
                    })
                    .id(selectedRepo.id)
                } else {
                    EmptyStateView(message: "Select a repository")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadRepos()
                await loadWorkspaceNames()
            }
        }
        .sheet(isPresented: $showNewRepository) {
            NewRepositorySheet {
                showNewRepository = false
                Task { await loadRepos() }
            }
        }
    }

    private var repoListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("CodeCommit")
            ScreenFilterField(text: $filter)
            LoadableContent(reposState, retry: { Task { await loadRepos() } }) { unfilteredRepos in
                let repos = unfilteredRepos.matching(filter)
                List(repos, selection: Binding(
                    get: { selectedRepo?.id },
                    set: { id in selectedRepo = repos.first { $0.id == id } }
                )) { repo in
                    RepositoryRow(
                        name: repo.repositoryName,
                        hasWorkspace: workspaceRepoNames.contains(repo.repositoryName),
                        isSelected: selectedRepo?.id == repo.id
                    )
                    .tag(repo.id)
                }
                .listStyle(.sidebar)
            }
            PanelActionBar {
                NewButton(compactSize: 22, help: "New Repository") {
                    showNewRepository = true
                }
            }
        }
    }

    private func loadRepos() async {
        reposState = .loading
        selectedRepo = nil
        do {
            let repos = try await api.getCodeCommitRepositories(profile: appState.currentProfile, region: appState.currentRegion)
            reposState = repos.isEmpty ? .empty : .loaded(repos)
            // A dashboard card asked for one repository (and maybe a tab).
            if let link = appState.takeDeepLink(for: "codecommit"), let repo = repos.first(where: { $0.repositoryName == link.resource }) {
                deepLinkTab = link.tab
                selectedRepo = repo
            }
        } catch {
            reposState = .failed(error.friendlyMessage)
        }
    }

    private func loadWorkspaceNames() async {
        // Best-effort - this is only a "have a look" indicator, not worth
        // its own error state if it fails.
        if let entries = try? await api.listWorkspaces() {
            workspaceRepoNames = Set(entries.map(\.repositoryName))
        }
    }
}

/// A repository in the left list: name, and at the far right - one
/// column for every row - the local-workspace check. Lights up under the
/// mouse even when it isn't the selected one.
private struct RepositoryRow: View {
    let name: String
    let hasWorkspace: Bool
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.body.bold())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .opacity(hasWorkspace ? 1 : 0)
                .help(hasWorkspace ? "Has a local workspace" : "")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(isHovered && !isSelected ? 0.12 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
    }
}

private struct CodeCommitRepositoryDetailView: View {
    let repository: CodeCommitRepository
    /// "files" | "commits" | "branches" | "pullRequests" (dashboard cards).
    var initialTab: String? = nil
    var onRenamed: () -> Void
    var onDeleted: () -> Void
    var onWorkspaceChanged: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    private enum DetailTab: String, CaseIterable {
        case files = "Files"
        case commits = "Commits"
        case branches = "Branches"
        case pullRequests = "Pull Requests"
        case workspace = "Workspace"
        case settings = "Settings"
    }

    @State private var tab: DetailTab = .files
    @State private var detailState: LoadState<CodeCommitRepositoryDetail> = .loading
    @State private var branchesState: LoadState<[CodeCommitBranch]> = .loading
    /// The single "currently viewing" branch, shared by every tab below that
    /// cares about one - changing it here is what makes Files/Commits (and
    /// anything else added later) switch together, instead of each tab
    /// owning its own independent branch picker.
    @State private var selectedBranch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Text(repository.repositoryName)
                    .font(.title2.bold())
                if case .loaded(let branches) = branchesState, !branches.isEmpty {
                    BranchPickerField(branches: branches, defaultBranch: defaultBranchName, selection: $selectedBranch)
                        .frame(width: 220)
                }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 4)

            LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
                VStack(alignment: .leading, spacing: 0) {
                    detailHeader(detail)

                    TabBar(selection: $tab)
                    .padding(.bottom, 8)

                    Group {
                        switch tab {
                        case .files:
                            CodeCommitFilesView(repositoryName: repository.repositoryName, defaultBranch: effectiveBranch(detail))
                        case .commits:
                            CodeCommitCommitsView(repositoryName: repository.repositoryName, defaultBranch: effectiveBranch(detail))
                        case .branches:
                            CodeCommitBranchesView(repositoryName: repository.repositoryName, defaultBranch: detail.defaultBranch ?? "main", onOpenCommits: { branchName in
                                selectedBranch = branchName
                                tab = .commits
                            })
                        case .pullRequests:
                            CodeCommitPullRequestsView(repositoryName: repository.repositoryName, defaultBranch: detail.defaultBranch ?? "main")
                        case .workspace:
                            WorkspaceView(repositoryName: repository.repositoryName, cloneUrlHttp: detail.cloneUrlHttp, branches: loadedBranches, defaultBranch: detail.defaultBranch ?? "main", compareBranch: effectiveBranch(detail), onWorkspaceChanged: onWorkspaceChanged)
                        case .settings:
                            CodeCommitRepositorySettingsView(
                                repositoryName: repository.repositoryName,
                                detail: detail,
                                onUpdated: { updated in detailState = .loaded(updated) },
                                onRenamed: onRenamed,
                                onDeleted: onDeleted
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            switch initialTab {
            case "commits": tab = .commits
            case "branches": tab = .branches
            case "pullRequests": tab = .pullRequests
            case "files": tab = .files
            default: break
            }
        }
        .task {
            await loadDetail()
            await loadBranches()
        }
    }

    private var defaultBranchName: String {
        if case .loaded(let detail) = detailState { return detail.defaultBranch ?? "" }
        return ""
    }

    private var loadedBranches: [CodeCommitBranch] {
        if case .loaded(let branches) = branchesState { return branches }
        return []
    }

    /// Falls back to the repo's actual default branch until the branch list
    /// (and with it, the user-facing picker) has finished loading, so Files/
    /// Commits don't sit blocked on a request that isn't even about them.
    private func effectiveBranch(_ detail: CodeCommitRepositoryDetail) -> String {
        selectedBranch.isEmpty ? (detail.defaultBranch ?? "main") : selectedBranch
    }

    @ViewBuilder
    private func detailHeader(_ detail: CodeCommitRepositoryDetail) -> some View {
        if let description = detail.description, !description.isEmpty {
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }

    private func loadDetail() async {
        detailState = .loading
        do {
            let detail = try await api.getCodeCommitRepositoryDetail(profile: appState.currentProfile, region: appState.currentRegion, name: repository.repositoryName)
            detailState = .loaded(detail)
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }

    private func loadBranches() async {
        branchesState = .loading
        do {
            let branches = try await api.getCodeCommitBranches(profile: appState.currentProfile, region: appState.currentRegion, name: repository.repositoryName)
            branchesState = branches.isEmpty ? .empty : .loaded(branches)
            if selectedBranch.isEmpty {
                selectedBranch = branches.first { $0.name == defaultBranchName }?.name ?? branches.first?.name ?? ""
            }
        } catch {
            branchesState = .failed(error.friendlyMessage)
        }
    }
}

private struct NewRepositorySheet: View {
    var onCreated: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New Repository")
                    .font(.title2.bold())
                Spacer()
                SecondaryButton("Cancel") { dismiss() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Repository Name").font(.caption).foregroundStyle(.secondary)
                TextField("my-repo", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Description (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("What this repository is for", text: $description)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                NewButton("Create Repository", isLoading: isCreating, isDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await create() }
                }
            }
        }
        .padding(24)
        .frame(width: 420, height: 240)
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        do {
            try await api.createCodeCommitRepository(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                repositoryName: name.trimmingCharacters(in: .whitespaces),
                description: description.trimmingCharacters(in: .whitespaces).isEmpty ? nil : description
            )
            onCreated()
        } catch {
            errorMessage = error.friendlyMessage
        }
        isCreating = false
    }
}
