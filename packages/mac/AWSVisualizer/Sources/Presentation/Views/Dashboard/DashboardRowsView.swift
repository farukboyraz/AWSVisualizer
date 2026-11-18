import SwiftUI

/// Draws the dashboard's sections in the saved rows at their sizes
/// (`DashboardLayout`). The width is split into columns - 4 when wide
/// (≥ 1050 pt), 2 on a medium window (≥ 640 pt), 1 when narrow - and a
/// section takes as many as its size (small 1, medium 2, large all),
/// capped to what there is. A saved row that no longer fits wraps onto the
/// next line. Sections on one line get the same height. Switched-off
/// sections and empty rows are skipped.
struct DashboardRowsView<Cell: View>: View {
    typealias Widget = DashboardPrefs.Widget

    let layout: DashboardLayout
    let isOn: (Widget) -> Bool
    let width: CGFloat
    var spacing: CGFloat = 16
    var rowSpacing: CGFloat = 22
    @ViewBuilder let cell: (Widget, DashboardPrefs.WidgetSize) -> Cell

    static func columns(for width: CGFloat) -> Int {
        width >= 1050 ? DashboardLayout.columns : width >= 640 ? 2 : 1
    }

    private var columns: Int { Self.columns(for: width) }

    private func span(_ widget: Widget) -> Int { min(layout.span(of: widget), columns) }

    /// The saved rows, each wrapped into lines of at most `columns`.
    private var lines: [[Widget]] {
        var lines: [[Widget]] = []
        for row in layout.rows {
            var line: [Widget] = []
            var used = 0
            for widget in row where isOn(widget) {
                if used + span(widget) > columns, !line.isEmpty {
                    lines.append(line)
                    line = []
                    used = 0
                }
                line.append(widget)
                used += span(widget)
            }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    private func cellWidth(_ widget: Widget) -> CGFloat {
        let column = max((width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 0)
        let n = CGFloat(span(widget))
        return column * n + spacing * (n - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(line, id: \.self) { widget in
                        cell(widget, layout.size(of: widget))
                            .frame(width: cellWidth(widget))
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
