import AppKit

extension NSScrollView {
    /// Word wrap on: lines wrap to the visible width, no horizontal
    /// scroller. Off: lines keep their length and the view scrolls
    /// sideways. Shared by every NSTextView-backed viewer/editor
    /// (`CodeTextView`, `SelectableTextView`, `CodeTextEditor`) so View →
    /// Word Wrap behaves the same everywhere.
    func applyWordWrap(_ wordWrap: Bool) {
        guard let textView = documentView as? NSTextView, let container = textView.textContainer else { return }
        hasHorizontalScroller = !wordWrap
        if wordWrap {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            let width = contentSize.width
            textView.frame.size.width = width
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        } else {
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        textView.layoutManager?.ensureLayout(for: container)
        textView.sizeToFit()
        if !wordWrap {
            // Never narrower than the view, so it still fills the width.
            textView.minSize = NSSize(width: contentSize.width, height: contentSize.height)
            if textView.frame.width < contentSize.width { textView.frame.size.width = contentSize.width }
        }
        verticalRulerView?.needsDisplay = true
    }
}
