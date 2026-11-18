import SwiftUI
import AppKit

/// The dashboard's "Arrange layout" mode: every section (also the hidden
/// ones) as a tile in its row, drawn at its real width (small ¼ row,
/// medium ½, large the whole row) and in proportion to its real height.
/// Each tile shows / hides its section (eye) and switches its size
/// (S / M / L, like macOS widgets); a section whose packages are missing
/// has an Install button instead of the eye.
///
/// While dragging, the tile follows the pointer and the layout underneath
/// is already the result: a dashed "Drop here" placeholder sits where the
/// tile would land, the other tiles in that row narrow to make room, or the
/// rows below move down for a new row. Dropping beside a tile puts the
/// section in that row (while the row's minimum widths fit in 4 columns,
/// `DashboardLayout.fits`); the top / bottom quarter of a tile gives it a
/// row of its own. Each drop / resize calls `onChange` (saved right away).
struct DashboardLayoutEditor: View {
    typealias Widget = DashboardPrefs.Widget

    let layout: DashboardLayout
    /// Which sections are on (off ones are shown dimmed, still movable).
    let prefs: DashboardPrefs
    let language: AppLanguage
    var onChange: (DashboardLayout) -> Void
    /// Shows / hides a section.
    var onToggle: (Widget, Bool) -> Void = { _, _ in }
    var missingPackages: Set<String> = []
    var packageName: (String) -> String = { $0 }
    var onInstall: (Widget) -> Void = { _ in }
    var onDone: () -> Void

    /// Tiles are the real sections scaled down to this.
    private static let heightScale: CGFloat = 0.42

    private static let space = "dashboardLayoutEditor"

    @State private var dragging: Widget?
    @State private var target: DashboardLayout.Target?
    @State private var pointer: CGPoint = .zero
    @State private var grab: CGSize = .zero
    @State private var ghostSize: CGSize = .zero
    @State private var frames: [Widget: CGRect] = [:]
    @State private var width: CGFloat = 900

    private let spacing: CGFloat = 12

    /// The layout without the dragged section (targets are in its terms).
    private var base: DashboardLayout { dragging.map(layout.removing) ?? layout }

    /// What is drawn: the result of dropping at the current target.
    private var preview: DashboardLayout {
        guard let dragging, let target, let moved = base.inserting(dragging, at: target) else { return layout }
        return moved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            rows
        }
        .padding(18)
        .dashboardSurface()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(language.dashArrangeTitle, systemImage: "rectangle.3.group").font(.title3.bold())
                Text(language.dashArrangeHint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            SecondaryButton(language.dashArrangeReset, systemImage: "arrow.uturn.backward", isDisabled: layout == .default) {
                onChange(.default)
            }
            ConfirmButton(language.dashArrangeDone, systemImage: "checkmark", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(preview.rows.enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .coordinateSpace(name: Self.space)
        .overlay(alignment: .topLeading) { ghost }
        .contentShape(Rectangle())
        .gesture(drag)
        .animation(.snappy(duration: 0.22), value: preview)
    }

    private func tileWidth(_ widget: Widget) -> CGFloat {
        let columns = CGFloat(DashboardLayout.columns)
        let column = max((width - spacing * (columns - 1)) / columns, 0)
        let n = CGFloat(preview.span(of: widget))
        return column * n + spacing * (n - 1)
    }

    private func tileHeight(_ widget: Widget) -> CGFloat {
        max(62, widget.height(preview.size(of: widget)) * Self.heightScale)
    }

    private func rowView(_ row: [Widget]) -> some View {
        let height = row.map(tileHeight).max() ?? 62
        return HStack(spacing: spacing) {
            ForEach(row, id: \.self) { widget in
                Group {
                    if widget == dragging { placeholder } else { tile(widget) }
                }
                .frame(width: tileWidth(widget), height: height)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { frames[widget] = $0 }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Tiles

    private func missingService(_ widget: Widget) -> String? {
        DashboardPrefs.requiredService(for: widget).flatMap { missingPackages.contains($0) ? $0 : nil }
    }

    private func tile(_ widget: Widget) -> some View {
        let missing = missingService(widget)
        let isOn = prefs.isOn(widget) && missing == nil
        let size = layout.size(of: widget)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: Self.icon(widget))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text(language.dsWidget(widget))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if !isOn {
                    Text(language.dashArrangeOff)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                }
                Spacer(minLength: 4)
                if let missing {
                    DashboardSectionInstallButton(service: packageName(missing), language: language) { onInstall(widget) }
                } else {
                    Button { onToggle(widget, !isOn) } label: {
                        Image(systemName: isOn ? "eye" : "eye.slash")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 22)
                            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isOn ? language.dashArrangeHide : language.dashArrangeShow)
                }
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                sizePicker(widget, current: size)
                Text(language.widgetSizeWidth(size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.1)))
        .opacity(isOn ? 1 : 0.6)
        .onHover { hovering in
            if dragging == nil { (hovering ? NSCursor.openHand : NSCursor.arrow).set() }
        }
    }

    /// S / M / L - only the sizes the section offers.
    private func sizePicker(_ widget: Widget, current: DashboardPrefs.WidgetSize) -> some View {
        HStack(spacing: 2) {
            ForEach(widget.sizes, id: \.self) { size in
                Button { if size != current { onChange(layout.resizing(widget, to: size)) } } label: {
                    Text(language.widgetSizeShort(size))
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 20)
                        .foregroundStyle(size == current ? Color.white : Color.secondary)
                        .background(size == current ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(language.dashArrangeSize): \(language.widgetSizeLabel(size)) · \(language.widgetSizeWidth(size))")
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .overlay(Text(language.dashArrangeDropHere).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor))
    }

    /// The dragged tile under the pointer.
    @ViewBuilder private var ghost: some View {
        if let dragging {
            tile(dragging)
                .frame(width: ghostSize.width, height: ghostSize.height)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .scaleEffect(1.03)
                .offset(x: pointer.x - grab.width, y: pointer.y - grab.height)
                .allowsHitTesting(false)
        }
    }

    static func icon(_ widget: Widget) -> String {
        switch widget {
        case .resourcesKpi: "square.stack.3d.up.fill"
        case .activeKpi: "bolt.horizontal.circle.fill"
        case .costKpi: "dollarsign.circle.fill"
        case .attentionKpi: "exclamationmark.triangle.fill"
        case .customCards: "rectangle.stack.fill"
        case .distribution: "chart.pie.fill"
        case .topServices: "chart.bar.fill"
        case .costTrend: "chart.xyaxis.line"
        case .costByService: "list.bullet.rectangle.fill"
        case .services: "square.grid.2x2.fill"
        }
    }

    // MARK: Dragging

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragging == nil {
                    guard let (widget, frame) = frames.first(where: { $0.value.contains(value.startLocation) }) else { return }
                    grab = CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY)
                    ghostSize = frame.size
                    target = layout.currentTarget(of: widget)
                    dragging = widget
                    NSCursor.closedHand.set()
                }
                pointer = value.location
                updateTarget(at: value.location)
            }
            .onEnded { _ in finish() }
    }

    /// Over a tile: its left / right half = into its row (when it fits),
    /// its top / bottom quarter = a new row above / below. Over the
    /// placeholder or a gap the target stays; above / below everything =
    /// first / last row.
    private func updateTarget(at point: CGPoint) {
        guard let dragging else { return }
        if let own = frames[dragging], own.contains(point) { return }
        if let (widget, frame) = frames.first(where: { $0.key != dragging && $0.value.contains(point) }),
           let (row, index) = base.position(of: widget) {
            let fy = (point.y - frame.minY) / max(frame.height, 1)
            let next: DashboardLayout.Target
            if fy < 0.25 {
                next = .newRow(row)
            } else if fy > 0.75 {
                next = .newRow(row + 1)
            } else {
                let slot = DashboardLayout.Target.slot(row: row, index: point.x < frame.midX ? index : index + 1)
                next = base.inserting(dragging, at: slot) != nil ? slot : (fy < 0.5 ? .newRow(row) : .newRow(row + 1))
            }
            if next != target { target = next }
            return
        }
        let others = frames.filter { $0.key != dragging }.values
        if let top = others.map(\.minY).min(), point.y < top {
            if target != .newRow(0) { target = .newRow(0) }
        } else if let bottom = others.map(\.maxY).max(), point.y > bottom {
            let end = DashboardLayout.Target.newRow(base.rows.count)
            if target != end { target = end }
        }
    }

    private func finish() {
        defer {
            if self.dragging != nil { NSCursor.arrow.set() }
            self.dragging = nil
            self.target = nil
        }
        guard let dragging, let target, let moved = base.inserting(dragging, at: target), moved != layout else { return }
        onChange(moved)
    }
}
