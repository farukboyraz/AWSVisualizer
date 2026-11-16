import SwiftUI
import AppKit

struct ResizableSplitView<Left: View, Right: View>: View {
    @State private var width: CGFloat
    @State private var dragStartWidth: CGFloat?

    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    /// Hides the left panel (and the divider) without rebuilding either
    /// side, so the right one keeps its state - e.g. a diff's file list.
    private let leftHidden: Bool
    private let left: Left
    private let right: Right

    init(
        initialWidth: CGFloat,
        minWidth: CGFloat = 160,
        maxWidth: CGFloat = 600,
        leftHidden: Bool = false,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) {
        _width = State(initialValue: initialWidth)
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.leftHidden = leftHidden
        self.left = left()
        self.right = right()
    }

    var body: some View {
        HStack(spacing: 0) {
            left
                .frame(width: leftHidden ? 0 : width)
                .opacity(leftHidden ? 0 : 1)
                .clipped()
            if !leftHidden { divider }
            right
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var divider: some View {
        Divider()
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        // `.global` coordinate space - the default `.local`
                        // measures translation relative to this divider's
                        // own frame, which moves as `width` changes (the
                        // very thing the drag controls), causing erratic
                        // jitter/stuck-at-a-bound behavior (see
                        // `DataGridColumnResizeHandle`'s doc comment in
                        // DataGridView.swift for the full story).
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = dragStartWidth ?? width
                                if dragStartWidth == nil { dragStartWidth = width }
                                width = min(max(base + value.translation.width, minWidth), maxWidth)
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                            }
                    )
            )
    }
}
