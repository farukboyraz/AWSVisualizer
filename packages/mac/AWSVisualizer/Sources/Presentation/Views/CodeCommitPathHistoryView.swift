import SwiftUI

/// "git log -- <path>" for a folder in the Files tab - shows commits that
/// touched anything underneath it (subfolders included). Files show their
/// history inline in the preview pane instead (`CodeCommitFilePreviewPane`)
/// since there's already a content area to reuse there; a folder has no
/// such area, so this stays a popup. Reuses the same commit table
/// (view/compare) as the branch-wide Commits tab. Paginated - each page
/// walks a bounded slice of the commit graph server-side, so "Load More"
/// keeps going deeper instead of one request trying to walk the whole
/// history (which is what used to time out).
struct CodeCommitPathHistoryView: View {
    let repositoryName: String
    let commitSpecifier: String
    let path: String
    let displayName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var commitsState: LoadState<[CodeCommitCommit]> = .loading
    @State private var commits: [CodeCommitCommit] = []
    @State private var nextCursor: String?
    @State private var isLoadingMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("History")
                        .font(.title3.bold())
                    Text(path.isEmpty ? repositoryName : displayName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SheetMaximizeButton()
                SecondaryButton("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            LoadableContent(commitsState, retry: { Task { await load() } }, emptyMessage: "No commits touched this path") { _ in
                VStack(spacing: 0) {
                    CodeCommitCommitTable(repositoryName: repositoryName, commits: commits)
                    if nextCursor != nil {
                        Divider()
                        Button {
                            Task { await loadMore() }
                        } label: {
                            if isLoadingMore {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Load Earlier Commits")
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                        .padding(8)
                        .disabled(isLoadingMore)
                    }
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 900, maxWidth: .infinity, minHeight: 420, idealHeight: 680, maxHeight: .infinity)
        .resizableSheet(minWidth: 620, minHeight: 420)
        .task {
            await load()
        }
    }

    private func load() async {
        commitsState = .loading
        commits = []
        nextCursor = nil
        do {
            let page = try await api.getCodeCommitCommitsForPath(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                name: repositoryName,
                commit: commitSpecifier,
                path: path,
                cursor: nil,
                limit: 30
            )
            commits = page.commits
            nextCursor = page.nextCursor
            commitsState = commits.isEmpty && nextCursor == nil ? .empty : .loaded(commits)
        } catch {
            commitsState = .failed(error.friendlyMessage)
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let page = try await api.getCodeCommitCommitsForPath(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                name: repositoryName,
                commit: commitSpecifier,
                path: path,
                cursor: cursor,
                limit: 30
            )
            commits += page.commits
            nextCursor = page.nextCursor
            commitsState = .loaded(commits)
        } catch {
            // Keep the commits already loaded on screen - only surface
            // the error, don't blow away a page that already succeeded.
        }
        isLoadingMore = false
    }
}
