import SwiftUI

/// The action row at the bottom of a list panel - New (+), Refresh and
/// the like on the left, an optional count / status on the right. Every
/// service list puts its actions here (the screen name lives in the window
/// title), the same place the DynamoDB Items grid keeps its + button.
struct PanelActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                leading()
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }
}

extension PanelActionBar where Trailing == EmptyView {
    init(@ViewBuilder leading: @escaping () -> Leading) {
        self.init(leading: leading, trailing: { EmptyView() })
    }
}
