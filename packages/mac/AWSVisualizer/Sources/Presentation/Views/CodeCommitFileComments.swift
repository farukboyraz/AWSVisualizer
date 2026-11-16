import SwiftUI

/// The expandable comments drawer under a pull request file's diff (the
/// Changes tab). Lists the file's threads - line comments sorted by line,
/// whole-file comments first, outdated ones (written on an older source
/// commit) last - and has the composer. The target line comes from a click
/// on a diff line number (`FileDiffContentView.onLineTap`); with no line
/// the comment is on the whole file. Same AWS call as the Comments tab
/// (`PostCommentForPullRequest` with a `location`).
struct CodeCommitFileComments: View {
    let repositoryName: String
    let pullRequest: CodeCommitPullRequest
    let path: String
    /// Every thread on this file, any revision.
    let threads: [CodeCommitCommentThread]
    let loadError: String?
    @Binding var target: DiffLineRef?
    @Binding var isExpanded: Bool
    /// The line last clicked in the diff - its threads are highlighted.
    let focus: DiffLineRef?
    /// Bumped on every line click, to scroll there and focus the composer.
    let focusToken: Int
    let reload: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var draft = ""
    @State private var isPosting = false
    @State private var postError: String?
    @FocusState private var composerFocused: Bool

    private var language: AppLanguage { appState.language }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func isOutdated(_ thread: CodeCommitCommentThread) -> Bool {
        guard let after = thread.afterCommitId, let source = pullRequest.sourceCommit else { return false }
        return after != source
    }

    /// Whole-file first, then by line (new side before old on the same number), outdated last.
    private var sortedThreads: [CodeCommitCommentThread] {
        threads.sorted { a, b in
            let ao = isOutdated(a), bo = isOutdated(b)
            if ao != bo { return !ao }
            let al = a.lineRef?.line ?? 0, bl = b.lineRef?.line ?? 0
            if al != bl { return al < bl }
            return (a.lineRef?.side == .after ? 0 : 1) < (b.lineRef?.side == .after ? 0 : 1)
        }
    }

    private var currentCount: Int { threads.filter { !isOutdated($0) }.count }
    private var outdatedCount: Int { threads.count - currentCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            header
            if isExpanded {
                Divider()
                threadList
                Divider()
                composer
            }
        }
        .background(Color.primary.opacity(0.02))
        .onChange(of: focusToken) { _, _ in composerFocused = true }
        .onChange(of: path) { _, _ in
            draft = ""
            postError = nil
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "text.bubble")
                    Text(language.prComments).font(.callout.weight(.semibold))
                    if currentCount > 0 {
                        Text("\(currentCount)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                    if outdatedCount > 0 {
                        Text("· \(outdatedCount) \(language.prOutdated.lowercased())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let loadError {
                Label(language.prCommentsLoadFailed, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(loadError)
            }
            Spacer()
            if !isExpanded {
                NewButton(language.prAddComment, systemImage: "plus.bubble") {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded = true }
                    composerFocused = true
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var threadList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if threads.isEmpty {
                        Text(language.prNoFileComments)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(sortedThreads) { thread in
                        VStack(alignment: .leading, spacing: 4) {
                            threadLabel(thread)
                            CodeCommitCommentThreadCard(
                                thread: thread,
                                isHighlighted: focus != nil && thread.lineRef == focus && !isOutdated(thread),
                                language: language,
                                reply: { rootId, text in
                                    _ = try await api.postCodeCommitCommentReply(profile: appState.currentProfile, region: appState.currentRegion, inReplyTo: rootId, content: text)
                                    await reload()
                                },
                                delete: { comment in
                                    try await api.deleteCodeCommitComment(profile: appState.currentProfile, region: appState.currentRegion, commentId: comment.commentId)
                                    await reload()
                                }
                            )
                            .opacity(isOutdated(thread) ? 0.75 : 1)
                        }
                        .id(thread.id)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: focusToken) { _, _ in
                guard let focus, let match = sortedThreads.first(where: { $0.lineRef == focus && !isOutdated($0) }) else { return }
                withAnimation { proxy.scrollTo(match.id, anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private func threadLabel(_ thread: CodeCommitCommentThread) -> some View {
        HStack(spacing: 6) {
            if let ref = thread.lineRef {
                Button {
                    target = ref
                    composerFocused = true
                } label: {
                    Label(language.prLine(ref), systemImage: "number")
                }
                .buttonStyle(.plain)
                .help(language.prCommentGutterHelp)
            } else {
                Label(language.prWholeFile, systemImage: "doc.text")
            }
            if isOutdated(thread) {
                Text(language.prOutdated)
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.2), in: Capsule())
                    .help(language.prOutdatedHelp)
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: target == nil ? "doc.text" : "number")
                Text(target.map(language.prLine) ?? language.prWholeFile)
                if target != nil {
                    ClearButton(compactSize: 18, help: language.prCommentTargetHelp) { target = nil }
                }
                Spacer()
                Text(path).lineLimit(1).truncationMode(.head)
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 8) {
                TextField(language.prCommentPlaceholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                    .focused($composerFocused)
                NewButton(language.prCommentButton, systemImage: "text.bubble", isLoading: isPosting, isDisabled: !canPost) {
                    Task { await post() }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
            if let postError {
                Text(postError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    private var canPost: Bool {
        !trimmedDraft.isEmpty && !isPosting && pullRequest.destinationCommit != nil && pullRequest.sourceCommit != nil
    }

    private func post() async {
        guard canPost, let before = pullRequest.destinationCommit, let after = pullRequest.sourceCommit else { return }
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
                content: trimmedDraft,
                filePath: path,
                filePosition: target?.line,
                relativeFileVersion: target?.side.rawValue
            )
            draft = ""
            target = nil
            await reload()
        } catch {
            postError = error.friendlyMessage
        }
        isPosting = false
    }
}
