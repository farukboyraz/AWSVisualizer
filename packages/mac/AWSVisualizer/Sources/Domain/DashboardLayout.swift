import Foundation
import CoreGraphics

/// The dashboard's sections as rows, top to bottom (`display.dashboard.layout`
/// in ~/.awsvisualizer), and each section's size (`display.dashboard.sizes`).
/// Same rules as packages/api/src/config/dashboard-layout.ts: a row is 4
/// columns; like macOS widgets a section is small (1 column), medium (2)
/// or large (the whole row), and a row holds sections while their sizes fit in 4.
struct DashboardLayout: Equatable {
    typealias Widget = DashboardPrefs.Widget
    typealias Size = DashboardPrefs.WidgetSize

    static let columns = 4

    var rows: [[Widget]]
    var sizes: [Widget: Size]

    static let defaultRows: [[Widget]] = [
        [.resourcesKpi, .activeKpi, .costKpi, .attentionKpi],
        [.customCards],
        [.distribution, .topServices],
        [.costTrend, .costByService],
        [.services],
    ]

    static let `default` = DashboardLayout(rows: defaultRows, sizes: [:])

    /// Where a dragged section would go: into a row at an index, or as a
    /// new row of its own before row `n` (`n == rows.count` = at the end).
    enum Target: Equatable {
        case slot(row: Int, index: Int)
        case newRow(Int)
    }

    init(rows: [[Widget]], sizes: [Widget: Size]) {
        self.rows = rows
        self.sizes = sizes
    }

    /// Same rows and same sizes (a size left out = its default).
    static func == (lhs: DashboardLayout, rhs: DashboardLayout) -> Bool {
        lhs.rows == rhs.rows && Widget.allCases.allSatisfy { lhs.size(of: $0) == rhs.size(of: $0) }
    }

    /// A saved layout made safe to draw (same as the sidecar's `readLayout`):
    /// unknown sizes fall back to the default, unknown / repeated ids are
    /// dropped, overfull rows split, missing sections added back as their default rows.
    init(reading raw: [[String]], sizes rawSizes: [String: String]) {
        var sizes: [Widget: Size] = [:]
        for (id, value) in rawSizes {
            if let widget = Widget(rawValue: id), let size = Size(rawValue: value), widget.sizes.contains(size) { sizes[widget] = size }
        }
        self.sizes = sizes
        self.rows = []
        var seen = Set<Widget>()
        for rawRow in raw {
            var row: [Widget] = []
            for id in rawRow {
                guard let widget = Widget(rawValue: id), !seen.contains(widget) else { continue }
                seen.insert(widget)
                row.append(widget)
            }
            appendSplit(row)
        }
        for defaultRow in Self.defaultRows {
            let missing = defaultRow.filter { !seen.contains($0) }
            missing.forEach { seen.insert($0) }
            appendSplit(missing)
        }
    }

    /// Adds a row, split into as many rows as its sizes need.
    private mutating func appendSplit(_ row: [Widget]) {
        var line: [Widget] = []
        for widget in row {
            if !line.isEmpty && !fits(line + [widget]) {
                rows.append(line)
                line = []
            }
            line.append(widget)
        }
        if !line.isEmpty { rows.append(line) }
    }

    func size(of widget: Widget) -> Size { sizes[widget] ?? widget.defaultSize }

    func span(of widget: Widget) -> Int { size(of: widget).span }

    func fits(_ row: [Widget]) -> Bool {
        row.reduce(0) { $0 + span(of: $1) } <= Self.columns
    }

    var rowsJSON: [[String]] { rows.map { $0.map(\.rawValue) } }

    /// Every section's size spelled out, so the saved file lists them all.
    var sizesJSON: [String: String] {
        Dictionary(uniqueKeysWithValues: Widget.allCases.map { ($0.rawValue, size(of: $0).rawValue) })
    }

    func position(of widget: Widget) -> (row: Int, index: Int)? {
        for (r, row) in rows.enumerated() {
            if let i = row.firstIndex(of: widget) { return (r, i) }
        }
        return nil
    }

    /// Without the section; a row it leaves empty disappears.
    func removing(_ widget: Widget) -> DashboardLayout {
        DashboardLayout(rows: rows.map { $0.filter { $0 != widget } }.filter { !$0.isEmpty }, sizes: sizes)
    }

    /// With the section put at `target`; nil when it doesn't fit there.
    func inserting(_ widget: Widget, at target: Target) -> DashboardLayout? {
        var copy = removing(widget)
        switch target {
        case .slot(let r, let i):
            guard copy.rows.indices.contains(r) else { return nil }
            var row = copy.rows[r]
            row.insert(widget, at: min(max(i, 0), row.count))
            guard copy.fits(row) else { return nil }
            copy.rows[r] = row
        case .newRow(let r):
            copy.rows.insert([widget], at: min(max(r, 0), copy.rows.count))
        }
        return copy
    }

    /// The target that leaves `widget` where it is (in `removing(widget)` terms).
    func currentTarget(of widget: Widget) -> Target? {
        guard let (r, i) = position(of: widget) else { return nil }
        return rows[r].count == 1 ? .newRow(r) : .slot(row: r, index: i)
    }

    /// The section at another size. When its row no longer fits, the
    /// sections after it move to a row of their own below, so nothing
    /// before it moves.
    func resizing(_ widget: Widget, to size: Size) -> DashboardLayout {
        guard widget.sizes.contains(size) else { return self }
        var copy = self
        copy.sizes[widget] = size
        guard let (r, _) = copy.position(of: widget), !copy.fits(copy.rows[r]) else { return copy }
        let row = copy.rows.remove(at: r)
        var split = DashboardLayout(rows: [], sizes: copy.sizes)
        split.appendSplit(row)
        copy.rows.insert(contentsOf: split.rows, at: r)
        return copy
    }
}

extension DashboardPrefs {
    /// Like macOS widgets: small = 1 column, medium = 2, large = the whole row.
    enum WidgetSize: String, CaseIterable, Codable {
        case small, medium, large

        var span: Int {
            switch self {
            case .small: 1
            case .medium: 2
            case .large: DashboardLayout.columns
            }
        }
    }
}

extension DashboardPrefs.Widget {
    typealias Size = DashboardPrefs.WidgetSize

    /// The sizes the section offers (the spend chart, My cards and
    /// Services have no small size).
    var sizes: [Size] {
        switch self {
        case .customCards, .costTrend, .services: [.medium, .large]
        default: Size.allCases
        }
    }

    var defaultSize: Size {
        switch self {
        case .resourcesKpi, .activeKpi, .costKpi, .attentionKpi: .small
        case .customCards, .services: .large
        case .distribution, .topServices, .costTrend, .costByService: .medium
        }
    }

    var isKPI: Bool {
        switch self {
        case .resourcesKpi, .activeKpi, .costKpi, .attentionKpi: true
        default: false
        }
    }

    /// About how tall the section is drawn at a size (the dashboard's
    /// minimum height, and the layout editor's tiles scaled down) - so the
    /// editor shows real proportions.
    func height(_ size: Size) -> CGFloat {
        switch (self, size) {
        case (.resourcesKpi, .large), (.activeKpi, .large), (.costKpi, .large), (.attentionKpi, .large): 240
        case (.resourcesKpi, _), (.activeKpi, _), (.costKpi, _), (.attentionKpi, _): 135
        case (.distribution, .small): 240
        case (.distribution, _): 350
        case (.topServices, .small): 210
        case (.topServices, _): 355
        case (.costByService, .small): 220
        case (.costByService, _): size == .large ? 380 : 300
        case (.costTrend, .large): 415
        case (.costTrend, _): 315
        case (.customCards, _): 200
        case (.services, _): 420
        }
    }
}
