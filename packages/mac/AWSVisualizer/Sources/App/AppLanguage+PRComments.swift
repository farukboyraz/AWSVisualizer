import Foundation

/// Text of the pull request file comments in the Changes tab.
extension AppLanguage {
    var prCommentGutterHelp: String { self == .tr ? "Bu satıra yorum eklemek için tıklayın" : "Click to comment on this line" }
    var prComments: String { self == .tr ? "Yorumlar" : "Comments" }
    var prAddComment: String { self == .tr ? "Yorum ekle" : "Add comment" }
    var prCommentButton: String { self == .tr ? "Yorumla" : "Comment" }
    var prCommentPlaceholder: String { self == .tr ? "Yorumunuzu yazın… (⌘↩ gönderir)" : "Write a comment… (⌘↩ to post)" }
    var prReplyPlaceholder: String { self == .tr ? "Yanıt yazın…" : "Write a reply…" }
    var prReply: String { self == .tr ? "Yanıtla" : "Reply" }
    var prCancel: String { self == .tr ? "Vazgeç" : "Cancel" }
    var prDeleteComment: String { self == .tr ? "Yorumu sil" : "Delete comment" }
    var prDeleted: String { self == .tr ? "[silindi]" : "[deleted]" }
    var prWholeFile: String { self == .tr ? "Dosyanın tamamı" : "Whole file" }
    var prNoFileComments: String {
        self == .tr ? "Bu dosyada yorum yok. Bir satır numarasına tıklayın ya da dosyanın tamamına yorum yazın."
                    : "No comments on this file. Click a line number, or comment on the whole file."
    }
    var prOutdated: String { self == .tr ? "Eski sürüm" : "Outdated" }
    var prOutdatedHelp: String {
        self == .tr ? "Kaynak dal güncellenmeden önce yazıldı; satır numarası artık farklı olabilir."
                    : "Written before the source branch was updated; the line may have moved."
    }
    var prCommentTargetHelp: String { self == .tr ? "Dosyanın tamamına yorum yap" : "Comment on the whole file instead" }
    var prCommentsLoadFailed: String { self == .tr ? "Yorumlar yüklenemedi" : "Couldn't load comments" }
    var prUnknownAuthor: String { self == .tr ? "Bilinmiyor" : "Unknown" }

    func prLine(_ ref: DiffLineRef) -> String {
        switch (ref.side, self) {
        case (.after, .tr): "Satır \(ref.line) · yeni"
        case (.before, .tr): "Satır \(ref.line) · eski"
        case (.after, _): "Line \(ref.line) · new"
        case (.before, _): "Line \(ref.line) · old"
        }
    }

    func prCommentCount(_ n: Int) -> String {
        self == .tr ? "\(n) yorum" : (n == 1 ? "1 comment" : "\(n) comments")
    }
}
