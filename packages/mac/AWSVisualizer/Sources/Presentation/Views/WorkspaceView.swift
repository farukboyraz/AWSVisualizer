import SwiftUI
import AppKit

/// The "real git" tab, sitting between Pull Requests and Settings: unlike
/// every other CodeCommit tab (which only ever talks to the CodeCommit REST
/// API), this one operates on an actual local clone via the real `git`
/// binary, because CodeCommit's API has no concept of push/pull/merge-into-
/// a-working-copy - those only make sense against a real checkout.
struct WorkspaceView: View {
    let repositoryName: String
    let cloneUrlHttp: String?
    let branches: [CodeCommitBranch]
    let defaultBranch: String
    /// The branch currently chosen in the shared picker next to the repo
    /// name (`CodeCommitView`) - what Compare diffs this workspace against.
    let compareBranch: String
    /// Lets the repo list's "has a local workspace" checkmark
    /// (`CodeCommitView`'s `workspaceRepoNames`) pick up a clone/match/
    /// forget immediately, instead of only refreshing the next time that
    /// list happens to reload.
    var onWorkspaceChanged: () -> Void = {}

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var statusState: LoadState<WorkspaceStatus> = .loading
    @State private var isCloning = false
    @State private var isMatching = false
    @State private var isPulling = false
    @State private var isPushing = false
    @State private var isMerging = false
    @State private var lastResult: GitCommandResult?
    @State private var mergeBranch = ""
    @State private var cloneError: String?
    @State private var matchWarning: String?
    @State private var showCompare = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LoadableContent(statusState, retry: { Task { await loadStatus() } }) { status in
                    if let localPath = status.localPath, !status.isMissing {
                        connectedWorkspace(localPath: localPath, status: status)
                    } else if let localPath = status.localPath, status.isMissing {
                        missingWorkspace(localPath: localPath)
                    } else {
                        clonePanel
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: repositoryName) {
            lastResult = nil
            matchWarning = nil
            await loadStatus()
        }
        .sheet(isPresented: $showCompare) {
            LocalWorkspaceDiffView(repositoryName: repositoryName, branch: compareBranch)
        }
    }

    // MARK: - Not cloned yet

    private var clonePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone")
                .font(.headline)
            Text("This repository hasn't been cloned to a local folder yet. Clone it once to enable Pull, Push, and Merge from here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let cloneUrlHttp {
                HStack(spacing: 8) {
                    Text(cloneUrlHttp)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        copyToPasteboard(cloneUrlHttp)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy clone URL")
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 12) {
                NewButton("Clone to…", isLoading: isCloning, isDisabled: isMatching || cloneUrlHttp == nil) {
                    Task { await clone() }
                }

                SecondaryButton("Match Existing Folder…", systemImage: "checkmark.circle", isLoading: isMatching, isDisabled: isCloning) {
                    Task { await match() }
                }
            }
            Text("Already have this repo cloned somewhere? Match points the app at that existing folder instead of cloning a new copy.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let cloneError {
                Text(cloneError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Saved path missing on disk

    private func missingWorkspace(localPath: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Workspace Not Found", systemImage: "questionmark.folder")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("This app remembers \(localPath) as the local clone, but it's no longer there - it may have been moved, renamed, or deleted outside the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DeleteButton("Forget This Workspace") {
                Task { await forget() }
            }
        }
    }

    // MARK: - Connected workspace

    private func connectedWorkspace(localPath: String, status: WorkspaceStatus) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(localPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button { openInFinder(localPath) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help("Open in Finder")
                    Button { openInTerminal(localPath) } label: { Image(systemName: "terminal") }
                        .buttonStyle(.borderless)
                        .help("Open in Terminal")
                }
                statusSummary(status)
                if let matchWarning {
                    Text(matchWarning).font(.caption).foregroundStyle(.orange)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Compare")
                    .font(.headline)
                Text("See what's different between this workspace (including any local, uncommitted edits) and \u{201C}\(compareBranch)\u{201D} - the branch picked above, next to the repo name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RunButton("Compare with \(compareBranch)", systemImage: "arrow.left.arrow.right", isDisabled: compareBranch.isEmpty) {
                    showCompare = true
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Sync")
                    .font(.headline)
                HStack(spacing: 12) {
                    RefreshButton("Pull", systemImage: "arrow.down", isLoading: isPulling, isDisabled: isPushing || isMerging) {
                        Task { await pull() }
                    }

                    ConfirmButton("Push", systemImage: "arrow.up", isLoading: isPushing, isDisabled: isPulling || isMerging) {
                        Task { await push() }
                    }
                }
                Text("Push updates the remote branch with commits already made locally in this folder - it doesn't create or stage them. Use a regular git client (or the Files tab's direct-commit editor) to actually make commits.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Merge a branch in")
                    .font(.headline)
                Text("Fetches \u{201C}\(mergeBranch.isEmpty ? "the selected branch" : mergeBranch)\u{201D} from the remote and merges it into whatever branch this workspace currently has checked out (\(status.currentBranch ?? "unknown")). This can produce a conflict you'll need to resolve locally, same as merging normally with git.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if !branches.isEmpty {
                        BranchPickerField(branches: branches, defaultBranch: defaultBranch, selection: $mergeBranch)
                            .frame(width: 220)
                    }
                    ConfirmButton("Merge", isLoading: isMerging, isDisabled: isPulling || isPushing || mergeBranch.isEmpty) {
                        Task { await merge() }
                    }
                }
            }

            if let lastResult {
                Divider()
                resultBanner(lastResult, localPath: localPath)
            }

            Divider()

            DeleteButton("Forget This Workspace") {
                Task { await forget() }
            }
        }
        .task {
            if mergeBranch.isEmpty {
                mergeBranch = branches.first(where: { $0.name != status.currentBranch })?.name ?? ""
            }
        }
    }

    private func statusSummary(_ status: WorkspaceStatus) -> some View {
        HStack(spacing: 14) {
            if let branch = status.currentBranch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if status.isDirty {
                Label("Uncommitted changes", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let ahead = status.ahead, ahead > 0 {
                Label("\(ahead) ahead", systemImage: "arrow.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let behind = status.behind, behind > 0 {
                Label("\(behind) behind", systemImage: "arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Result banner (the "extreme case" guidance the user asked for)

    @ViewBuilder
    private func resultBanner(_ result: GitCommandResult, localPath: String) -> some View {
        switch result.outcome {
        case .success:
            Label("Completed successfully.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)

        case .conflict:
            warningBox(tint: .red, icon: "exclamationmark.triangle.fill", title: "Merge Conflict") {
                Text("This left files in a conflicted state that need to be resolved by hand before you can continue - open the folder, edit each file to remove the conflict markers (`<<<<<<<`/`=======`/`>>>>>>>`) and pick the right content, then commit the result there. The app can't resolve this part for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !result.conflictedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(result.conflictedFiles, id: \.self) { file in
                            Text(file).font(.caption.monospaced())
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                quickOpenButtons(localPath: localPath)
            }

        case .rejectedNonFastForward:
            warningBox(tint: .orange, icon: "exclamationmark.triangle.fill", title: "Push Rejected") {
                Text("The remote branch has commits this workspace doesn't have yet. Pull first to bring them in - that may itself produce a conflict to resolve - then push again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RefreshButton("Pull Now") { Task { await pull() } }
            }

        case .uncommittedChanges:
            warningBox(tint: .orange, icon: "exclamationmark.triangle.fill", title: "Uncommitted Local Changes") {
                Text("This workspace has local changes that haven't been committed yet, so git stopped rather than risk overwriting them. Commit or stash those changes locally, then try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                quickOpenButtons(localPath: localPath)
            }

        case .nothingToPush:
            Label("Nothing to push.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .error:
            warningBox(tint: .red, icon: "xmark.circle.fill", title: "Something Went Wrong") {
                if !result.stderr.isEmpty {
                    Text(result.stderr)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(6)
                }
            }
        }
    }

    @ViewBuilder
    private func warningBox<Content: View>(tint: Color, icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.callout.bold())
                .foregroundStyle(tint)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.3)))
    }

    private func quickOpenButtons(localPath: String) -> some View {
        HStack(spacing: 12) {
            OpenButton("Open in Finder", systemImage: "folder") { openInFinder(localPath) }
            OpenButton("Open in Terminal", systemImage: "terminal") { openInTerminal(localPath) }
        }
        .controlSize(.small)
    }

    // MARK: - Actions

    private func loadStatus() async {
        statusState = .loading
        do {
            let status = try await api.getWorkspaceStatus(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName)
            statusState = .loaded(status)
        } catch {
            statusState = .failed(error.friendlyMessage)
        }
    }

    private func clone() async {
        guard let cloneUrlHttp else { return }
        guard let parentDirectory = pickCloneDestinationFolder() else { return }
        isCloning = true
        cloneError = nil
        do {
            let result = try await api.cloneWorkspace(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, cloneUrl: cloneUrlHttp, parentDirectory: parentDirectory)
            if result.outcome == .success {
                await loadStatus()
                onWorkspaceChanged()
            } else {
                cloneError = result.stderr.isEmpty ? "Clone failed." : result.stderr
            }
        } catch {
            cloneError = error.friendlyMessage
        }
        isCloning = false
    }

    private func match() async {
        guard let localPath = pickExistingFolder() else { return }
        isMatching = true
        cloneError = nil
        do {
            let result = try await api.matchWorkspace(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, cloneUrl: cloneUrlHttp, localPath: localPath)
            matchWarning = result.warning
            await loadStatus()
            onWorkspaceChanged()
        } catch {
            cloneError = error.friendlyMessage
        }
        isMatching = false
    }

    private func pull() async {
        isPulling = true
        lastResult = nil
        do {
            lastResult = try await api.pullWorkspace(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName)
            await loadStatus()
        } catch {
            lastResult = GitCommandResult(outcome: .error, stdout: "", stderr: error.friendlyMessage, conflictedFiles: [])
        }
        isPulling = false
    }

    private func push() async {
        isPushing = true
        lastResult = nil
        do {
            lastResult = try await api.pushWorkspace(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName)
            await loadStatus()
        } catch {
            lastResult = GitCommandResult(outcome: .error, stdout: "", stderr: error.friendlyMessage, conflictedFiles: [])
        }
        isPushing = false
    }

    private func merge() async {
        guard !mergeBranch.isEmpty else { return }
        isMerging = true
        lastResult = nil
        do {
            lastResult = try await api.mergeIntoWorkspace(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, branch: mergeBranch)
            await loadStatus()
        } catch {
            lastResult = GitCommandResult(outcome: .error, stdout: "", stderr: error.friendlyMessage, conflictedFiles: [])
        }
        isMerging = false
    }

    private func forget() async {
        do {
            try await api.forgetWorkspace(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName)
        } catch {
            // Best-effort - even if this particular call fails, reloading
            // status below will just show the same state as before, so
            // there's nothing destructive to roll back.
        }
        lastResult = nil
        await loadStatus()
        onWorkspaceChanged()
    }

    private func pickCloneDestinationFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to clone \"\(repositoryName)\" into"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func pickExistingFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Match"
        panel.message = "Choose the existing local clone of \"\(repositoryName)\""
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func openInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func openInTerminal(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", path]
        try? process.run()
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
