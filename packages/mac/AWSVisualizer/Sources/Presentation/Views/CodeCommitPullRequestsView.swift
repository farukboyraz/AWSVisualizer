import SwiftUI

struct CodeCommitPullRequestsView: View {
    let repositoryName: String
    let defaultBranch: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var status = "OPEN"
    @State private var state: LoadState<[CodeCommitPullRequest]> = .loading
    @State private var showNewPullRequest = false
    @State private var selectedPullRequest: CodeCommitPullRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TabBar(tabs: ["OPEN", "CLOSED"], selection: $status, style: .pills, title: { $0 == "OPEN" ? "Open" : "Closed" })

                Spacer()

                NewButton("New Pull Request") {
                    showNewPullRequest = true
                }
            }
            .padding()

            LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No pull requests") { pullRequests in
                List(pullRequests) { pr in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(pr.title)
                                .font(.body.bold())
                            Spacer()
                            StatusBadge(pr.isMerged == true ? "MERGED" : pr.status, color: pr.isMerged == true ? .purple : nil)
                        }
                        if let source = pr.sourceReference, let destination = pr.destinationReference {
                            Text("\(source) → \(destination)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let description = pr.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedPullRequest = pr }
                    .contextMenu {
                        if pr.status == "OPEN" && pr.isMerged != true {
                            Button("Close Pull Request", role: .destructive) {
                                Task { await close(pr) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .task(id: status) {
            await load()
        }
        .sheet(isPresented: $showNewPullRequest) {
            NewPullRequestSheet(repositoryName: repositoryName, defaultDestination: defaultBranch) {
                showNewPullRequest = false
                Task { await load() }
            }
        }
        .sheet(item: $selectedPullRequest) { pr in
            CodeCommitPullRequestDetailView(repositoryName: repositoryName, pullRequestId: pr.pullRequestId) {
                Task { await load() }
            }
        }
    }

    private func load() async {
        state = .loading
        do {
            let pullRequests = try await api.getCodeCommitPullRequests(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, status: status)
            state = pullRequests.isEmpty ? .empty : .loaded(pullRequests)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }

    private func close(_ pr: CodeCommitPullRequest) async {
        do {
            _ = try await api.closeCodeCommitPullRequest(profile: appState.currentProfile, region: appState.currentRegion, pullRequestId: pr.pullRequestId)
            await load()
        } catch {
            // Rare enough (row-level close failing) to just leave the PR as
            // is and let the user retry from the detail sheet, which does
            // surface the error.
        }
    }
}

private struct NewPullRequestSheet: View {
    let repositoryName: String
    let defaultDestination: String
    var onCreated: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var branchesState: LoadState<[CodeCommitBranch]> = .loading
    @State private var sourceBranch = ""
    @State private var destinationBranch = ""
    @State private var title = ""
    @State private var description = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    @State private var titleMaxLength = 100
    @State private var descriptionMaxLength = 10240
    @State private var titleEditedManually = false
    @State private var isAutoFilling = false
    @State private var aheadHint: String?
    @State private var aheadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New Pull Request")
                    .font(.title2.bold())
                Spacer()
                SecondaryButton("Cancel") { dismiss() }
            }

            LoadableContent(branchesState, retry: { Task { await loadBranches() } }) { branches in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Source Branch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            BranchPickerField(branches: branches, defaultBranch: defaultDestination, selection: $sourceBranch)
                        }
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Destination Branch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            BranchPickerField(branches: branches, defaultBranch: defaultDestination, selection: $destinationBranch)
                        }
                    }
                    if let aheadHint {
                        Text(aheadHint)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(height: 76)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Title")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(title.count)/\(titleMaxLength)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(title.count > titleMaxLength ? Color.red : Color.secondary.opacity(0.6))
                }
                TextField("Pull request title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: title) { _, newValue in
                        if !isAutoFilling { titleEditedManually = true }
                        if newValue.count > titleMaxLength {
                            title = String(newValue.prefix(titleMaxLength))
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(description.count)/\(descriptionMaxLength)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(description.count > descriptionMaxLength ? Color.red : Color.secondary.opacity(0.6))
                }
                TextEditor(text: $description)
                    .frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
                    .onChange(of: description) { _, newValue in
                        if newValue.count > descriptionMaxLength {
                            description = String(newValue.prefix(descriptionMaxLength))
                        }
                    }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                NewButton("Create Pull Request", isLoading: isCreating, isDisabled: !isFormValid) {
                    Task { await create() }
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 500)
        .task {
            destinationBranch = defaultDestination
            await loadBranches()
            await loadPRLimits()
        }
        .onChange(of: sourceBranch) { _, _ in refreshAheadCommit() }
        .onChange(of: destinationBranch) { _, _ in refreshAheadCommit() }
    }

    private var isFormValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && title.count <= titleMaxLength
            && description.count <= descriptionMaxLength
            && !sourceBranch.isEmpty
            && !destinationBranch.isEmpty
            && sourceBranch != destinationBranch
    }

    private func loadBranches() async {
        branchesState = .loading
        do {
            let branches = try await api.getCodeCommitBranches(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName)
            branchesState = branches.isEmpty ? .empty : .loaded(branches)
            if sourceBranch.isEmpty {
                sourceBranch = branches.first { $0.name != destinationBranch }?.name ?? branches.first?.name ?? ""
            }
            refreshAheadCommit()
        } catch {
            branchesState = .failed(error.friendlyMessage)
        }
    }

    private func loadPRLimits() async {
        if let limits = try? await api.getCodeCommitPRLimits() {
            titleMaxLength = limits.titleMaxLength
            descriptionMaxLength = limits.descriptionMaxLength
        }
    }

    /// Prefills the title with the message of the newest commit that source
    /// actually has ahead of destination - not just the source branch tip,
    /// which could differ from what the PR would really bring in.
    private func refreshAheadCommit() {
        aheadTask?.cancel()
        aheadHint = nil
        guard !sourceBranch.isEmpty, !destinationBranch.isEmpty, sourceBranch != destinationBranch else { return }

        aheadTask = Task {
            guard let ahead = try? await api.getCodeCommitCommitsAhead(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                name: repositoryName,
                source: sourceBranch,
                destination: destinationBranch
            ) else { return }
            guard !Task.isCancelled else { return }

            if ahead.isEmpty {
                aheadHint = "No commits ahead of \(destinationBranch)"
                return
            }

            aheadHint = ahead.count == 1
                ? "1 commit ahead of \(destinationBranch)"
                : "\(ahead.count) commits ahead of \(destinationBranch)"

            if !titleEditedManually, let newest = ahead.first {
                isAutoFilling = true
                title = String(firstLine(of: newest.message).prefix(titleMaxLength))
                isAutoFilling = false
            }
        }
    }

    private func firstLine(of message: String) -> String {
        message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        do {
            _ = try await api.createCodeCommitPullRequest(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                repositoryName: repositoryName,
                title: title.trimmingCharacters(in: .whitespaces),
                description: description.isEmpty ? nil : description,
                sourceReference: sourceBranch,
                destinationReference: destinationBranch
            )
            onCreated()
        } catch {
            errorMessage = error.friendlyMessage
        }
        isCreating = false
    }
}
