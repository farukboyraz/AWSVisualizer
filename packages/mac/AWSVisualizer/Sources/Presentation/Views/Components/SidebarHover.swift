import SwiftUI

extension View {
    /// A light tint behind a sidebar row while the pointer is over it, so
    /// it's clear which row a click opens. Same shape as the selection
    /// highlight: the row's full width and height (a sidebar row is ~28 pt,
    /// the label ~17 pt, so the tint reaches past the label on every side;
    /// the cell clips whatever goes beyond the row). The selection keeps its
    /// own color. `inset: 0` = exactly the view's own frame (collapsed icons).
    func sidebarHover(cornerRadius: CGFloat = 8, inset: CGFloat = 8) -> some View {
        modifier(SidebarHoverHighlight(cornerRadius: cornerRadius, inset: inset))
    }
}

private struct SidebarHoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    /// How far the tint reaches past the label on the left and right.
    let inset: CGFloat

    @State private var isHovering = false

    /// Up and down: enough to fill a sidebar row's height.
    private var verticalInset: CGFloat { inset > 0 ? 6 : 0 }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: inset > 0 ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.vertical, verticalInset)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .padding(.horizontal, -inset)
            .padding(.vertical, -verticalInset)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
