import SwiftUI

/// Pull request discussion - general comments plus every file-scoped
/// ("inline") thread in one list. AWS's inline comments are anchored to a
/// diff line via `Location` (file path + file position + before/after
/// side). The Changes tab is the main place for those (click a line number
/// in the diff, `CodeCommitFileComments`); this composer can still pick a
/// file and line by hand. Threads are drawn by `CodeCommitCommentThreadCard`
/// in both places.
struct CodeCommitPullRequestCommentsView: View {
    let repositoryName: String
    let pullRequest: CodeCommitPullRequest

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var threadsState: LoadState<[CodeCommitCommentThread]> = .loading
    @State private var changedFiles: [String] = []

    @State private var newComment = ""
    @State private var newCommentFilePath: String = ""
    @State private var newCommentLine = ""
    @State private var isPosting = false
    @State private var postError: String?

    private var beforeCommitId: String? { pullRequest.destinationCommit }
    private var afterCommitId: String? { pullRequest.sourceCommit }

    private var generalThreads: [CodeCommitCommentThread] {
        threads.filter { $0.location?.filePath == nil }
    }

    private var fileThreads: [String: [CodeCommitCommentThread]] {
        Dictionary(grouping: threads.filter { $0.location?.filePath != nil }) { $0.location!.filePath! }
    }

    private var threads: [CodeCommitCommentThread] {
        if case .loaded(let threads) = threadsState { return threads }
        return []
    }

    var body: some View {
        VStack(spacing: 0) {
            LoadableContent(threadsState, retry: { Task { await load() } }) { _ in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if threads.isEmpty {
                            EmptyStateView(message: "No comments yet - start the discussion below")
                                .padding(.top, 40)
                                .frame(maxWidth: .infinity)
                        }

                        if !generalThreads.isEmpty {
                            sectionHeader("General Discussion")
                            ForEach(generalThreads) { thread in
                                threadCard(thread)
                            }
                        }

                        ForEach(fileThreads.keys.sorted(), id: \.self) { path in
                            sectionHeader(path)
                            ForEach(fileThreads[path] ?? []) { thread in
                                threadCard(thread)
                            }
                        }
                    }
                    .padding()
                }
            }

            Divider()
            composer
        }
        .task {
            await load()
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.bold().monospaced())
            .foregroundStyle(.secondary)
    }

    private func threadCard(_ thread: CodeCommitCommentThread) -> some View {
        CodeCommitCommentThreadCard(
            thread: thread,
            language: appState.language,
            reply: { rootId, text in
                _ = try await api.postCodeCommitCommentReply(profile: appState.currentProfile, region: appState.currentRegion, inReplyTo: rootId, content: text)
                await load()
            },
            delete: { comment in
                try await api.deleteCodeCommitComment(profile: appState.currentProfile, region: appState.currentRegion, commentId: comment.commentId)
                await load()
            }
        )
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !changedFiles.isEmpty {
                HStack {
                    Picker("File", selection: $newCommentFilePath) {
                        Text("General comment").tag("")
                        ForEach(changedFiles, id: \.self) { path in
                            Text(path).tag(path)
                        }
                    }
                    .frame(maxWidth: 320)
                    if !newCommentFilePath.isEmpty {
                        TextField("Line #", text: $newCommentLine)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    Spacer()
                }
            }
            HStack(alignment: .top) {
                TextField("Leave a comment…", text: $newComment, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                NewButton("Comment", isLoading: isPosting, isDisabled: newComment.trimmingCharacters(in: .whitespaces).isEmpty || beforeCommitId == nil || afterCommitId == nil) {
                    Task { await postComment() }
                }
            }
            if let postError {
                Text(postError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
    }

    private func load() async {
        threadsState = .loading
        do {
            let threads = try await api.getCodeCommitPullRequestComments(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                pullRequestId: pullRequest.pullRequestId,
                repositoryName: repositoryName,
                beforeCommitId: beforeCommitId,
                afterCommitId: afterCommitId
            )
            threadsState = .loaded(threads)
        } catch {
            threadsState = .failed(error.friendlyMessage)
        }

        if let before = beforeCommitId, let after = afterCommitId {
            if let entries = try? await api.getCodeCommitDifferences(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, before: before, after: after) {
                changedFiles = entries.map(\.path).sorted()
            }
        }
    }

    private func postComment() async {
        guard let before = beforeCommitId, let after = afterCommitId else { return }
        isPosting = true
        postError = nil
        do {
            _ = try await api.postCodeCommitPullRequestComment(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                pullRequestId: pullRequest.pullRequestId,
                repositoryName: repositoryName,
                beforeCommitId: before,
                afterCommitId: after,
                content: newComment.trimmingCharacters(in: .whitespaces),
                filePath: newCommentFilePath.isEmpty ? nil : newCommentFilePath,
                filePosition: Int(newCommentLine),
                relativeFileVersion: newCommentFilePath.isEmpty ? nil : "AFTER"
            )
            newComment = ""
            newCommentLine = ""
            await load()
        } catch {
            postError = error.friendlyMessage
        }
        isPosting = false
    }
}

/// The PR's `DescribePullRequestEvents` history - a flat, read-only
/// timeline (creation, source updates, status changes, merges) same idea
/// as the AWS console's "Activity" tab.
struct CodeCommitPullRequestActivityView: View {
    let pullRequestId: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var eventsState: LoadState<[CodeCommitPullRequestEvent]> = .loading

    var body: some View {
        LoadableContent(eventsState, retry: { Task { await load() } }, emptyMessage: "No activity recorded") { events in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(events) { event in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon(for: event.eventType))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label(for: event.eventType))
                                    .font(.callout.bold())
                                HStack(spacing: 6) {
                                    if let actor = event.actorArn {
                                        Text(actor.split(separator: "/").last.map(String.init) ?? actor)
                                    }
                                    Text(Formatters.formatDate(event.eventDate))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        Divider()
                    }
                }
                .padding()
            }
        }
        .task {
            await load()
        }
    }

    private func label(for eventType: String?) -> String {
        switch eventType {
        case "PULL_REQUEST_CREATED": return "Pull request created"
        case "PULL_REQUEST_STATUS_CHANGED": return "Status changed"
        case "PULL_REQUEST_SOURCE_REFERENCE_UPDATED": return "Source branch updated"
        case "PULL_REQUEST_MERGE_STATE_CHANGED": return "Merge state changed"
        case "PULL_REQUEST_APPROVAL_RULE_CREATED", "PULL_REQUEST_APPROVAL_RULE_UPDATED", "PULL_REQUEST_APPROVAL_RULE_DELETED", "PULL_REQUEST_APPROVAL_RULE_OVERRIDDEN":
            return "Approval rule changed"
        case "PULL_REQUEST_APPROVAL_STATE_CHANGED": return "Approval state changed"
        default: return eventType?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Event"
        }
    }

    private func icon(for eventType: String?) -> String {
        switch eventType {
        case "PULL_REQUEST_CREATED": return "plus.circle"
        case "PULL_REQUEST_STATUS_CHANGED": return "arrow.triangle.2.circlepath"
        case "PULL_REQUEST_SOURCE_REFERENCE_UPDATED": return "arrow.up.circle"
        case "PULL_REQUEST_MERGE_STATE_CHANGED": return "arrow.triangle.merge"
        case "PULL_REQUEST_APPROVAL_STATE_CHANGED": return "checkmark.seal"
        default: return "circle"
        }
    }

    private func load() async {
        eventsState = .loading
        do {
            let events = try await api.getCodeCommitPullRequestEvents(profile: appState.currentProfile, region: appState.currentRegion, pullRequestId: pullRequestId)
            eventsState = events.isEmpty ? .empty : .loaded(events)
        } catch {
            eventsState = .failed(error.friendlyMessage)
        }
    }
}
