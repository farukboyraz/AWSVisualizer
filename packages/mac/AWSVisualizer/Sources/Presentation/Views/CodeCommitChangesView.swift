import SwiftUI

/// Shared file-diff viewer for CodeCommit - used for a single commit's
/// changes (vs. its parent), a diff between two arbitrary commits, and a
/// diff between two branches. All three are just a `before`/`after`
/// commit specifier pair under the hood (GetDifferences accepts branch
/// names or commit IDs interchangeably).
struct CodeCommitChangesView: View {
    let repositoryName: String
    let before: String?
    let after: String
    let title: String
    let subtitle: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3.bold())
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                SheetMaximizeButton()
                SecondaryButton("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            CodeCommitDiffPane(repositoryName: repositoryName, before: before, after: after)
        }
        .frame(minWidth: 760, idealWidth: 1400, maxWidth: .infinity, minHeight: 480, idealHeight: 860, maxHeight: .infinity)
        .resizableSheet(minWidth: 760, minHeight: 480)
    }
}

/// The reusable "file list + diff" split view, with no chrome of its own -
/// embeddable directly in a sheet (`CodeCommitChangesView`) or inline in a
/// larger view (the pull request detail/merge screen). Given a pull
/// request it also shows that PR's file and line comments: a count per
/// file, bubbles on commented lines, click-a-line-number to comment, and
/// the expandable `CodeCommitFileComments` drawer under the diff.
struct CodeCommitDiffPane: View {
    let repositoryName: String
    let before: String?
    let after: String
    var pullRequest: CodeCommitPullRequest? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var entriesState: LoadState<[CodeCommitDiffEntry]> = .loading
    @State private var selectedPath: String?
    @State private var fileDiffState: LoadState<CodeCommitFileDiff> = .empty
    @State private var diffMode: DiffViewMode = .unified
    @State private var fileListHidden = false

    @State private var commentThreads: [CodeCommitCommentThread] = []
    @State private var commentsError: String?
    @State private var commentTarget: DiffLineRef?
    @State private var commentsExpanded = false
    @State private var commentFocus: DiffLineRef?
    @State private var commentFocusToken = 0

    var body: some View {
        ResizableSplitView(initialWidth: 300, minWidth: 220, maxWidth: 520, leftHidden: fileListHidden) {
            fileListPanel
        } right: {
            fileDiffPanel
        }
        .task(id: "\(before ?? "")-\(after)") {
            await loadEntries()
        }
        .task(id: "\(pullRequest?.pullRequestId ?? "")|\(pullRequest?.sourceCommit ?? "")|\(appState.currentProfile)|\(appState.currentRegion)") {
            await loadComments()
        }
        .onChange(of: selectedPath) { _, _ in
            commentTarget = nil
            commentFocus = nil
        }
    }

    // MARK: Pull request comments

    private func threads(for path: String) -> [CodeCommitCommentThread] {
        commentThreads.filter { $0.location?.filePath == path }
    }

    private func isCurrent(_ thread: CodeCommitCommentThread) -> Bool {
        guard let after = thread.afterCommitId, let source = pullRequest?.sourceCommit else { return true }
        return after == source
    }

    /// Current (not outdated) threads per file, for the file list badges.
    private var commentCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for thread in commentThreads where isCurrent(thread) {
            if let path = thread.location?.filePath { counts[path, default: 0] += 1 }
        }
        return counts
    }

    private func commentedLines(for path: String) -> Set<DiffLineRef> {
        Set(threads(for: path).filter(isCurrent).compactMap(\.lineRef))
    }

    private func lineTapped(_ ref: DiffLineRef) {
        commentTarget = ref
        commentFocus = ref
        commentsExpanded = true
        commentFocusToken += 1
    }

    private func loadComments() async {
        guard let pullRequest else { return }
        do {
            // Every revision's threads (no commit filter) - threads written on
            // an older source commit are listed as outdated, without a marker.
            commentThreads = try await api.getCodeCommitPullRequestComments(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                pullRequestId: pullRequest.pullRequestId,
                repositoryName: nil,
                beforeCommitId: nil,
                afterCommitId: nil
            )
            commentsError = nil
        } catch where error.isCancellation {
            return
        } catch {
            commentsError = error.friendlyMessage
        }
    }

    private var fileListPanel: some View {
        LoadableContent(entriesState, retry: { Task { await loadEntries() } }, emptyMessage: "No differences") { entries in
            // A plain List with no `selection:` binding - a selection
            // binding turns every top-level ForEach item (each folder,
            // header + all its nested children together) into a single
            // opaque row for macOS's native list-selection hit-testing, so
            // clicking a file nested inside an expanded folder could
            // register as clicking the *folder's* row instead. Selection is
            // tracked and highlighted by hand instead, the same way
            // `BranchTreeView` already does it successfully.
            let counts = commentCounts
            List {
                PathTreeView(nodes: buildPathTree(entries, path: { $0.path })) { entry in
                    fileRow(entry, comments: counts[entry.path] ?? 0)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func fileRow(_ entry: CodeCommitDiffEntry, comments: Int) -> some View {
        HStack(spacing: 8) {
            FileIcon(name: fileName(entry.path))
                .font(.caption)
            Text(fileName(entry.path))
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if comments > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "text.bubble.fill")
                    Text("\(comments)")
                }
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
                .help(appState.language.prCommentCount(comments))
            }
            // At the far right, so the badges line up in one column.
            changeTypeBadge(entry.changeType)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(entry.path == selectedPath ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPath = entry.path
            Task { await loadFileDiff(path: entry.path) }
        }
    }

    private func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private var fileDiffPanel: some View {
        VStack(spacing: 0) {
            fileDiffBody
            if let pullRequest, let selectedPath {
                CodeCommitFileComments(
                    repositoryName: repositoryName,
                    pullRequest: pullRequest,
                    path: selectedPath,
                    threads: threads(for: selectedPath),
                    loadError: commentsError,
                    target: $commentTarget,
                    isExpanded: $commentsExpanded,
                    focus: commentFocus,
                    focusToken: commentFocusToken,
                    reload: { await loadComments() }
                )
            }
        }
    }

    @ViewBuilder
    private var fileDiffBody: some View {
        if selectedPath == nil {
            EmptyStateView(message: "Select a file to view its diff")
        } else {
            LoadableContent(fileDiffState, retry: {
                if let selectedPath { Task { await loadFileDiff(path: selectedPath) } }
            }) { fileDiff in
                if fileDiff.binary {
                    EmptyStateView(message: "Preview not available (binary or too large)")
                } else if fileDiff.hunks.isEmpty {
                    EmptyStateView(message: "No textual changes")
                } else {
                    FileDiffContentView(
                        fileDiff: fileDiff,
                        mode: $diffMode,
                        fileListHidden: $fileListHidden,
                        loadFullFile: {
                            try await api.getCodeCommitFileDiff(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, path: fileDiff.path, before: before, after: after, fullFile: true)
                        },
                        commentedLines: pullRequest == nil ? [] : commentedLines(for: fileDiff.path),
                        onLineTap: pullRequest == nil ? nil : { lineTapped($0) }
                    )
                }
            }
        }
    }

    private func changeTypeBadge(_ changeType: String) -> some View {
        ChangeTypeBadge(changeType: changeType)
    }

    private func loadEntries() async {
        entriesState = .loading
        selectedPath = nil
        do {
            let entries = try await api.getCodeCommitDifferences(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, before: before, after: after)
            entriesState = entries.isEmpty ? .empty : .loaded(entries)
            if let firstPath = entries.first?.path {
                selectedPath = firstPath
                await loadFileDiff(path: firstPath)
            }
        } catch {
            entriesState = .failed(error.friendlyMessage)
        }
    }

    private func loadFileDiff(path: String) async {
        fileDiffState = .loading
        do {
            let diff = try await api.getCodeCommitFileDiff(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, path: path, before: before, after: after)
            fileDiffState = .loaded(diff)
        } catch {
            fileDiffState = .failed(error.friendlyMessage)
        }
    }
}
