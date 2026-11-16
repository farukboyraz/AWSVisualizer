import SwiftUI

/// One pull request comment thread: the root comment, its replies, a reply
/// box and per-comment delete. Shared by the PR Comments tab and the file
/// comments drawer under the Changes tab's diff, so both behave the same.
struct CodeCommitCommentThreadCard: View {
    let thread: CodeCommitCommentThread
    var isHighlighted: Bool = false
    let language: AppLanguage
    /// (root comment id, text) - posts a reply; the host reloads afterwards.
    let reply: (String, String) async throws -> Void
    let delete: (CodeCommitComment) async throws -> Void

    @State private var isReplying = false
    @State private var draft = ""
    @State private var isPosting = false
    @State private var deletingId: String?
    @State private var failure: String?
    @FocusState private var replyFocused: Bool

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(thread.comments.enumerated()), id: \.element.id) { index, comment in
                if index > 0 { Divider().padding(.leading, 12) }
                commentRow(comment)
            }

            if let root = thread.comments.first {
                if isReplying {
                    HStack(alignment: .top, spacing: 6) {
                        TextField(language.prReplyPlaceholder, text: $draft, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                            .focused($replyFocused)
                        NewButton(language.prReply, systemImage: "arrowshape.turn.up.left", isLoading: isPosting, isDisabled: trimmedDraft.isEmpty || isPosting) {
                            Task { await postReply(to: root.id) }
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        SecondaryButton(language.prCancel) {
                            isReplying = false
                            draft = ""
                        }
                    }
                    .padding([.horizontal, .bottom], 12)
                    .padding(.top, 4)
                    .onAppear { replyFocused = true }
                } else {
                    Button(language.prReply) { isReplying = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .padding([.horizontal, .bottom], 12)
                        .padding(.top, 2)
                }
            }

            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
                    .padding([.horizontal, .bottom], 12)
            }
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: isHighlighted ? 1.5 : 0))
    }

    private func commentRow(_ comment: CodeCommitComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(.secondary)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(author(comment.authorArn))
                        .font(.caption.bold())
                    Text(Formatters.formatDate(comment.creationDate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if comment.deleted != true {
                        DeleteButton(compactSize: 20, isLoading: deletingId == comment.id, isDisabled: deletingId != nil, help: language.prDeleteComment) {
                            Task { await remove(comment) }
                        }
                    }
                }
                Text(comment.deleted == true ? language.prDeleted : comment.content)
                    .font(.callout)
                    .foregroundStyle(comment.deleted == true ? .secondary : .primary)
                    .italic(comment.deleted == true)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    private func author(_ arn: String?) -> String {
        guard let arn else { return language.prUnknownAuthor }
        return arn.split(separator: "/").last.map(String.init) ?? arn
    }

    private func postReply(to rootId: String) async {
        guard !trimmedDraft.isEmpty else { return }
        isPosting = true
        failure = nil
        do {
            try await reply(rootId, trimmedDraft)
            draft = ""
            isReplying = false
        } catch {
            failure = error.friendlyMessage
        }
        isPosting = false
    }

    private func remove(_ comment: CodeCommitComment) async {
        deletingId = comment.id
        failure = nil
        do {
            try await delete(comment)
        } catch {
            failure = error.friendlyMessage
        }
        deletingId = nil
    }
}
