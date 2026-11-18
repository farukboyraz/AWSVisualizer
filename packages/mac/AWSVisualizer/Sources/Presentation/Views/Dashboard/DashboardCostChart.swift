import SwiftUI
import Charts

/// The spend chart of the dashboard.
///
/// - Series: the 4 most expensive services of the period plus "Other"
///   (from the per-day / per-month breakdown; just "Total" when an older
///   answer has none).
/// - Style: bars (stacked), lines or points - switched with the icons in
///   the panel header, default in Settings › Display › Dashboard.
/// - A dashed average line labelled at its right end, axis titles and a
///   legend underneath.
/// - Single color (the switch in the panel header; its default in Settings ›
///   Display › Dashboard): only the total, in green; the tooltip and the
///   period window still show each service in its own series color.
/// - Hover: only while the pointer is on a bar (its own width and height)
///   or within 12 pt of a point - not "the nearest period" anywhere in the
///   plot, which jumped to the next period halfway between two. Then a
///   dashed crosshair, the period's axis label in a pill, the other periods
///   dimmed and a tooltip (header band, each series' amount and share)
///   whose arrow points at the period.
/// - Click on a bar / point: `onSelectPeriod` (the period's detail window).
struct DashboardCostChart: View {
    let cost: DashboardModel.Cost
    let style: DashboardPrefs.ChartStyle
    let language: AppLanguage
    /// Snapshot only: shows the tooltip of this period without hovering.
    var pinned: Date? = nil
    /// One color: the total only (Settings › Display › Dashboard).
    var singleColor = false
    /// Off while the spend settings popover is open: no tooltip, no highlight.
    var isInteractive = true
    /// A bar / point was clicked.
    var onSelectPeriod: (Date) -> Void = { _ in }

    @State private var selected: Date?
    @State private var hover = TooltipHoverState()

    private var shownSelection: Date? { pinned ?? (isInteractive && hover.isVisible ? selected : nil) }

    /// Lines / points also draw the total, so the average line has its counterpart.
    static let totalColor = Color(hex: "#EC4899")
    /// The single-color chart's color.
    static let singleColorValue = Color(hex: "#10B981")
    private let averageColor = Color(hex: "#D97706")
    private let crosshairColor = Color(hex: "#3B82F6")

    // MARK: Data

    struct Point: Identifiable {
        let date: Date
        let series: String
        let amount: Double
        var id: String { "\(date.timeIntervalSince1970)|\(series)" }
    }

    /// Top 4 services by spend in the period, then "Other".
    private var seriesNames: [String] {
        guard !cost.breakdown.isEmpty else { return [language.dashTotal] }
        let top = cost.services.sorted { $0.amount > $1.amount }.prefix(4).map(\.name)
        let hasOther = cost.daily.contains { point in
            point.amount - cost.services(on: point.date).filter { top.contains($0.name) }.reduce(0) { $0 + $1.amount } > 0.005
        }
        return top + (hasOther ? [language.dashOther] : [])
    }

    /// Bars stack to the total by themselves; lines and points add it as its own series.
    private var drawsTotal: Bool { style != .bar && !cost.breakdown.isEmpty && !singleColor }
    private var drawnSeries: [String] { singleColor ? [language.dashTotal] : (drawsTotal ? [language.dashTotal] : []) + seriesNames }
    /// What a series is drawn in.
    private func color(_ name: String) -> Color {
        if singleColor { return Self.singleColorValue }
        if name == language.dashTotal && drawsTotal { return Self.totalColor }
        return seriesColor(name)
    }

    /// A series' own color - the service's fixed one (`DashboardServiceColor`),
    /// grey for "Other"; also in single-color mode, for the tooltip.
    private func seriesColor(_ name: String) -> Color {
        if name == language.dashOther { return DashboardServiceColor.other }
        if name == language.dashTotal { return Self.singleColorValue }
        return DashboardServiceColor.color(for: name)
    }

    /// Per service of the series (and "Other"), each period - never the total.
    private var seriesPoints: [Point] {
        let names = seriesNames
        guard !cost.breakdown.isEmpty else { return cost.daily.map { Point(date: $0.date, series: names[0], amount: $0.amount) } }
        let top = names.filter { $0 != language.dashOther }
        return cost.daily.flatMap { day -> [Point] in
            let services = cost.services(on: day.date)
            var rows = top.map { name in Point(date: day.date, series: name, amount: services.first { $0.name == name }?.amount ?? 0) }
            if names.contains(language.dashOther) {
                rows.append(Point(date: day.date, series: language.dashOther, amount: max(0, day.amount - rows.reduce(0) { $0 + $1.amount })))
            }
            return rows
        }
    }

    private var points: [Point] {
        if singleColor { return cost.daily.map { Point(date: $0.date, series: language.dashTotal, amount: $0.amount) } }
        let names = seriesNames
        guard !cost.breakdown.isEmpty else { return cost.daily.map { Point(date: $0.date, series: names[0], amount: $0.amount) } }
        let top = names.filter { $0 != language.dashOther }
        return cost.daily.flatMap { day -> [Point] in
            let services = cost.services(on: day.date)
            var rows = top.map { name in Point(date: day.date, series: name, amount: services.first { $0.name == name }?.amount ?? 0) }
            if names.contains(language.dashOther) {
                rows.append(Point(date: day.date, series: language.dashOther, amount: max(0, day.amount - rows.reduce(0) { $0 + $1.amount })))
            }
            if drawsTotal { rows.insert(Point(date: day.date, series: language.dashTotal, amount: day.amount), at: 0) }
            return rows
        }
    }

    private var unit: Calendar.Component { cost.monthly ? .month : .day }
    private func label(_ name: String) -> String { name == language.dashOther || name == language.dashTotal ? name : DashboardFormat.shortServiceName(name) }

    // MARK: Chart

    var body: some View {
        let names = drawnSeries
        let data = points
        Chart {
            ForEach(data) { point in
                let dim = shownSelection != nil && shownSelection != point.date
                switch style {
                case .bar:
                    BarMark(x: .value("Period", point.date, unit: unit), y: .value("Spend", point.amount), width: .ratio(cost.monthly ? 0.55 : 0.75))
                        .foregroundStyle(by: .value("Series", label(point.series)))
                        .opacity(dim ? 0.35 : 1)
                case .line:
                    LineMark(x: .value("Period", point.date, unit: unit), y: .value("Spend", point.amount))
                        .foregroundStyle(by: .value("Series", label(point.series)))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: point.series == language.dashTotal ? 3 : 2, lineCap: .round, lineJoin: .round))
                        .symbol(by: .value("Series", label(point.series)))
                        .symbolSize(shownSelection == point.date ? 60 : 18)
                case .points:
                    PointMark(x: .value("Period", point.date, unit: unit), y: .value("Spend", point.amount))
                        .foregroundStyle(by: .value("Series", label(point.series)))
                        .symbolSize(shownSelection == point.date ? 110 : 45)
                        .opacity(dim ? 0.4 : 1)
                }
            }
            RuleMark(y: .value("Average", cost.dailyAverage))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(averageColor)
                .annotation(position: .top, alignment: .trailing, spacing: 2) {
                    Text("\(language.dashAverageShort): \(DashboardFormat.money(cost.dailyAverage, currency: cost.currency))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(averageColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DashboardFormat.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
                }
            if let selected = shownSelection {
                RuleMark(x: .value("Period", selected, unit: unit))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(crosshairColor.opacity(0.8))
            }
        }
        .chartForegroundStyleScale(domain: names.map(label), range: names.map(color))
        .chartLegend(position: .bottom, alignment: .center, spacing: 12)
        .chartYAxisLabel(position: .leading, alignment: .center) {
            Text("\(language.dashSpend) (\(cost.currency))").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .chartXAxisLabel(position: .bottom, alignment: .center) {
            Text(cost.monthly ? language.dashMonthAxis : language.dashDayAxis).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(DashboardFormat.money(amount, currency: cost.currency)) }
                }
            }
        }
        .chartXAxis {
            // Dates in the app's language (not the system's).
            if cost.monthly {
                AxisMarks(values: .stride(by: .month)) { value in
                    AxisValueLabel(centered: true) {
                        if let date = value.as(Date.self) { Text(DashboardFormat.axisDate(date, monthly: true, language: language)) }
                    }
                }
            } else {
                AxisMarks(values: .stride(by: .day, count: max(1, cost.daily.count / 6))) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(DashboardFormat.axisDate(date, monthly: false, language: language)) }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): select(at: location, proxy: proxy, plot: plot)
                            case .ended:
                                hover.set(target: false)
                                setPointer(false)
                            }
                        }
                        .gesture(SpatialTapGesture().onEnded { tap in
                            if isInteractive, let date = period(at: tap.location, proxy: proxy, plot: plot) { onSelectPeriod(date) }
                        })
                    if let date = shownSelection, let anchor = anchor(for: date, proxy: proxy, plot: plot) {
                        axisPill(date).position(x: anchor.x, y: plot.maxY + 13)
                        tooltip(date, anchor: anchor, width: geo.size.width)
                    }
                }
            }
        }
        .onChange(of: hover.isVisible) { _, visible in if !visible { selected = nil } }
        .onChange(of: isInteractive) { _, interactive in
            if !interactive {
                hover.set(target: false)
                setPointer(false)
            }
        }
        .zIndex(hover.isVisible ? 10 : 0)
        .environment(\.locale, language.locale)
        .animation(.easeOut(duration: 0.15), value: selected)
        .animation(.easeInOut(duration: 0.25), value: style)
    }

    // MARK: Hover

    @State private var isPointing = false

    /// The period under the pointer - only when it's on that period's bar
    /// or point, otherwise the tooltip goes away.
    private func select(at location: CGPoint, proxy: ChartProxy, plot: CGRect) {
        guard isInteractive, let date = period(at: location, proxy: proxy, plot: plot) else {
            hover.set(target: false)
            setPointer(false)
            return
        }
        selected = date
        hover.set(target: true)
        setPointer(true)
    }

    private func setPointer(_ on: Bool) {
        guard on != isPointing else { return }
        isPointing = on
        (on ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    /// Bars: the pointer inside a bar (its drawn width, from the top of the
    /// stack to the axis; at least 8 pt tall so tiny bars can be hit).
    /// Lines / points: within 12 pt of one of the period's points.
    private func period(at location: CGPoint, proxy: ChartProxy, plot: CGRect) -> Date? {
        guard plot.insetBy(dx: -6, dy: -6).contains(location) else { return nil }
        let calendar = Calendar.utc
        for point in cost.daily {
            if style == .bar {
                guard let next = calendar.date(byAdding: unit, value: 1, to: point.date),
                      let x0 = proxy.position(forX: point.date), let x1 = proxy.position(forX: next),
                      let top = proxy.position(forY: point.amount), let bottom = proxy.position(forY: 0.0) else { continue }
                let ratio: CGFloat = cost.monthly ? 0.55 : 0.75
                let center = plot.minX + (x0 + x1) / 2
                let half = max(abs(x1 - x0) * ratio / 2, 3)
                let yTop = plot.minY + min(top, bottom - 8)
                let yBottom = plot.minY + bottom
                if abs(location.x - center) <= half, location.y >= yTop - 2, location.y <= yBottom + 2 { return point.date }
            } else if let anchor = anchor(for: point.date, proxy: proxy, plot: plot) {
                let amounts = points.filter { $0.date == point.date }.map(\.amount)
                for amount in amounts {
                    guard let y = proxy.position(forY: amount) else { continue }
                    let dx = location.x - anchor.x, dy = location.y - (plot.minY + y)
                    if dx * dx + dy * dy <= 144 { return point.date }
                }
            }
        }
        return nil
    }

    /// Where the period is drawn: its center, at the top of what's drawn
    /// there (the stacked total for bars, the highest series otherwise).
    private func anchor(for date: Date, proxy: ChartProxy, plot: CGRect) -> CGPoint? {
        guard let point = cost.daily.first(where: { $0.date == date }) else { return nil }
        let center: Date
        if style == .bar, let next = Calendar.utc.date(byAdding: unit, value: 1, to: date) {
            center = Date(timeIntervalSince1970: (date.timeIntervalSince1970 + next.timeIntervalSince1970) / 2)
        } else {
            center = cost.monthly ? date.addingTimeInterval(15 * 86_400) : date
        }
        let top = style == .bar ? point.amount : (points.filter { $0.date == date }.map(\.amount).max() ?? point.amount)
        guard let x = proxy.position(forX: center), let y = proxy.position(forY: top) else { return nil }
        return CGPoint(x: plot.minX + x, y: plot.minY + y)
    }

    /// The selected period's axis label, in a pill under the plot.
    private func axisPill(_ date: Date) -> some View {
        Text(DashboardFormat.periodLabel(date, monthly: cost.monthly, language: language))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(crosshairColor, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize()
            .allowsHitTesting(false)
    }

    /// Right above the period with its arrow pointing down at it - below
    /// (arrow up) only when even the panel header can't take it. Placed
    /// with alignment guides on a point at the period, so it uses its real
    /// size at layout time (no measuring, no first-frame jump); kept inside
    /// the chart's width.
    @ViewBuilder private func tooltip(_ date: Date, anchor: CGPoint, width: CGFloat) -> some View {
        if let index = cost.daily.firstIndex(where: { $0.date == date }) {
            let rows = tooltipRows(index)
            let estimatedHeight = 78 + CGFloat(rows.count) * 29
            let above = anchor.y - estimatedHeight - 10 >= -260
            Color.clear
                .frame(width: 0, height: 0)
                .overlay(alignment: above ? .bottom : .top) {
                    DashboardCostTooltip(
                        title: DashboardFormat.periodLabel(date, monthly: cost.monthly, language: language),
                        total: cost.daily[index].amount,
                        rows: rows,
                        currency: cost.currency,
                        language: language,
                        anchorX: anchor.x,
                        containerWidth: width,
                        arrowOnTop: !above
                    )
                    .allowsHitTesting(false)
                    .alignmentGuide(HorizontalAlignment.center) { d in anchor.x - DashboardCostTooltip.left(anchorX: anchor.x, width: d.width, containerWidth: width) }
                    .alignmentGuide(VerticalAlignment.bottom) { d in d[.bottom] + 10 }
                    .alignmentGuide(VerticalAlignment.top) { d in d[.top] - 10 }
                }
                .position(x: anchor.x, y: anchor.y)
                .transition(.opacity)
        }
    }

    /// Each series' amount in the period, in its own color - also when the
    /// chart itself is single-color.
    private func tooltipRows(_ index: Int) -> [DashboardCostTooltip.Row] {
        let date = cost.daily[index].date
        let all = seriesPoints
        return seriesNames.map { name in
            DashboardCostTooltip.Row(name: label(name), color: seriesColor(name), amount: all.first { $0.date == date && $0.series == name }?.amount ?? 0)
        }
    }
}

/// The tooltip of the spend chart: a header band with the period and its
/// total, each series' amount and share, a small arrow at the period and a
/// "click for details" hint (it doesn't take the pointer itself).
struct DashboardCostTooltip: View {
    struct Row: Identifiable {
        let name: String
        let color: Color?
        let amount: Double
        var id: String { name }
    }

    let title: String
    let total: Double
    let rows: [Row]
    let currency: String
    let language: AppLanguage
    /// Where the period is, and how wide the chart is (chart coordinates).
    let anchorX: CGFloat
    let containerWidth: CGFloat
    let arrowOnTop: Bool

    private let header = LinearGradient(colors: [Color(hex: "#1E3A8A"), Color(hex: "#312E81")], startPoint: .leading, endPoint: .trailing)

    /// The bubble's left edge: centered on the period, kept inside the chart.
    static func left(anchorX: CGFloat, width: CGFloat, containerWidth: CGFloat) -> CGFloat {
        min(max(anchorX - width / 2, 2), max(containerWidth - width - 2, 2))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(.white.opacity(0.7)).frame(width: 7, height: 7)
                Text(title).font(.callout.weight(.bold)).foregroundStyle(.white)
                Spacer(minLength: 14)
                Text(DashboardFormat.money(total, currency: currency)).font(.callout.weight(.bold).monospacedDigit()).foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(header)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(row.color ?? .gray).frame(width: 3, height: 16)
                        Text(row.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 16)
                        Text(DashboardFormat.money(row.amount, currency: currency)).font(.caption.weight(.bold).monospacedDigit())
                        Text(DashboardFormat.percent(row.amount, of: total)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // The bar / point itself opens the details (no link to chase).
            HStack(spacing: 5) {
                Image(systemName: "cursorarrow.click").font(.caption2)
                Text(language.dashChartClickHint).font(.caption2)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 9)
        }
        .frame(minWidth: 260)
        .background(DashboardFormat.tooltipSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
        // The arrow, from the bubble's real width: at the period, clear of the corners.
        .overlay {
            GeometryReader { g in
                let left = Self.left(anchorX: anchorX, width: g.size.width, containerWidth: containerWidth)
                let x = min(max(anchorX - left, 18), g.size.width - 18)
                TooltipArrow()
                    .fill(arrowOnTop ? AnyShapeStyle(header) : AnyShapeStyle(DashboardFormat.tooltipSurface))
                    .frame(width: 16, height: 8)
                    .rotationEffect(.degrees(arrowOnTop ? 180 : 0))
                    .position(x: x, y: arrowOnTop ? -3.5 : g.size.height + 3.5)
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
        .fixedSize()
    }
}

private extension Calendar {
    /// Gregorian in UTC - Cost Explorer's days and months.
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
