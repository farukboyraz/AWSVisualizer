import SwiftUI
import AppKit

/// Read-only, selectable code view: highlighted text, a line-number gutter,
/// and either **word wrap** (long lines wrap to the view's width) or a
/// horizontal scroller (lines keep their length and the view scrolls
/// sideways). Line numbers count *logical* lines, so a wrapped line keeps
/// one number - same as Xcode / VS Code.
struct CodeTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    var wordWrap: Bool
    var showLineNumbers: Bool = true
    /// Editor background + line-number colors (token colors are already in
    /// `attributedText`).
    var theme: CodeTheme = CodeThemeID.vscode.theme

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textStorage?.setAttributedString(attributedText)
        applyTheme(to: scrollView)

        if showLineNumbers {
            let ruler = LineNumberRulerView(textView: textView)
            ruler.theme = theme
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }
        apply(wordWrap: wordWrap, to: scrollView)
        context.coordinator.lastWrap = wordWrap
        context.coordinator.lastThemeID = theme.id
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.textStorage?.string != attributedText.string {
            textView.textStorage?.setAttributedString(attributedText)
            (scrollView.verticalRulerView as? LineNumberRulerView)?.textDidChange()
        }
        if context.coordinator.lastThemeID != theme.id {
            context.coordinator.lastThemeID = theme.id
            applyTheme(to: scrollView)
        }
        if context.coordinator.lastWrap != wordWrap {
            context.coordinator.lastWrap = wordWrap
            apply(wordWrap: wordWrap, to: scrollView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastWrap: Bool?
        var lastThemeID: CodeThemeID?
    }

    private func applyTheme(to scrollView: NSScrollView) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if let background = theme.background {
            textView.drawsBackground = true
            textView.backgroundColor = background
            scrollView.drawsBackground = true
            scrollView.backgroundColor = background
        } else {
            textView.drawsBackground = false
            scrollView.drawsBackground = false
        }
        textView.insertionPointColor = theme.foreground
        textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6)]
        if let ruler = scrollView.verticalRulerView as? LineNumberRulerView {
            ruler.theme = theme
            ruler.needsDisplay = true
        }
    }

    private func apply(wordWrap: Bool, to scrollView: NSScrollView) {
        scrollView.applyWordWrap(wordWrap)
    }
}

/// Line-number gutter. Keeps an index of where each logical line starts so
/// drawing only touches the visible lines (binary search for the first),
/// which keeps scrolling smooth in large files.
private final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    var theme: CodeTheme = CodeThemeID.vscode.theme

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        rebuildIndex()
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func boundsChanged() { needsDisplay = true }

    func textDidChange() {
        rebuildIndex()
        needsDisplay = true
    }

    private func rebuildIndex() {
        guard let text = textView?.string as NSString? else { return }
        var starts = [0]
        var index = 0
        let length = text.length
        while index < length {
            let range = text.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(range)
            if index < length || (index == length && length > 0 && text.character(at: length - 1) == 10) {
                starts.append(index)
            }
            if range.length == 0 { break }
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        ruleThickness = CGFloat(digits) * 7.5 + 14
    }

    /// Index of the last line start <= `location`.
    private func lineIndex(for location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        if let background = theme.background {
            background.setFill()
            bounds.fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: theme.lineNumber,
        ]
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let inset = textView.textContainerInset.height
        // Text view → ruler coordinates (accounts for scrolling).
        let offset = convert(NSPoint.zero, from: textView).y
        let length = (textView.string as NSString).length

        var line = lineIndex(for: charRange.location)
        while line < lineStarts.count {
            let start = lineStarts[line]
            if start > NSMaxRange(charRange) { break }
            let rectY: CGFloat
            if start >= length {
                // Trailing empty line after a final newline.
                rectY = layoutManager.extraLineFragmentRect.minY
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                rectY = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            }
            let y = rectY + inset + offset
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + 1), withAttributes: attributes)
            line += 1
        }
    }
}
