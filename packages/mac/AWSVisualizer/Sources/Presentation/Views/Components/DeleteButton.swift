import SwiftUI

/// The app's standard "Delete" action button - a thin, fixed-`.delete`
/// wrapper around the shared `AppButton` engine (color/style config lives
/// there, see `AppButton.swift`), broken out into its own type/file so
/// every delete action in the app is a single, greppable `DeleteButton`.
///
/// Unlike `EditButton`, this one isn't *just* styling: it always confirms
/// before running `action` - one consistent "are you sure"
/// (`AppLanguage.deleteConfirmationTitle/Message`, TR/EN) instead of each
/// call site wording (or forgetting) its own, and not configurable on
/// purpose - the point is that every delete in the app behaves the same
/// way. Owning the confirmation here (rather than `AppButton` special-
/// casing `kind == .delete`) keeps "what confirming means" with the one
/// kind that actually needs it, instead of leaking delete-specific
/// behavior into the shared styling engine.
struct DeleteButton: View {
    @Environment(AppState.self) private var appState

    var title: String?
    var systemImage: String?
    var showIcon: Bool = true
    var compactSize: CGFloat = 26
    var isLoading: Bool = false
    var isDisabled: Bool = false
    var help: String?
    /// Replaces the shared "This data will be deleted" text (e.g. to name what goes).
    var confirmationMessage: String?
    var action: () -> Void

    @State private var showConfirmation = false

    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        showIcon: Bool = true,
        compactSize: CGFloat = 26,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        help: String? = nil,
        confirmationMessage: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.showIcon = showIcon
        self.compactSize = compactSize
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.help = help
        self.confirmationMessage = confirmationMessage
        self.action = action
    }

    var body: some View {
        AppButton(
            title,
            kind: .delete,
            systemImage: systemImage,
            showIcon: showIcon,
            compactSize: compactSize,
            isLoading: isLoading,
            isDisabled: isDisabled,
            help: help
        ) {
            showConfirmation = true
        }
        .confirmationDialog(
            appState.language.deleteConfirmationTitle,
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button(appState.language.yesButtonTitle, role: .destructive) { action() }
            Button(appState.language.noButtonTitle, role: .cancel) {}
        } message: {
            Text(confirmationMessage ?? appState.language.deleteConfirmationMessage)
        }
    }
}
