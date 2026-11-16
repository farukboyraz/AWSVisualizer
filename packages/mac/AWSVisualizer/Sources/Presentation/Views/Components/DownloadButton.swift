import SwiftUI

/// The app's standard "Download" action button - a thin, fixed-`.download`
/// wrapper around the shared `AppButton` engine (color/style config lives
/// there, see `AppButton.swift`), broken out into its own type/file for the
/// same reason as `EditButton`/`DeleteButton`/etc. **Icon-only by design**
/// (no `title` parameter at all, unlike the other typed buttons) - matches
/// `OpenButton`'s reasoning: a download glyph reads on its own wherever
/// this is used (e.g. Lambda's Code tab, next to `OpenInIDEControl`).
struct DownloadButton: View {
    /// Optional label - icon-only (the original Lambda Code-tab use) when nil.
    var title: String?
    var systemImage: String?
    var compactSize: CGFloat = 26
    var isLoading: Bool = false
    var isDisabled: Bool = false
    var help: String?
    var action: () -> Void

    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        compactSize: CGFloat = 26,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.compactSize = compactSize
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.help = help
        self.action = action
    }

    var body: some View {
        AppButton(
            title,
            kind: .download,
            systemImage: systemImage,
            compactSize: compactSize,
            isLoading: isLoading,
            isDisabled: isDisabled,
            help: help,
            action: action
        )
    }
}
