import SwiftUI

/// The app's standard "New / Create" action button - a thin, fixed-
/// `.newItem` wrapper around the shared `AppButton` engine (color/style
/// config lives there, see `AppButton.swift`), broken out into its own
/// type/file for the same reason as `EditButton`/`DeleteButton`/
/// `SaveButton`. Named `NewButton` (not `NewItemButton`) since it covers
/// every "New X"/"Create X" action in the app (New Item, New Repository,
/// Create Branch, ...), not just DynamoDB's specific "New Item".
struct NewButton: View {
    var title: String?
    var systemImage: String?
    var showIcon: Bool = true
    var compactSize: CGFloat = 26
    var isLoading: Bool = false
    var isDisabled: Bool = false
    var help: String?
    var action: () -> Void

    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        showIcon: Bool = true,
        compactSize: CGFloat = 26,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.showIcon = showIcon
        self.compactSize = compactSize
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.help = help
        self.action = action
    }

    var body: some View {
        AppButton(
            title,
            kind: .newItem,
            systemImage: systemImage,
            showIcon: showIcon,
            compactSize: compactSize,
            isLoading: isLoading,
            isDisabled: isDisabled,
            help: help,
            action: action
        )
    }
}
