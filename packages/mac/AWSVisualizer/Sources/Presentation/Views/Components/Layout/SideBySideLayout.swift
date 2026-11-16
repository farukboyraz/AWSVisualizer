import SwiftUI

/// List left, detail right, drag-resizable divider - the default layout
/// (see `MasterDetailView`).
struct SideBySideLayout<Master: View, Detail: View>: View {
    var initialWidth: CGFloat
    var minWidth: CGFloat
    var maxWidth: CGFloat
    @ViewBuilder var master: () -> Master
    @ViewBuilder var detail: () -> Detail

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ResizableSplitView(initialWidth: initialWidth, minWidth: minWidth, maxWidth: maxWidth) {
            master().listTierBackground(colorScheme)
        } right: {
            detail().detailTierBackground(colorScheme)
        }
    }
}
