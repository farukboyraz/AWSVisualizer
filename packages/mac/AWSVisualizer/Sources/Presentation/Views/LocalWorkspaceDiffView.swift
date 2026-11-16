import SwiftUI

/// Compares a local workspace (its working tree, including uncommitted
/// edits - not just its last commit) against a branch, fetched fresh from
/// origin first. The file-list-with-+/--counts-per-row and the split/
/// unified diff itself are two different concerns: the counts come from a
/// cheap `git diff --numstat` pass (`LocalDiffFile`, one call for the whole
/// list); the actual hunks for one file (`CodeCommitFileDiff`, same shape
/// CodeCommit's own PR/commit diff uses) are only fetched once that file is
/// clicked, via `FileDiffContentView` - the same renderer, so Split mode's
/// "removed on the left, added on the right" coloring is identical either
/// way.
struct LocalWorkspaceDiffView: View {
    let repositoryName: String
    let branch: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var filesState: LoadState<[LocalDiffFile]> = .loading
    @State private var selectedPath: String?
    @State private var fileDiffState: LoadState<CodeCommitFileDiff> = .empty
    @State private var diffMode: DiffViewMode = .unified
    @State private var fileListHidden = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare Workspace")
                        .font(.title3.bold())
                    Text("Local checkout vs. \(branch)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SecondaryButton("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ResizableSplitView(initialWidth: 320, minWidth: 240, maxWidth: 520, leftHidden: fileListHidden) {
                fileListPanel
            } right: {
                fileDiffPanel
            }
        }
        .frame(minWidth: 1100, idealWidth: 1400, maxWidth: .infinity, minHeight: 720, idealHeight: 860, maxHeight: .infinity)
        .task {
            await loadFiles()
        }
    }

    private var fileListPanel: some View {
        LoadableContent(filesState, retry: { Task { await loadFiles() } }, emptyMessage: "No differences") { files in
            List {
                ForEach(files) { file in
                    fileRow(file)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func fileRow(_ file: LocalDiffFile) -> some View {
        HStack(spacing: 8) {
            FileIcon(name: fileName(file.path))
                .font(.caption)
            Text(fileName(file.path))
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if file.binary {
                Text("binary")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 4) {
                    if file.additions > 0 {
                        Text("+\(file.additions)")
                            .foregroundStyle(.green)
                    }
                    if file.deletions > 0 {
                        Text("-\(file.deletions)")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption2.monospaced())
            }
            // At the far right, so the badges line up in one column.
            changeTypeBadge(file.changeType)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(file.path == selectedPath ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPath = file.path
            Task { await loadFileDiff(path: file.path) }
        }
    }

    private func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private func changeTypeBadge(_ changeType: String) -> some View {
        ChangeTypeBadge(changeType: changeType)
    }

    @ViewBuilder
    private var fileDiffPanel: some View {
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
                    FileDiffContentView(fileDiff: fileDiff, mode: $diffMode, fileListHidden: $fileListHidden, loadFullFile: {
                        try await api.getLocalWorkspaceFileDiff(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, branch: branch, path: fileDiff.path, fullFile: true)
                    })
                }
            }
        }
    }

    private func loadFiles() async {
        filesState = .loading
        selectedPath = nil
        do {
            let files = try await api.getLocalWorkspaceDiffSummary(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, branch: branch)
            filesState = files.isEmpty ? .empty : .loaded(files)
            if let first = files.first {
                selectedPath = first.path
                await loadFileDiff(path: first.path)
            }
        } catch {
            filesState = .failed(error.friendlyMessage)
        }
    }

    private func loadFileDiff(path: String) async {
        fileDiffState = .loading
        do {
            let diff = try await api.getLocalWorkspaceFileDiff(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, branch: branch, path: path)
            fileDiffState = .loaded(diff)
        } catch {
            fileDiffState = .failed(error.friendlyMessage)
        }
    }
}
