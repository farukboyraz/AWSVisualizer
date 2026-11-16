import SwiftUI

/// Follows whatever branch the repo header's picker currently has selected
/// (`defaultBranch` here just means "the branch to show", set by the
/// parent) - no branch picker of its own, so there's exactly one place in
/// the CodeCommit tab that controls which branch is being viewed.
struct CodeCommitCommitsView: View {
    let repositoryName: String
    let defaultBranch: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var commitsState: LoadState<[CodeCommitCommit]> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            branchBar

            Divider()

            LoadableContent(commitsState, retry: { Task { await loadCommits() } }) { commits in
                CodeCommitCommitTable(repositoryName: repositoryName, commits: commits, showsGraph: true)
            }
        }
        .task(id: defaultBranch) {
            await loadCommits()
        }
    }

    private var branchBar: some View {
        HStack {
            Label(defaultBranch, systemImage: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await loadCommits() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .padding()
    }

    private func loadCommits() async {
        guard !defaultBranch.isEmpty else { return }
        commitsState = .loading
        do {
            let commits = try await api.getCodeCommitCommits(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, commit: defaultBranch, limit: 50)
            commitsState = commits.isEmpty ? .empty : .loaded(commits)
        } catch {
            commitsState = .failed(error.friendlyMessage)
        }
    }
}
