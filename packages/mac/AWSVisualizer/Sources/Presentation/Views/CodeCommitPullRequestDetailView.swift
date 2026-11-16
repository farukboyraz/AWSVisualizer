import SwiftUI

/// A pull request's detail popup - header (state, approve/merge/close
/// actions), and a tabbed bottom section: Changes (the diff, same as the
/// AWS console's PR "Changes" tab), Comments (general + file-scoped
/// discussion), and Activity (the event timeline).
struct CodeCommitPullRequestDetailView: View {
    let repositoryName: String
    let pullRequestId: String
    var onChanged: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    private enum BottomTab: String, CaseIterable {
        case changes = "Changes"
        case comments = "Comments"
        case activity = "Activity"
    }

    @State private var prState: LoadState<CodeCommitPullRequest> = .loading
    @State private var showMergePanel = false
    @State private var isClosingPR = false
    @State private var closeError: String?
    @State private var bottomTab: BottomTab = .changes

    @State private var isApproving = false
    @State private var approvalError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(prState, retry: { Task { await loadPullRequest() } }) { pr in
                content(pr)
            }
        }
        .frame(minWidth: 860, idealWidth: 1400, maxWidth: .infinity, minHeight: 560, idealHeight: 900, maxHeight: .infinity)
        .resizableSheet(minWidth: 860, minHeight: 560)
        .task {
            await loadPullRequest()
        }
    }

    @ViewBuilder
    private func content(_ pr: CodeCommitPullRequest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(pr)

            if showMergePanel, pr.status == "OPEN", pr.isMerged != true {
                Divider()
                MergePanel(
                    repositoryName: repositoryName,
                    pullRequest: pr,
                    onCancel: { showMergePanel = false },
                    onMerged: {
                        onChanged()
                        dismiss()
                    }
                )
            }

            Divider()

            TabBar(selection: $bottomTab)
            .padding(.bottom, 8)

            Group {
                switch bottomTab {
                case .changes:
                    CodeCommitDiffPane(repositoryName: repositoryName, before: pr.mergeBase ?? pr.destinationCommit, after: pr.sourceCommit ?? pr.sourceReference ?? "", pullRequest: pr)
                case .comments:
                    CodeCommitPullRequestCommentsView(repositoryName: repositoryName, pullRequest: pr)
                case .activity:
                    CodeCommitPullRequestActivityView(pullRequestId: pullRequestId)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func header(_ pr: CodeCommitPullRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pr.title)
                        .font(.title3.bold())
                    if let source = pr.sourceReference, let destination = pr.destinationReference {
                        Text("\(source) → \(destination)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                StatusBadge(pr.isMerged == true ? "MERGED" : pr.status, color: pr.isMerged == true ? .purple : nil)
                SheetMaximizeButton()
                SecondaryButton("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if let description = pr.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if pr.isMerged == true {
                Label("Merged" + (pr.mergedBy.map { " by \($0)" } ?? ""), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
            } else if pr.status == "OPEN" {
                HStack {
                    if let revisionId = pr.revisionId {
                        ConfirmButton("Approve", isLoading: isApproving, isDisabled: isApproving) {
                            Task { await setApproval(revisionId: revisionId, approved: true) }
                        }

                        Button {
                            Task { await setApproval(revisionId: revisionId, approved: false) }
                        } label: {
                            Text("Revoke Approval")
                        }
                        .disabled(isApproving)
                    }

                    ConfirmButton(showMergePanel ? "Cancel Merge" : "Merge Pull Request", systemImage: "arrow.triangle.merge") {
                        showMergePanel.toggle()
                    }

                    DeleteButton("Close Pull Request", isLoading: isClosingPR, isDisabled: isClosingPR) {
                        Task { await closePullRequest() }
                    }
                }

                if let closeError {
                    Text(closeError).font(.caption).foregroundStyle(.red)
                }
                if let approvalError {
                    Text(approvalError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding()
    }

    private func setApproval(revisionId: String, approved: Bool) async {
        isApproving = true
        approvalError = nil
        do {
            try await api.setCodeCommitPullRequestApproval(profile: appState.currentProfile, region: appState.currentRegion, pullRequestId: pullRequestId, revisionId: revisionId, approved: approved)
        } catch {
            approvalError = error.friendlyMessage
        }
        isApproving = false
    }

    private func closePullRequest() async {
        isClosingPR = true
        closeError = nil
        do {
            _ = try await api.closeCodeCommitPullRequest(profile: appState.currentProfile, region: appState.currentRegion, pullRequestId: pullRequestId)
            onChanged()
            dismiss()
        } catch {
            closeError = error.friendlyMessage
        }
        isClosingPR = false
    }

    private func loadPullRequest() async {
        prState = .loading
        do {
            let pr = try await api.getCodeCommitPullRequest(profile: appState.currentProfile, region: appState.currentRegion, id: pullRequestId)
            prState = .loaded(pr)
        } catch {
            prState = .failed(error.friendlyMessage)
        }
    }
}

/// Inline merge confirmation - strategy, live mergeability check, and the
/// actual merge action. Kept inline (not a nested sheet) so the diff below
/// it stays visible the whole time, matching what was asked for: the
/// changes should still be showing once you've clicked "Merge".
private struct MergePanel: View {
    let repositoryName: String
    let pullRequest: CodeCommitPullRequest
    var onCancel: () -> Void
    var onMerged: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var mergeOption: CodeCommitMergeOption = .fastForward
    @State private var checkState: LoadState<CodeCommitMergeCheck> = .loading
    @State private var commitMessage = ""
    @State private var isMerging = false
    @State private var mergeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge Pull Request")
                .font(.headline)

            Picker("Strategy", selection: $mergeOption) {
                ForEach(CodeCommitMergeOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 480)

            if mergeOption != .fastForward {
                TextField("Commit message (optional)", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 480)
            }

            mergeabilityView

            if let mergeError {
                Text(mergeError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                SecondaryButton("Cancel", action: onCancel)
                Spacer()
                ConfirmButton("Confirm Merge", isLoading: isMerging, isDisabled: !isMergeable) {
                    Task { await merge() }
                }
            }
            .frame(maxWidth: 480)
        }
        .padding()
        .task(id: mergeOption) {
            await checkMergeability()
        }
    }

    private var isMergeable: Bool {
        if case .loaded(let check) = checkState { return check.mergeable }
        return false
    }

    @ViewBuilder
    private var mergeabilityView: some View {
        switch checkState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking whether this can be merged…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loaded(let check):
            if check.mergeable {
                Label("This branch can be merged automatically.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("This branch has conflicts that must be resolved.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if !check.conflictedFilePaths.isEmpty {
                        Text(check.conflictedFilePaths.prefix(10).joined(separator: ", "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        case .empty, .failed:
            EmptyView()
        }
    }

    private func checkMergeability() async {
        checkState = .loading
        guard let destination = pullRequest.destinationCommit, let source = pullRequest.sourceCommit else {
            checkState = .failed("Missing source/destination commit")
            return
        }
        do {
            let check = try await api.checkCodeCommitMergeConflicts(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                name: repositoryName,
                destination: destination,
                source: source,
                mergeOption: mergeOption
            )
            checkState = .loaded(check)
        } catch {
            checkState = .failed(error.friendlyMessage)
        }
    }

    private func merge() async {
        isMerging = true
        mergeError = nil
        do {
            _ = try await api.mergeCodeCommitPullRequest(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                repositoryName: repositoryName,
                pullRequestId: pullRequest.pullRequestId,
                mergeOption: mergeOption,
                commitMessage: commitMessage.isEmpty ? nil : commitMessage
            )
            onMerged()
        } catch {
            mergeError = error.friendlyMessage
        }
        isMerging = false
    }
}
