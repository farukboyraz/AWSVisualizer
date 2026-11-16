import SwiftUI
import AppKit

/// Read-only selectable text (formatted JSON / XML / plain values). Wraps
/// long lines or scrolls sideways per View → Word Wrap (`\.wordWrap`).
struct SelectableTextView: NSViewRepresentable {
    let attributedString: NSAttributedString

    final class Coordinator { var lastWrap: Bool? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        scrollView.autohidesScrollers = true
        textView.textStorage?.setAttributedString(attributedString)
        let wrap = context.environment.wordWrap
        DispatchQueue.main.async { scrollView.applyWordWrap(wrap) }
        context.coordinator.lastWrap = wrap
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.textStorage?.string != attributedString.string {
            textView.textStorage?.setAttributedString(attributedString)
        }
        let wrap = context.environment.wordWrap
        if context.coordinator.lastWrap != wrap {
            context.coordinator.lastWrap = wrap
            scrollView.applyWordWrap(wrap)
        }
    }
}
