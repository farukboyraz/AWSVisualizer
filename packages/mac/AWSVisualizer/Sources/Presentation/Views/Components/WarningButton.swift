import SwiftUI

/// The app's "Warning" button - a thin, fixed-`.warning` wrapper around the
/// shared `AppButton` engine (color/style live there and in Settings ->
/// Button Colors). Operational actions that disturb something running but don't delete data - stop/reboot an instance, stop a task, force a redeploy, cancel a rotation. Usually wrapped in `ConfirmedActionButton` for the "are you sure".
struct WarningButton: View {
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
            kind: .warning,
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
