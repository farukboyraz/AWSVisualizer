import SwiftUI
import AppKit

/// Makes the sheet a view sits in resizable by dragging its edges (macOS
/// sheets aren't by default), with a minimum size. Used by the big
/// popups - commit changes, pull request, history, fullscreen preview.
private struct ResizableSheetConfigurator: NSViewRepresentable {
    let minSize: NSSize

    func makeNSView(context: Context) -> NSView { WindowHookView(minSize: minSize) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowHookView: NSView {
        let minSize: NSSize
        init(minSize: NSSize) {
            self.minSize = minSize
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.sheetParent != nil else { return }
            window.styleMask.insert(.resizable)
            window.minSize = minSize
        }
    }
}

extension View {
    /// Edge-draggable sheet, never smaller than the given size.
    func resizableSheet(minWidth: CGFloat = 720, minHeight: CGFloat = 480) -> some View {
        background(ResizableSheetConfigurator(minSize: NSSize(width: minWidth, height: minHeight)))
    }
}

/// Toggles the sheet between nearly the whole parent window and the size
/// it had before - for when dragging the edges is too slow (side-by-side
/// diffs need the room).
struct SheetMaximizeButton: View {
    @State private var window: NSWindow?
    @State private var restoreSize: NSSize?

    var body: some View {
        Button {
            toggle()
        } label: {
            Image(systemName: restoreSize == nil ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(restoreSize == nil ? "Fill the window" : "Restore size")
        .background(WindowFinder(window: $window))
    }

    private func toggle() {
        guard let window else { return }
        if let restoreSize {
            window.setContentSize(restoreSize)
            self.restoreSize = nil
        } else if let parent = window.sheetParent {
            restoreSize = window.contentLayoutRect.size
            let available = parent.contentLayoutRect.size
            window.setContentSize(NSSize(width: max(available.width - 24, window.minSize.width), height: max(available.height - 12, window.minSize.height)))
        }
    }
}

private struct WindowFinder: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window == nil { DispatchQueue.main.async { window = nsView.window } }
    }
}
