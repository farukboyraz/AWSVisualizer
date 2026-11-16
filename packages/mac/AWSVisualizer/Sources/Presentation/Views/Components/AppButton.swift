import SwiftUI
import AppKit

// MARK: - Hex <-> Color

extension Color {
    /// Parses `#RRGGBB` (leading `#` optional). Falls back to opaque black
    /// for anything malformed - a bad/missing color should never crash a
    /// button, just look wrong until fixed in Settings.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }

    var hexString: String {
        let resolved = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        let r = Int((resolved.redComponent * 255).rounded())
        let g = Int((resolved.greenComponent * 255).rounded())
        let b = Int((resolved.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Black on light backgrounds, white on medium/dark ones - perceived
    /// brightness (YIQ: `0.299R + 0.587G + 0.114B`) rather than a plain RGB
    /// average, since the eye weighs green much more heavily than blue.
    /// The 0.6 threshold (vs. YIQ's usual 0.5 midpoint) deliberately biases
    /// medium tones toward white text, matching "light -> black, medium or
    /// dark -> white" rather than splitting exactly down the middle.
    var contrastingContentColor: Color {
        let resolved = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        let brightness = resolved.redComponent * 0.299 + resolved.greenComponent * 0.587 + resolved.blueComponent * 0.114
        return brightness > 0.6 ? .black : .white
    }
}

// MARK: - Button kind

/// Every semantic "kind" of action button in the app, each with its own
/// Settings-configurable color (Settings -> Button Colors). Neutral actions
/// (Cancel, Close, Hide, Load more, Retry) are the `.secondary` kind, drawn
/// *tinted* rather than filled (see `variant`) so a dialog's "Cancel"
/// never competes visually with its colored primary/destructive action.
/// Only buttons inside native `.alert` / `.confirmationDialog` / context
/// menus stay system buttons - those containers can't render custom styles.
enum AppButtonKind: String, CaseIterable, Identifiable, Codable {
    case newItem
    case edit
    case delete
    case save
    case clone
    case refresh
    case confirm
    case open
    case download
    case run
    case stop
    case reveal
    case clear
    case warning
    case secondary
    /// Closes a result view / panel (e.g. PartiQL or Query results back to
    /// the scan) - Stop's tinted look with an ✕.
    case close

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newItem: "New / Create"
        case .edit: "Edit"
        case .delete: "Delete"
        case .save: "Save"
        case .clone: "Clone"
        case .refresh: "Refresh"
        case .confirm: "Approve / Confirm"
        case .open: "Open"
        case .download: "Download"
        case .run: "Run / Search"
        case .stop: "Stop"
        case .reveal: "Reveal"
        case .clear: "Clear"
        case .warning: "Warning"
        case .secondary: "Secondary"
        case .close: "Close / Dismiss"
        }
    }

    /// Filled (solid background, contrasting text) for primary actions;
    /// tinted (soft background in the kind's color, text in that color) for
    /// neutral / "undo-ish" ones so they stay visible without shouting.
    var variant: AppButtonVariant {
        switch self {
        case .secondary, .clear, .stop, .close: .tinted
        default: .filled
        }
    }

    var defaultHex: String {
        switch self {
        case .newItem: "#2563EB"  // blue
        case .edit: "#F97316"     // orange
        case .delete: "#7F1D1D"   // dark red
        case .save: "#14532D"     // dark green
        case .clone: "#7C3AED"    // purple
        case .refresh: "#0F766E"  // teal
        case .confirm: "#065F46"  // deep emerald - approve/merge/rotate-now
        case .open: "#4338CA"     // indigo - launch/open in an external app
        case .download: "#4B5563" // gray - neutral, non-mutating action
        case .run: "#0369A1"      // sky blue - run a query / search / compare
        case .stop: "#DC2626"     // red (tinted) - stop something in progress
        case .reveal: "#B45309"   // amber - show a hidden/secret value
        case .clear: "#64748B"    // slate (tinted) - clear a search / filter
        case .warning: "#C2410C"  // burnt orange - stop / reboot / force-deploy
        case .secondary: "#64748B" // slate (tinted) - cancel / close / load more
        case .close: "#DC2626"     // red (tinted) - close a results view
        }
    }

    /// Used when a call site doesn't override `systemImage` explicitly.
    var defaultSystemImage: String {
        switch self {
        case .newItem: "plus"
        case .edit: "pencil"
        case .delete: "trash"
        case .save: "checkmark"
        case .clone: "doc.on.doc"
        case .refresh: "arrow.clockwise"
        case .confirm: "checkmark.seal"
        case .open: "arrow.up.forward.app"
        case .download: "square.and.arrow.down"
        case .run: "play.fill"
        case .stop: "stop.fill"
        case .reveal: "eye"
        case .clear: "xmark.circle"
        case .warning: "exclamationmark.triangle"
        case .secondary: ""
        case .close: "xmark"
        }
    }

    /// A curated set of standard swatches offered in Settings' button-color
    /// picker before falling back to the full system color panel ("Other")
    /// - the same list for every kind, so picking a color is normally just
    /// a click rather than a trip through the system picker.
    static let presetColors: [String] = [
        "#2563EB", // blue
        "#0F766E", // teal
        "#16A34A", // green
        "#14532D", // dark green
        "#F97316", // orange
        "#CA8A04", // yellow / amber
        "#DC2626", // red
        "#7F1D1D", // dark red
        "#7C3AED", // purple
        "#DB2777", // pink
        "#4338CA", // indigo
        "#4B5563", // gray
    ]
}

/// The persisted (and Settings-editable) background color for each
/// `AppButtonKind`, stored as `#RRGGBB` hex strings in `~/.awsvisualizer`
/// (JSON-friendly - `Color`/`NSColor` aren't). Content (text/icon) color is
/// never stored - it's always derived from the background via
/// `contrastingContentColor` so it can't drift out of sync with a color
/// someone picks in Settings.
struct ButtonColorConfig: Codable, Equatable {
    var newItem: String
    var edit: String
    var delete: String
    var save: String
    var clone: String
    var refresh: String
    var confirm: String
    var open: String
    var download: String
    var run: String
    var stop: String
    var reveal: String
    var clear: String
    var warning: String
    var secondary: String
    var close: String

    static let defaults = ButtonColorConfig(colors: [:])

    /// Every kind from `colors`, falling back to the kind's default.
    init(colors: [AppButtonKind: String]) {
        func c(_ kind: AppButtonKind) -> String { colors[kind] ?? kind.defaultHex }
        newItem = c(.newItem); edit = c(.edit); delete = c(.delete); save = c(.save)
        clone = c(.clone); refresh = c(.refresh); confirm = c(.confirm); open = c(.open)
        download = c(.download); run = c(.run); stop = c(.stop); reveal = c(.reveal)
        clear = c(.clear); warning = c(.warning); secondary = c(.secondary); close = c(.close)
    }

    /// Tolerant decoding: a config written before a kind existed (or by an
    /// older sidecar) just gets that kind's default instead of failing the
    /// whole config load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var colors: [AppButtonKind: String] = [:]
        for kind in AppButtonKind.allCases {
            if let key = DynamicKey(stringValue: kind.rawValue), let value = try? container.decode(String.self, forKey: key) {
                colors[kind] = value
            }
        }
        self.init(colors: colors)
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    subscript(kind: AppButtonKind) -> String {
        get {
            switch kind {
            case .newItem: newItem
            case .edit: edit
            case .delete: delete
            case .save: save
            case .clone: clone
            case .refresh: refresh
            case .confirm: confirm
            case .open: open
            case .download: download
            case .run: run
            case .stop: stop
            case .reveal: reveal
            case .clear: clear
            case .warning: warning
            case .secondary: secondary
            case .close: close
            }
        }
        set {
            switch kind {
            case .newItem: newItem = newValue
            case .edit: edit = newValue
            case .delete: delete = newValue
            case .save: save = newValue
            case .clone: clone = newValue
            case .refresh: refresh = newValue
            case .confirm: confirm = newValue
            case .open: open = newValue
            case .download: download = newValue
            case .run: run = newValue
            case .stop: stop = newValue
            case .reveal: reveal = newValue
            case .clear: clear = newValue
            case .warning: warning = newValue
            case .secondary: secondary = newValue
            case .close: close = newValue
            }
        }
    }

    var asDictionary: [String: Any] {
        Dictionary(uniqueKeysWithValues: AppButtonKind.allCases.map { ($0.rawValue, self[$0]) })
    }
}

// MARK: - Button style

/// Renders the colored pill (labeled) or circle (icon-only) shape every
/// typed action button (`AppButton`, `EditButton`, `DeleteButton`, ...)
/// shares - the one place "config and color" actually lives, alongside
/// `AppButtonKind`/`ButtonColorConfig` above. Internal (not `private`) so
/// `EditButton.swift`/`DeleteButton.swift` can use it directly too. A
/// `ButtonStyle` rather than a plain `View` so it stays a real `Button`
/// underneath (hit-testing, accessibility, the system press animation)
/// instead of a look-alike.
enum AppButtonVariant {
    /// Solid background in the kind's color, black/white text for contrast.
    case filled
    /// Soft background tinted with the kind's color, text in that color.
    case tinted
}

struct AppButtonStyle: ButtonStyle {
    let color: Color
    var variant: AppButtonVariant = .filled
    let isCompact: Bool
    /// Diameter of the icon-only circle - ignored for labeled buttons.
    var compactSize: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        AppButtonBody(configuration: configuration, color: color, variant: variant, isCompact: isCompact, compactSize: compactSize)
    }
}

/// The actual rendering - a separate view so it can track hover and read
/// `isEnabled` / `colorScheme`, which a bare `ButtonStyle.makeBody` can't.
private struct AppButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let color: Color
    let variant: AppButtonVariant
    let isCompact: Bool
    let compactSize: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    /// Labeled buttons are a fixed height so buttons in one row line up.
    static let labeledHeight: CGFloat = 30

    var body: some View {
        let shape = isCompact ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        let pressed = configuration.isPressed
        let compactFontSize = max(9, (compactSize * 0.46).rounded())

        return configuration.label
            .font(.system(size: isCompact ? compactFontSize : 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .frame(width: isCompact ? compactSize : nil, height: isCompact ? compactSize : Self.labeledHeight)
            .padding(.horizontal, isCompact ? 0 : 13)
            .background {
                ZStack {
                    shape.fill(background(pressed: pressed))
                    if variant == .filled {
                        // Soft top highlight - gives the flat fill a little depth.
                        shape.fill(LinearGradient(colors: [.white.opacity(isHovered ? 0.18 : 0.12), .clear], startPoint: .top, endPoint: .bottom))
                    }
                    shape.stroke(border, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(variant == .filled && isEnabled && !pressed ? 0.18 : 0), radius: 1.5, y: 1)
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { isHovered = $0 && isEnabled }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }

    private var foreground: Color {
        switch variant {
        case .filled: return color.contrastingContentColor
        case .tinted: return tintText
        }
    }

    /// Tinted text: the kind's color, lifted toward white in dark mode so a
    /// dark slate/red stays readable on a dark window.
    private var tintText: Color {
        guard colorScheme == .dark else { return color }
        let base = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        return Color(nsColor: base.blended(withFraction: 0.45, of: .white) ?? base)
    }

    private func background(pressed: Bool) -> Color {
        switch variant {
        case .filled:
            return color.opacity(pressed ? 0.8 : 1)
        case .tinted:
            let base = colorScheme == .dark ? 0.24 : 0.13
            return color.opacity(pressed ? base + 0.12 : (isHovered ? base + 0.07 : base))
        }
    }

    private var border: Color {
        switch variant {
        case .filled: return .black.opacity(colorScheme == .dark ? 0.25 : 0.12)
        case .tinted: return color.opacity(colorScheme == .dark ? 0.45 : 0.3)
        }
    }
}

/// Base action button - used directly for kinds that don't have their own
/// dedicated type yet (`.newItem`/`.save`/`.clone`/`.refresh`/`.confirm`),
/// and composed *by* `EditButton`/`DeleteButton` for theirs (see those
/// files) rather than duplicating the icon/loading/help/disabled rendering
/// in each. Background color comes from `appState.buttonColors`
/// (Settings-editable, persisted in `~/.awsvisualizer`); text/icon color is
/// always derived automatically for contrast, never stored or passed in.
///
/// Icon-only (`title == nil`) renders as a small filled circle - matches
/// the existing pencil/trash/clone row-action icon buttons throughout the
/// app; labeled renders as a filled rounded-rect pill.
///
/// Confirmation flows stay outside this component - it only owns how the
/// button *looks*, not what happens when it's pressed (`DeleteButton`
/// layers its own confirmation on top rather than this type special-
/// casing `.delete`, so "what confirming means" lives with the one kind
/// that actually needs it).
struct AppButton: View {
    @Environment(AppState.self) private var appState

    let kind: AppButtonKind
    var title: String?
    /// `nil` uses `kind.defaultSystemImage`; set `showIcon: false` to
    /// suppress the icon entirely instead (rather than overloading this
    /// with a second layer of optionality).
    var systemImage: String?
    var showIcon: Bool = true
    /// Diameter of the icon-only circle (labeled buttons ignore this).
    var compactSize: CGFloat = 26
    var isLoading: Bool = false
    var isDisabled: Bool = false
    var help: String?
    var action: () -> Void

    init(
        _ title: String? = nil,
        kind: AppButtonKind,
        systemImage: String? = nil,
        showIcon: Bool = true,
        compactSize: CGFloat = 26,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.systemImage = systemImage
        self.showIcon = showIcon
        self.compactSize = compactSize
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.help = help ?? title
        self.action = action
    }

    private var resolvedIcon: String? {
        guard showIcon else { return nil }
        return systemImage ?? kind.defaultSystemImage
    }

    var body: some View {
        let color = Color(hex: appState.buttonColors[kind])
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                } else if let resolvedIcon, !resolvedIcon.isEmpty {
                    Image(systemName: resolvedIcon)
                }
                if let title {
                    Text(title)
                }
            }
        }
        .buttonStyle(AppButtonStyle(color: color, variant: kind.variant, isCompact: title == nil, compactSize: compactSize))
        .disabled(isDisabled || isLoading)
        .help(help ?? "")
    }
}

/// Type-erased `Shape` so `AppButtonStyle` can pick between `Circle()` and
/// `RoundedRectangle` without an `if/else` duplicating the whole modifier
/// chain (SwiftUI's `some Shape` opaque type can't vary between branches).
private struct AnyShape: Shape {
    private let pathBuilder: @Sendable (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        pathBuilder = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        pathBuilder(rect)
    }
}
