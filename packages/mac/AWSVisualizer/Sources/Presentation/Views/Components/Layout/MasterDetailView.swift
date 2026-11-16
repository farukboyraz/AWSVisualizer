import SwiftUI

/// The base of every list + detail screen. A screen hands over its two
/// parts - the list (`master`) and what's selected (`detail`) - and this
/// picks the arrangement from Settings → Layout:
/// - `SideBySideLayout`: both at once, resizable divider (default).
/// - `SinglePageLayout`: the list fills the window; with something
///   selected the detail replaces it, and Back (⌘[) returns to the list.
/// Screens themselves never branch on the layout mode.
struct MasterDetailView<Master: View, Detail: View>: View {
    var initialWidth: CGFloat
    var minWidth: CGFloat = 160
    var maxWidth: CGFloat = 600
    /// Something is selected - single page shows the detail instead of the list.
    var isDetailActive: Bool
    /// Back in single page: the screen clears its selection.
    var onBack: () -> Void
    /// What Back returns to ("Tables", "Buckets"…).
    var backTitle: String
    /// The selected item's name for the path row (`‹  Tables / Orders`).
    var detailTitle: String? = nil
    /// Screens with their own path row (S3) turn the single-page one off.
    var showsBackBar = true
    @ViewBuilder var master: () -> Master
    @ViewBuilder var detail: () -> Detail

    @Environment(\.layoutMode) private var layoutMode

    var body: some View {
        switch layoutMode {
        case .sideBySide:
            SideBySideLayout(initialWidth: initialWidth, minWidth: minWidth, maxWidth: maxWidth, master: master, detail: detail)
        case .singlePage:
            SinglePageLayout(isDetailActive: isDetailActive, onBack: onBack, backTitle: backTitle, detailTitle: detailTitle, showsBackBar: showsBackBar, master: master, detail: detail)
        }
    }
}
