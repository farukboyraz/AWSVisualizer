import SwiftUI

/// The window's three background tiers, darkest on the left:
///
/// | Tier            | Dark mode          | Light mode        |
/// |-----------------|--------------------|-------------------|
/// | Sidebar         | black              | gray              |
/// | List (master)   | lighter black      | light gray        |
/// | Detail / pages  | dark gray          | lighter gray      |
///
/// `SideBySideLayout` / `SinglePageLayout` paint the list and detail tiers,
/// so every service screen (all built on `MasterDetailView`) follows it.
enum Theme {
    static func sidebarBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.035) : Color(white: 0.80)
    }

    /// A step lighter than `sidebarBackground` - the sidebar's internal
    /// panels (header, service list, footer) on the darkest outer frame.
    static func sidebarPanelBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.065) : Color(white: 0.835)
    }

    static func tabBarBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.09) : Color(white: 0.865)
    }

    /// The list column of a list + detail screen.
    static func listBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.115) : Color(white: 0.895)
    }

    /// Detail panes and full pages (Dashboard, single-page details).
    static func detailBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.175) : Color(white: 0.955)
    }

    /// Area behind every screen; same tier as the detail.
    static func contentBackground(_ scheme: ColorScheme) -> Color {
        detailBackground(scheme)
    }
}

extension View {
    /// Paints the list tier; Lists inside drop their own system background.
    func listTierBackground(_ scheme: ColorScheme) -> some View {
        scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.listBackground(scheme))
    }

    func detailTierBackground(_ scheme: ColorScheme) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.detailBackground(scheme))
    }
}
