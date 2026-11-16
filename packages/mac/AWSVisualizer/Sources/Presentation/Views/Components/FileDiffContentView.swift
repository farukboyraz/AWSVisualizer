import SwiftUI
import AppKit

enum DiffViewMode: String, CaseIterable {
    case unified = "Unified"
    case split = "Split"
    /// The whole old file left, the whole new file right, changes
    /// highlighted (not just the changed regions).
    case file = "File"
}

/// A / M / D in a small circle, with Added / Modified / Deleted on hover -
/// used by every changed-files list.
struct ChangeTypeBadge: View {
    let changeType: String

    var body: some View {
        let (label, color, help): (String, Color, String) = {
            switch changeType {
            case "A": return ("A", .green, "Added")
            case "D": return ("D", .red, "Deleted")
            default: return ("M", .orange, "Modified")
            }
        }()
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(color, in: Circle())
            .help(help)
    }
}

/// Renders one file's diff (hunk headers, +/- counts, Unified/Split toggle)
/// - shared by CodeCommit's own diff viewer (`CodeCommitDiffPane`, comparing
/// two commits/branches via the CodeCommit API: commits, history, pull
/// requests) and the Workspace tab's local diff (comparing a local git
/// checkout against a branch). Both feed it the exact same
/// `CodeCommitFileDiff` shape regardless of where the two sides of text
/// actually came from, so this has no idea which one it's in.
///
/// Drawn like the file viewers (`CodeFileViewer`): syntax highlighting in
/// the Settings code theme, a line-number gutter (old + new numbers in
/// Unified, one per side in Split) and an NSTextView underneath, so large
/// diffs scroll smoothly and text is selectable. Split mode has a draggable
/// middle divider, both sides scroll horizontally on their own and
/// vertically together, and the host's file list can be hidden for room.
struct FileDiffContentView: View {
    let fileDiff: CodeCommitFileDiff
    @Binding var mode: DiffViewMode
    /// The host's file list - Split hides it so both columns get the width;
    /// the sidebar button brings it back.
    var fileListHidden: Binding<Bool>?
    /// Fetches this file's diff with the whole file as context - enables
    /// the File mode (hidden when nil).
    var loadFullFile: (() async throws -> CodeCommitFileDiff)? = nil
    /// Pull request line comments: lines with a thread get a bubble in the
    /// gutter; a click on a line number calls `onLineTap` (nil = the diff
    /// isn't commentable, e.g. a commit or branch compare).
    var commentedLines: Set<DiffLineRef> = []
    var onLineTap: ((DiffLineRef) -> Void)? = nil

    @Environment(\.codeTheme) private var theme
    @Environment(\.wordWrap) private var wordWrap
    @State private var documents: DiffDocuments?
    @State private var fullDocuments: DiffDocuments?
    @State private var fullFileError: String?
    @State private var splitFraction: CGFloat = 0.5
    @State private var dragStartFraction: CGFloat?
    @State private var scrollSync = DiffScrollSync()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if mode == .file {
                    if let fullDocuments {
                        splitBody(fullDocuments)
                    } else if let fullFileError {
                        ErrorStateView(message: fullFileError, retry: { Task { await loadFull() } })
                    } else {
                        BrandedLoader(message: "Loading both versions…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let documents {
                    switch mode {
                    case .unified:
                        if wordWrap {
                            WrappedDiffView(left: documents.unified, right: nil, theme: theme, splitFraction: $splitFraction, commentedLines: commentedLines, onLineTap: onLineTap)
                        } else {
                            DiffTextView(document: documents.unified, theme: theme, commentedLines: commentedLines, onLineTap: onLineTap)
                        }
                    case .split, .file:
                        splitBody(documents)
                    }
                } else {
                    BrandedLoader(message: "Highlighting…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(theme.swiftUIBackground)
        }
        .task(id: "\(mode == .file)|\(theme.id.rawValue)|\(fileDiff.path)") {
            if mode == .file { await loadFull() }
        }
        .task(id: "\(theme.id.rawValue)|\(fileDiff.path)|\(fileDiff.additions)|\(fileDiff.deletions)|\(fileDiff.hunks.count)") {
            let diff = fileDiff
            let currentTheme = theme
            let built = await Task.detached(priority: .userInitiated) {
                DiffDocumentBuilder.build(diff, theme: currentTheme)
            }.value
            guard !Task.isCancelled else { return }
            documents = built
        }
        .onChange(of: mode) { _, newMode in
            fileListHidden?.wrappedValue = newMode != .unified
        }
        .onChange(of: fileDiff.path) { _, _ in
            fullDocuments = nil
            fullFileError = nil
        }
    }

    private var availableModes: [DiffViewMode] {
        loadFullFile == nil ? [.unified, .split] : DiffViewMode.allCases
    }

    private func loadFull() async {
        guard let loadFullFile, fullDocuments == nil else { return }
        fullFileError = nil
        do {
            let diff = try await loadFullFile()
            let currentTheme = theme
            let built = await Task.detached(priority: .userInitiated) {
                DiffDocumentBuilder.build(diff, theme: currentTheme)
            }.value
            guard !Task.isCancelled else { return }
            fullDocuments = built
        } catch {
            guard !Task.isCancelled else { return }
            fullFileError = error.friendlyMessage
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let fileListHidden {
                Button {
                    fileListHidden.wrappedValue.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(fileListHidden.wrappedValue ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(fileListHidden.wrappedValue ? "Show the file list" : "Hide the file list for a wider diff")
            }
            Text(fileDiff.path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Label("\(fileDiff.additions)", systemImage: "plus")
                .foregroundStyle(.green)
            Label("\(fileDiff.deletions)", systemImage: "minus")
                .foregroundStyle(.red)
            Spacer()
            MultiSwitchBox(
                selection: Binding(get: { availableModes.contains(mode) ? mode : .unified }, set: { mode = $0 }),
                options: availableModes.map { ($0, $0.rawValue) },
                segmentWidth: 70,
                height: 24
            )
            .help("Unified: changes in one column · Split: old and new side by side · File: the whole old and new file side by side")
        }
        .font(.caption.monospaced())
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func splitBody(_ documents: DiffDocuments) -> some View {
        if wordWrap {
            // Wrapped lines: one row per diff line holding both sides, so
            // a long line wrapping on one side grows the row on both and
            // the columns never drift apart.
            WrappedDiffView(left: documents.left, right: documents.right, theme: theme, splitFraction: $splitFraction, commentedLines: commentedLines, onLineTap: onLineTap)
        } else {
            unwrappedSplit(documents)
        }
    }

    private func unwrappedSplit(_ documents: DiffDocuments) -> some View {
        GeometryReader { geo in
            let total = max(geo.size.width, 1)
            let leftWidth = min(max(total * splitFraction, 160), max(total - 160, 160))
            HStack(spacing: 0) {
                DiffTextView(document: documents.left, theme: theme, sync: scrollSync, commentedLines: commentedLines, onLineTap: onLineTap)
                    .frame(width: leftWidth)
                Divider()
                    .overlay(
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 8)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                            .gesture(
                                // `.global` for the same reason as `ResizableSplitView`.
                                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        let base = dragStartFraction ?? splitFraction
                                        if dragStartFraction == nil { dragStartFraction = splitFraction }
                                        splitFraction = min(max(base + value.translation.width / total, 0.15), 0.85)
                                    }
                                    .onEnded { _ in dragStartFraction = nil }
                            )
                    )
                DiffTextView(document: documents.right, theme: theme, sync: scrollSync, commentedLines: commentedLines, onLineTap: onLineTap)
            }
        }
    }
}

// MARK: - Building the text

enum DiffLineKind: Sendable {
    case context, add, del, hunk, filler

    func background(_ theme: CodeTheme) -> NSColor? {
        switch self {
        case .context: nil
        case .add: NSColor.systemGreen.withAlphaComponent(0.18)
        case .del: NSColor.systemRed.withAlphaComponent(0.18)
        case .hunk: NSColor.systemBlue.withAlphaComponent(0.10)
        case .filler: NSColor.secondaryLabelColor.withAlphaComponent(0.07)
        }
    }
}

/// Which version of the file a diff line is in - AWS's
/// `relativeFileVersion` for a pull request line comment.
enum DiffSide: String, Sendable {
    case before = "BEFORE"
    case after = "AFTER"
}

/// A line of one version of the file (1-based, like the gutter numbers).
struct DiffLineRef: Hashable, Sendable {
    let side: DiffSide
    let line: Int
}

/// One column of diff text: highlighted lines + per-line gutter label and kind.
struct DiffDocument: @unchecked Sendable {
    let id = UUID()
    let text: NSAttributedString
    let gutter: [String]
    let kinds: [DiffLineKind]
    /// The file line each row shows (nil for hunk headers and filler):
    /// a deleted line is in the old version, everything else in the new.
    let refs: [DiffLineRef?]
    /// The same lines one by one, for SwiftUI `Text` (word-wrap mode).
    let lines: [AttributedString]
}

struct DiffDocuments: @unchecked Sendable {
    let unified: DiffDocument
    let left: DiffDocument
    let right: DiffDocument
}

extension NSAttributedString.Key {
    /// Full-width line background drawn by `DiffLayoutManager`.
    static let diffLineBackground = NSAttributedString.Key("diffLineBackground")
}

enum DiffDocumentBuilder {
    private struct Row {
        let kind: DiffLineKind
        let text: String
        var old: Int?
        var new: Int?
        var sign = ""
    }

    static func build(_ diff: CodeCommitFileDiff, theme: CodeTheme) -> DiffDocuments {
        var unified: [Row] = [], left: [Row] = [], right: [Row] = []
        for hunk in diff.hunks {
            var (oldNo, newNo) = start(of: hunk.header)
            let header = Row(kind: .hunk, text: hunk.header)
            unified.append(header)
            left.append(header)
            right.append(header)
            // Each run of deletions is paired index-wise with the run of
            // additions right after it (a replaced line sits side by side);
            // the shorter side gets filler rows so both columns line up.
            var dels: [Row] = [], adds: [Row] = []
            func flush() {
                for i in 0..<max(dels.count, adds.count) {
                    left.append(i < dels.count ? dels[i] : Row(kind: .filler, text: ""))
                    right.append(i < adds.count ? adds[i] : Row(kind: .filler, text: ""))
                }
                dels = []
                adds = []
            }
            for line in hunk.lines {
                switch line.type {
                case "del":
                    unified.append(Row(kind: .del, text: line.text, old: oldNo, sign: "-"))
                    dels.append(Row(kind: .del, text: line.text, old: oldNo))
                    oldNo += 1
                case "add":
                    unified.append(Row(kind: .add, text: line.text, new: newNo, sign: "+"))
                    adds.append(Row(kind: .add, text: line.text, new: newNo))
                    newNo += 1
                default:
                    flush()
                    unified.append(Row(kind: .context, text: line.text, old: oldNo, new: newNo))
                    left.append(Row(kind: .context, text: line.text, old: oldNo))
                    right.append(Row(kind: .context, text: line.text, new: newNo))
                    oldNo += 1
                    newNo += 1
                }
            }
            flush()
        }
        let language = CodeLanguage.detect(path: diff.path)
        let digits = max(3, String(max(unified.compactMap(\.old).max() ?? 0, unified.compactMap(\.new).max() ?? 0)).count)
        func pad(_ n: Int?) -> String {
            let s = n.map(String.init) ?? ""
            return String(repeating: " ", count: max(digits - s.count, 0)) + s
        }
        return DiffDocuments(
            unified: render(unified, language: language, theme: theme, ref: { row in
                row.kind == .del ? row.old.map { DiffLineRef(side: .before, line: $0) } : row.new.map { DiffLineRef(side: .after, line: $0) }
            }) { "\(pad($0.old)) \(pad($0.new)) \($0.sign.isEmpty ? " " : $0.sign)" },
            left: render(left, language: language, theme: theme, ref: { $0.old.map { DiffLineRef(side: .before, line: $0) } }) { pad($0.old) },
            right: render(right, language: language, theme: theme, ref: { $0.new.map { DiffLineRef(side: .after, line: $0) } }) { pad($0.new) }
        )
    }

    /// `@@ -12,7 +12,9 @@` → (12, 12).
    private static let hunkStart = try? NSRegularExpression(pattern: #"-(\d+)(?:,\d+)?\s+\+(\d+)"#)

    private static func start(of header: String) -> (Int, Int) {
        let ns = header as NSString
        guard let match = hunkStart?.firstMatch(in: header, range: NSRange(location: 0, length: ns.length)),
              let old = Int(ns.substring(with: match.range(at: 1))),
              let new = Int(ns.substring(with: match.range(at: 2))) else { return (1, 1) }
        return (old, new)
    }

    private static func render(_ rows: [Row], language: CodeLanguage, theme: CodeTheme, ref: (Row) -> DiffLineRef?, gutter: (Row) -> String) -> DiffDocument {
        let plain = rows.map(\.text).joined(separator: "\n")
        let text = NSMutableAttributedString(attributedString: CodeHighlighter.highlight(plain, language: language, theme: theme, fontSize: 12))
        var location = 0
        var lines: [AttributedString] = []
        lines.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() {
            let textLength = (row.text as NSString).length
            let length = textLength + (i < rows.count - 1 ? 1 : 0)
            let range = NSRange(location: location, length: length)
            if row.kind == .hunk {
                text.addAttribute(.foregroundColor, value: theme.lineNumber, range: range)
            }
            if let color = row.kind.background(theme), length > 0 {
                text.addAttribute(.diffLineBackground, value: color, range: range)
            }
            lines.append(swiftUILine(text.attributedSubstring(from: NSRange(location: location, length: textLength))))
            location += length
        }
        return DiffDocument(
            text: text,
            gutter: rows.map { $0.kind == .hunk || $0.kind == .filler ? "" : gutter($0) },
            kinds: rows.map(\.kind),
            refs: rows.map { $0.kind == .hunk || $0.kind == .filler ? nil : ref($0) },
            lines: lines
        )
    }

    /// One highlighted line as a SwiftUI `AttributedString` (colors kept as
    /// dynamic NSColors so adaptive themes follow light/dark mode).
    private static func swiftUILine(_ ns: NSAttributedString) -> AttributedString {
        guard ns.length > 0 else { return AttributedString(" ", attributes: AttributeContainer().font(.system(size: 12, design: .monospaced))) }
        var result = AttributedString()
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attributes, range, _ in
            var piece = AttributedString(ns.attributedSubstring(from: range).string)
            if let color = attributes[.foregroundColor] as? NSColor { piece.foregroundColor = Color(nsColor: color) }
            let isBold = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            piece.font = .system(size: 12, weight: isBold ? .semibold : .regular, design: .monospaced)
            result += piece
        }
        return result
    }
}

// MARK: - Word-wrap view

/// Diff with long lines wrapped. Each row holds a line of *both* sides
/// (Split / File) - when either side wraps onto more lines the whole row
/// grows, so left and right stay aligned line for line. Lazily built rows,
/// selectable text, a draggable middle divider.
struct WrappedDiffView: View {
    let left: DiffDocument
    /// nil = Unified (one column).
    let right: DiffDocument?
    let theme: CodeTheme
    @Binding var splitFraction: CGFloat
    var commentedLines: Set<DiffLineRef> = []
    var onLineTap: ((DiffLineRef) -> Void)? = nil

    @Environment(AppState.self) private var appState
    @State private var dragStartFraction: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let total = max(geo.size.width, 1)
            let leftWidth = min(max(total * splitFraction, 160), max(total - 160, 160))
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<left.lines.count, id: \.self) { index in
                        HStack(alignment: .top, spacing: 0) {
                            cell(left, index)
                                .frame(width: right == nil ? total : leftWidth)
                            if let right, index < right.lines.count {
                                Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1)
                                cell(right, index)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if right != nil { dragHandle(total: total).offset(x: leftWidth - 4) }
            }
        }
    }

    private func cell(_ document: DiffDocument, _ index: Int) -> some View {
        let gutterWidth = CGFloat(max(document.gutter.map(\.count).max() ?? 3, 3)) * 6.5 + 10
        let ref = index < document.refs.count ? document.refs[index] : nil
        return HStack(alignment: .top, spacing: 6) {
            HStack(spacing: 2) {
                if onLineTap != nil {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.accentColor)
                        .opacity(ref.map(commentedLines.contains) == true ? 1 : 0)
                }
                Text(document.gutter[index])
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color(nsColor: theme.lineNumber))
                    .frame(width: gutterWidth, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { if let ref { onLineTap?(ref) } }
            .help(onLineTap != nil && ref != nil ? appState.language.prCommentGutterHelp : "")
            Text(document.lines[index])
                .foregroundStyle(document.kinds[index] == .hunk ? Color(nsColor: theme.lineNumber) : Color(nsColor: theme.foreground))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: document.kinds[index].background(theme) ?? .clear))
    }

    private func dragHandle(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragStartFraction ?? splitFraction
                        if dragStartFraction == nil { dragStartFraction = splitFraction }
                        splitFraction = min(max(base + value.translation.width / total, 0.15), 0.85)
                    }
                    .onEnded { _ in dragStartFraction = nil }
            )
    }
}

// MARK: - Text view

/// Keeps the two Split columns at the same vertical position while each
/// keeps its own horizontal scroll.
@MainActor
final class DiffScrollSync: NSObject {
    private final class WeakScroll { weak var view: NSScrollView?; init(_ v: NSScrollView) { view = v } }
    private var views: [WeakScroll] = []
    private var isSyncing = false

    func register(_ scrollView: NSScrollView) {
        views.removeAll { $0.view == nil || $0.view === scrollView }
        views.append(WeakScroll(scrollView))
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    @objc private func boundsChanged(_ note: Notification) {
        guard !isSyncing, let clip = note.object as? NSClipView else { return }
        isSyncing = true
        defer { isSyncing = false }
        for other in views.compactMap(\.view) where other.contentView !== clip {
            var origin = other.contentView.bounds.origin
            guard origin.y != clip.bounds.origin.y else { continue }
            origin.y = clip.bounds.origin.y
            other.contentView.scroll(to: origin)
            other.reflectScrolledClipView(other.contentView)
        }
    }
}

struct DiffTextView: NSViewRepresentable {
    let document: DiffDocument
    let theme: CodeTheme
    var sync: DiffScrollSync?
    var commentedLines: Set<DiffLineRef> = []
    var onLineTap: ((DiffLineRef) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = DiffLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 6, height: 8)

        let scrollView = DiffScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        let ruler = DiffGutterRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        load(document, into: scrollView)
        applyTheme(to: scrollView)
        applyComments(to: scrollView)
        context.coordinator.lastID = document.id
        context.coordinator.lastThemeID = theme.id
        sync?.register(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if context.coordinator.lastID != document.id {
            context.coordinator.lastID = document.id
            load(document, into: scrollView)
        }
        if context.coordinator.lastThemeID != theme.id {
            context.coordinator.lastThemeID = theme.id
            applyTheme(to: scrollView)
        }
        applyComments(to: scrollView)
    }

    /// Cheap: the ruler only redraws when the marked lines or commentability change.
    private func applyComments(to scrollView: NSScrollView) {
        (scrollView.verticalRulerView as? DiffGutterRulerView)?.setComments(markers: commentedLines, onLineTap: onLineTap)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastID: UUID?
        var lastThemeID: CodeThemeID?
    }

    private func load(_ document: DiffDocument, into scrollView: NSScrollView) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(document.text)
        (scrollView.verticalRulerView as? DiffGutterRulerView)?.update(gutter: document.gutter, kinds: document.kinds, refs: document.refs, theme: theme)
        scrollView.tile()
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
        textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6)]
        if let ruler = scrollView.verticalRulerView as? DiffGutterRulerView {
            ruler.theme = theme
            ruler.needsDisplay = true
        }
    }
}

/// Keeps the text view at least as wide/tall as the visible area, so line
/// backgrounds reach the right edge even when every line is short.
private final class DiffScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView,
              let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let inset = textView.textContainerInset
        let size = NSSize(width: max(contentSize.width, ceil(used.width + inset.width * 2 + 20)),
                          height: max(contentSize.height, ceil(used.height + inset.height * 2)))
        if textView.frame.size != size { textView.setFrameSize(size) }
    }
}

/// Paints each line's add/del/hunk background across the full width
/// (`.backgroundColor` would only cover the glyphs).
private final class DiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage {
            enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphRange, _ in
                let index = self.characterIndexForGlyph(at: glyphRange.location)
                guard index < storage.length,
                      let color = storage.attribute(.diffLineBackground, at: index, effectiveRange: nil) as? NSColor else { return }
                color.setFill()
                NSRect(x: 0, y: rect.minY + origin.y, width: 100_000, height: rect.height).fill(using: .sourceOver)
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// Gutter with the diff's own labels (old/new line numbers, +/-) per
/// logical line, tinted like the line it belongs to. Same visible-lines
/// drawing as the file viewer's `LineNumberRulerView`.
private final class DiffGutterRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    private var gutter: [String] = []
    private var kinds: [DiffLineKind] = []
    private var refs: [DiffLineRef?] = []
    private var commentMarkers: Set<DiffLineRef> = []
    private var onLineTap: ((DiffLineRef) -> Void)?
    private var hoverLine: Int?
    var theme: CodeTheme = CodeThemeID.vscode.theme

    /// Room on the left for the comment bubble when the diff is commentable.
    private var markerWidth: CGFloat { onLineTap == nil ? 0 : 14 }
    private static let bubble = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .regular).applying(.init(paletteColors: [.controlAccentColor])))
    private static let addBubble = NSImage(systemSymbolName: "plus.bubble", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor])))

    private static let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func boundsChanged() { needsDisplay = true }

    func update(gutter: [String], kinds: [DiffLineKind], refs: [DiffLineRef?], theme: CodeTheme) {
        self.gutter = gutter
        self.kinds = kinds
        self.refs = refs
        self.theme = theme
        hoverLine = nil
        if let clip = textView?.enclosingScrollView?.contentView {
            NotificationCenter.default.removeObserver(self)
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
        rebuildIndex()
        updateThickness()
        needsDisplay = true
    }

    func setComments(markers: Set<DiffLineRef>, onLineTap: ((DiffLineRef) -> Void)?) {
        let commentabilityChanged = (self.onLineTap == nil) != (onLineTap == nil)
        self.onLineTap = onLineTap
        guard commentabilityChanged || markers != self.commentMarkers else { return }
        self.commentMarkers = markers
        if commentabilityChanged {
            updateThickness()
            window?.invalidateCursorRects(for: self)
        }
        needsDisplay = true
    }

    private func updateThickness() {
        let widest = gutter.map(\.count).max() ?? 3
        let charWidth = ("0" as NSString).size(withAttributes: [.font: Self.font]).width
        let thickness = CGFloat(max(widest, 3)) * charWidth + 16 + markerWidth
        if ruleThickness != thickness { ruleThickness = thickness }
    }

    // MARK: Clicking a line number to comment on it

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        if onLineTap != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseMoved(with event: NSEvent) {
        let line = onLineTap == nil ? nil : commentableLine(at: convert(event.locationInWindow, from: nil))
        if line != hoverLine {
            hoverLine = line
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverLine != nil {
            hoverLine = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onLineTap, let line = commentableLine(at: convert(event.locationInWindow, from: nil)), let ref = refs[line] else {
            super.mouseDown(with: event)
            return
        }
        onLineTap(ref)
    }

    /// The logical line under a point in the ruler, if it is a real file
    /// line (not a hunk header or filler). Inverse of the drawing below.
    private func commentableLine(at point: NSPoint) -> Int? {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              (textView.string as NSString).length > 0 else { return nil }
        let y = point.y - convert(NSPoint.zero, from: textView).y - textView.textContainerInset.height
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard y >= fragment.minY, y <= fragment.maxY else { return nil }
        let line = lineIndex(for: layoutManager.characterIndexForGlyph(at: glyph))
        return line < refs.count && refs[line] != nil ? line : nil
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
    }

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

        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: theme.lineNumber]
        let glyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let inset = textView.textContainerInset.height
        let offset = convert(NSPoint.zero, from: textView).y
        let length = (textView.string as NSString).length

        var line = lineIndex(for: charRange.location)
        while line < lineStarts.count {
            let start = lineStarts[line]
            if start > NSMaxRange(charRange) { break }
            let fragment: NSRect
            if start >= length {
                fragment = layoutManager.extraLineFragmentRect
            } else {
                fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let y = fragment.minY + inset + offset
            if line < kinds.count, let color = kinds[line].background(theme) {
                color.setFill()
                NSRect(x: 0, y: y, width: bounds.width - 1, height: fragment.height).fill(using: .sourceOver)
            }
            if line < gutter.count, !gutter[line].isEmpty {
                let label = gutter[line] as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + 1), withAttributes: attributes)
            }
            if markerWidth > 0, line < refs.count, let ref = refs[line] {
                let icon = commentMarkers.contains(ref) ? Self.bubble : (line == hoverLine ? Self.addBubble : nil)
                if let icon {
                    let size = icon.size
                    icon.draw(in: NSRect(x: 4, y: y + (fragment.height - size.height) / 2, width: size.width, height: size.height),
                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            line += 1
        }
    }
}
