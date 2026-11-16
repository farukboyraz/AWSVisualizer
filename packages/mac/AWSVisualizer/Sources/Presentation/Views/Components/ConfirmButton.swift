import SwiftUI

/// The app's standard "Approve / Confirm" action button - a thin, fixed-
/// `.confirm` wrapper around the shared `AppButton` engine (color/style
/// config lives there, see `AppButton.swift`), broken out into its own
/// type/file for the same reason as `EditButton`/`DeleteButton`/
/// `SaveButton`/`NewButton`. Covers "positive confirmation" actions
/// (approve, merge, rotate-now, enable-rotation, restore-secret, ...).
struct ConfirmButton: View {
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
            kind: .confirm,
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
