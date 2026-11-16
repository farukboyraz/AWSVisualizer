import SwiftUI

/// Self-loading file preview - given just an entry to look at, it fetches
/// and renders its own content, the same "hand it identifiers, it owns its
/// load" pattern as `CodeCommitDiffPane`. Also owns editing (`PutFile`) and
/// deletion (`DeleteFile`), since those are file-preview-scoped concerns
/// that don't belong in the file *list* panel next to it.
struct CodeCommitFilePreviewPane: View {
    let repositoryName: String
    let branchName: String
    let entry: CodeCommitFolderEntry?
    var isPinned: Bool = false
    /// Left nil when there's nothing selected to pin (owner is the file
    /// list panel, since the pin bar lives there too).
    var onTogglePin: (() -> Void)? = nil
    /// Owned by the file list panel (not local @State) so double-click and
    /// "View History" in the file list can open a file already showing its
    /// history, not just flip a toggle this view can't see from outside.
    @Binding var showHistory: Bool
    /// Called after a save or delete actually changes the repository, so
    /// the file list panel can refresh.
    var onFileChanged: () -> Void = {}

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var fileState: LoadState<CodeCommitFileContent> = .empty
    @State private var fileTask: Task<Void, Never>?

    @State private var isEditing = false
    @State private var editedContent = ""
    @State private var commitMessage = ""
    @State private var isSaving = false
    @State private var saveError: String?

    @State private var isDeleting = false
    @State private var deleteError: String?

    @State private var historyState: LoadState<[CodeCommitCommit]> = .loading
    @State private var historyCommits: [CodeCommitCommit] = []
    @State private var historyNextCursor: String?
    @State private var isLoadingMoreHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entry, !entry.isFolder, case .loaded(let file) = fileState {
                toolbar(entry, file)
                Divider()
            }

            if showHistory && historySideBySide {
                // Settings → File history → Side by side: code left,
                // history right, the divider drags.
                ResizableSplitView(initialWidth: 520, minWidth: 240, maxWidth: 4000) {
                    contentArea
                } right: {
                    historyView
                }
            } else if showHistory {
                historyView
            } else {
                contentArea
            }
        }
        .task(id: entry?.path) {
            isEditing = false
            saveError = nil
            deleteError = nil
            if let entry, !entry.isFolder {
                load(entry)
            } else {
                cancel()
            }
        }
        .task(id: "\(entry?.path ?? "")|\(showHistory)") {
            guard showHistory, let entry, !entry.isFolder else { return }
            await loadHistory(entry)
        }
    }

    private var historySideBySide: Bool { appState.historyLayout == .sideBySide }

    @ViewBuilder
    private var contentArea: some View {
                LoadableContent(fileState, retry: { if let entry { load(entry) } }, cancel: cancel, emptyMessage: "Select a file to preview") { file in
                    if isEditing {
                        editor
                    } else if file.isText, let content = file.content {
                        // Viewer picked by extension: C#, JS/TS, JSON (code/tree),
                        // XML (code/tree), Markdown (preview/source), YAML, ... -
                        // highlighted, with line numbers and word wrap.
                        FileContentViewer(path: file.path, text: content)
                    } else if let imageData = file.imageData {
                        ImagePreviewView(data: imageData)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.questionmark")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("Binary file or too large to preview")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                // The type is in the toolbar next to the name.
                .environment(\.codeViewerShowsLanguage, false)
    }

    @ViewBuilder
    private func toolbar(_ entry: CodeCommitFolderEntry, _ file: CodeCommitFileContent) -> some View {
        HStack {
            FileIcon(name: entry.name)
            Text(entry.name)
                .font(.callout.bold())
            // The file type sits next to the name (the code viewer below no
            // longer repeats it on its own line).
            if file.isText {
                let language = CodeLanguage.detect(path: entry.name)
                Text(language.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            Spacer()
            if isEditing {
                SecondaryButton("Cancel") {
                    isEditing = false
                    saveError = nil
                }
                SaveButton("Commit Changes", isLoading: isSaving, isDisabled: commitMessage.trimmingCharacters(in: .whitespaces).isEmpty || editedContent == file.content) {
                    Task { await save(entry, baseCommitId: file.commitId) }
                }
            } else {
                if let onTogglePin {
                    Button(action: onTogglePin) {
                        Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.fill" : "pin")
                    }
                }
                Button {
                    showHistory.toggle()
                } label: {
                    Label(showHistory ? "Content" : "History", systemImage: showHistory ? "doc.text" : "clock.arrow.circlepath")
                }
                if !showHistory || historySideBySide, file.isText {
                    EditButton("Edit") {
                        editedContent = file.content ?? ""
                        commitMessage = "Update \(entry.name)"
                        isEditing = true
                    }
                    DeleteButton("Delete") {
                        Task { await delete(entry) }
                    }
                }
            }
        }
        .padding(8)

        if isEditing {
            TextField("Commit message", text: $commitMessage)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        if let saveError {
            Text(saveError).font(.caption).foregroundStyle(.red).padding(.horizontal, 8).padding(.bottom, 4)
        }
        if let deleteError {
            Text(deleteError).font(.caption).foregroundStyle(.red).padding(.horizontal, 8).padding(.bottom, 4)
        }
    }

    private var editor: some View {
        TextEditor(text: $editedContent)
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(4)
    }

    @ViewBuilder
    private var historyView: some View {
        LoadableContent(historyState, retry: { if let entry { Task { await loadHistory(entry) } } }, emptyMessage: "No commits touched this file") { _ in
            VStack(spacing: 0) {
                CodeCommitCommitTable(repositoryName: repositoryName, commits: historyCommits)
                if historyNextCursor != nil {
                    Divider()
                    Button {
                        if let entry { Task { await loadMoreHistory(entry) } }
                    } label: {
                        if isLoadingMoreHistory {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Load Earlier Commits")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
                    .padding(8)
                    .disabled(isLoadingMoreHistory)
                }
            }
        }
    }

    private func loadHistory(_ entry: CodeCommitFolderEntry) async {
        historyState = .loading
        historyCommits = []
        historyNextCursor = nil
        do {
            let page = try await api.getCodeCommitCommitsForPath(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                name: repositoryName,
                commit: branchName,
                path: entry.path,
                cursor: nil,
                limit: 30
            )
            historyCommits = page.commits
            historyNextCursor = page.nextCursor
            historyState = historyCommits.isEmpty && historyNextCursor == nil ? .empty : .loaded(historyCommits)
        } catch {
            historyState = .failed(error.friendlyMessage)
        }
    }

    private func loadMoreHistory(_ entry: CodeCommitFolderEntry) async {
        guard let cursor = historyNextCursor, !isLoadingMoreHistory else { return }
        isLoadingMoreHistory = true
        do {
            let page = try await api.getCodeCommitCommitsForPath(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                name: repositoryName,
                commit: branchName,
                path: entry.path,
                cursor: cursor,
                limit: 30
            )
            historyCommits += page.commits
            historyNextCursor = page.nextCursor
            historyState = .loaded(historyCommits)
        } catch {
            // Keep what already loaded on screen rather than clearing it.
        }
        isLoadingMoreHistory = false
    }

    private func load(_ entry: CodeCommitFolderEntry) {
        fileTask?.cancel()
        fileState = .loading
        fileTask = Task {
            do {
                let file = try await api.getCodeCommitFile(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, path: entry.path, commit: branchName)
                guard !Task.isCancelled else { return }
                fileState = .loaded(file)
            } catch {
                guard !Task.isCancelled else { return }
                fileState = .failed(error.friendlyMessage)
            }
        }
    }

    private func cancel() {
        fileTask?.cancel()
        fileTask = nil
        fileState = .empty
    }

    private func save(_ entry: CodeCommitFolderEntry, baseCommitId: String) async {
        isSaving = true
        saveError = nil
        do {
            _ = try await api.putCodeCommitFile(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                repositoryName: repositoryName,
                branchName: branchName,
                filePath: entry.path,
                fileContent: editedContent,
                commitMessage: commitMessage.trimmingCharacters(in: .whitespaces),
                parentCommitId: baseCommitId
            )
            isEditing = false
            onFileChanged()
            load(entry)
        } catch {
            saveError = error.friendlyMessage
        }
        isSaving = false
    }

    private func delete(_ entry: CodeCommitFolderEntry) async {
        guard case .loaded(let file) = fileState else { return }
        isDeleting = true
        deleteError = nil
        do {
            _ = try await api.deleteCodeCommitFile(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                repositoryName: repositoryName,
                branchName: branchName,
                filePath: entry.path,
                commitMessage: "Delete \(entry.name)",
                parentCommitId: file.commitId
            )
            onFileChanged()
        } catch {
            deleteError = error.friendlyMessage
        }
        isDeleting = false
    }
}
