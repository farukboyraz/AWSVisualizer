import SwiftUI
import Charts

/// Every chart here shows a hover bubble (`DashboardTooltipView`) with a
/// summary of the point under the pointer and a "Details" link; `onDetails`
/// opens the full breakdown.

// MARK: - Resources by category (donut + legend)

struct DashboardCategoryDonut: View {
    let categories: [DashboardModel.Category]
    let total: Int
    let language: AppLanguage
    var onDetails: (DashboardDetail) -> Void = { _ in }

    @State private var hovered: DashboardModel.Category?
    @State private var pointer: CGPoint = .zero
    @State private var hover = TooltipHoverState()
    @State private var bubbleHeight: CGFloat = 0

    private var slices: [DashboardModel.Category] {
        categories.filter { $0.resources > 0 }.sorted { $0.resources > $1.resources }
    }

    private static let size: CGFloat = 170

    var body: some View {
        if slices.isEmpty {
            DashboardEmptyChart(icon: "chart.pie", message: language.dashNoResources)
        } else {
            HStack(alignment: .center, spacing: 22) {
                Chart(slices) { category in
                    SectorMark(
                        angle: .value("Resources", category.resources),
                        innerRadius: .ratio(0.64),
                        outerRadius: .ratio(hovered?.id == category.id ? 1 : 0.94),
                        angularInset: 1.5
                    )
                    .cornerRadius(4)
                    .foregroundStyle(category.color.gradient)
                    .opacity(hovered == nil || hovered?.id == category.id ? 1 : 0.45)
                }
                .chartLegend(.hidden)
                .frame(width: Self.size, height: Self.size)
                .overlay {
                    VStack(spacing: 0) {
                        Text(DashboardFormat.number(hovered?.resources ?? total))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(hovered?.name ?? language.dashResources)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 96)
                    }
                    .allowsHitTesting(false)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        pointer = location
                        if let slice = slice(at: location) {
                            hovered = slice
                            hover.set(target: true)
                        } else {
                            hover.set(target: false)
                        }
                    case .ended:
                        hover.set(target: false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if hover.isVisible, let category = hovered {
                        DashboardTooltipView(data: tooltip(category), language: language, onDetails: onDetails)
                            .onHover { hover.set(bubble: $0) }
                            .background(GeometryReader { geo in Color.clear.onAppear { bubbleHeight = geo.size.height }.onChange(of: geo.size.height) { _, h in bubbleHeight = h } })
                            .alignmentGuide(.leading) { d in d.width / 2 - pointer.x }
                            .alignmentGuide(.top) { _ in bubbleHeight + 4 - pointer.y }
                            .zIndex(10)
                    }
                }
                .onChange(of: hover.isVisible) { _, visible in if !visible { hovered = nil } }
                .zIndex(hover.isVisible ? 10 : 0)

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(slices.prefix(7)) { category in
                        HStack(spacing: 8) {
                            Circle().fill(category.color).frame(width: 8, height: 8)
                            Text(category.name)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(DashboardFormat.number(category.resources))
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                            Text(DashboardFormat.percent(Double(category.resources), of: Double(total)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                        .dashboardTooltip(tooltip(category), language: language, onDetails: onDetails)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func tooltip(_ category: DashboardModel.Category) -> DashboardTooltipData {
        let top = category.services.filter { ($0.count ?? 0) > 0 }.sorted { ($0.count ?? 0) > ($1.count ?? 0) }.prefix(3)
        return DashboardTooltipData(
            title: category.name,
            subtitle: "\(DashboardFormat.number(category.resources)) · \(DashboardFormat.percent(Double(category.resources), of: Double(total)))",
            rows: top.map { .init(label: $0.entry.name, value: DashboardFormat.number($0.count ?? 0), color: $0.entry.tint) },
            detail: .category(name: category.name)
        )
    }

    /// Which slice the pointer is on: Swift Charts draws sectors clockwise
    /// from 12 o'clock in data order.
    private func slice(at point: CGPoint) -> DashboardModel.Category? {
        let center = CGPoint(x: Self.size / 2, y: Self.size / 2)
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let outer = Self.size / 2
        guard distance <= outer, distance >= outer * 0.6 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let fraction = angle / (2 * .pi)
        let sum = Double(slices.reduce(0) { $0 + $1.resources })
        var running = 0.0
        for slice in slices {
            running += Double(slice.resources) / sum
            if fraction <= running { return slice }
        }
        return slices.last
    }
}

// MARK: - Largest services (horizontal bars)

struct DashboardTopServicesChart: View {
    let services: [DashboardModel.Service]
    let language: AppLanguage
    var total: Int = 0
    var onOpen: (String) -> Void = { _ in }
    var onDetails: (DashboardDetail) -> Void = { _ in }

    var body: some View {
        if services.isEmpty {
            DashboardEmptyChart(icon: "chart.bar", message: language.dashNoResources)
        } else {
            let maxCount = services.compactMap(\.count).max() ?? 1
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
                    Button { onOpen(service.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: service.entry.icon)
                                .font(.system(size: 12, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(service.entry.tint)
                                .frame(width: 26, height: 26)
                                .background(service.entry.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(service.entry.name).font(.callout).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(DashboardFormat.number(service.count ?? 0))
                                        .font(.callout.weight(.semibold).monospacedDigit())
                                }
                                GeometryReader { geo in
                                    Capsule().fill(Color.primary.opacity(0.06))
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(service.entry.tint.gradient)
                                                .frame(width: max(6, geo.size.width * CGFloat(service.count ?? 0) / CGFloat(maxCount)))
                                        }
                                }
                                .frame(height: 6)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .dashboardTooltip(
                        DashboardTooltipData(
                            title: service.entry.name,
                            subtitle: service.entry.category,
                            rows: [
                                .init(label: language.dashResources, value: DashboardFormat.number(service.count ?? 0), color: service.entry.tint),
                                .init(label: language.dashShareOfResources, value: DashboardFormat.percent(Double(service.count ?? 0), of: Double(total))),
                                .init(label: language.dashRank, value: "#\(index + 1)"),
                            ],
                            detail: .service(id: service.id)
                        ),
                        language: language,
                        onDetails: onDetails
                    )
                }
            }
        }
    }
}

// MARK: - Spend trend (by day: area + line; by month: bars; dashed average)

struct DashboardSpendTrend: View {
    let cost: DashboardModel.Cost
    var compact = false
    var language: AppLanguage = .en
    var onDetails: (DashboardDetail) -> Void = { _ in }

    @State private var selected: Date?
    @State private var bubbleAnchor: CGPoint = .zero
    @State private var hover = TooltipHoverState()
    @State private var bubbleHeight: CGFloat = 0

    private let accent = Color(hex: "#10B981")

    var body: some View {
        if compact {
            chart.chartXAxis(.hidden).chartYAxis(.hidden)
        } else {
            chart
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel {
                            if let amount = value.as(Double.self) { Text(DashboardFormat.money(amount, currency: cost.currency)) }
                        }
                    }
                }
                .chartXAxis {
                    if cost.monthly {
                        AxisMarks(values: .stride(by: .month)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits), centered: true)
                        }
                    } else {
                        AxisMarks(values: .stride(by: .day, count: max(1, cost.daily.count / 6))) { _ in
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location): select(at: location, proxy: proxy, geo: geo)
                                case .ended: hover.set(target: false)
                                }
                            }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if hover.isVisible, let date = selected, let point = cost.daily.first(where: { $0.date == date }) {
                        DashboardTooltipView(data: tooltip(point), language: language, onDetails: onDetails)
                            .onHover { hover.set(bubble: $0) }
                            .background(GeometryReader { g in Color.clear.onAppear { bubbleHeight = g.size.height }.onChange(of: g.size.height) { _, h in bubbleHeight = h } })
                            .alignmentGuide(.leading) { d in d.width / 2 - bubbleAnchor.x }
                            .alignmentGuide(.top) { _ in bubbleHeight + 6 - bubbleAnchor.y }
                    }
                }
                .onChange(of: hover.isVisible) { _, visible in if !visible { selected = nil } }
                .zIndex(hover.isVisible ? 10 : 0)
                .environment(\.locale, language.locale)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(cost.daily, id: \.date) { point in
                if cost.monthly {
                    BarMark(x: .value("Month", point.date, unit: .month), y: .value("Spend", point.amount), width: .ratio(0.55))
                        .cornerRadius(5)
                        .foregroundStyle(LinearGradient(colors: [accent, accent.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                        .opacity(selected == nil || selected == point.date ? 1 : 0.5)
                } else {
                    AreaMark(x: .value("Day", point.date, unit: .day), y: .value("Spend", point.amount))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [accent.opacity(0.32), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Day", point.date, unit: .day), y: .value("Spend", point.amount))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: compact ? 1.6 : 2.2, lineCap: .round))
                        .foregroundStyle(accent)
                }
            }
            if !compact {
                RuleMark(y: .value("Average", cost.dailyAverage))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
            }
            if let date = selected, let point = cost.daily.first(where: { $0.date == date }), !cost.monthly {
                RuleMark(x: .value("Day", point.date, unit: .day))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(accent.opacity(0.5))
                PointMark(x: .value("Day", point.date, unit: .day), y: .value("Spend", point.amount))
                    .symbolSize(70)
                    .foregroundStyle(accent)
            }
        }
    }

    /// Nearest point to the pointer; the bubble's arrow points at its top.
    private func select(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plot = proxy.plotFrame else { return }
        let origin = geo[plot].origin
        guard let date: Date = proxy.value(atX: location.x - origin.x) else { return }
        guard let nearest = cost.daily.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) else { return }
        // Bars are centered on the month, lines on the day's start.
        let center = cost.monthly ? nearest.date.addingTimeInterval(15 * 86_400) : nearest.date
        let x = (proxy.position(forX: center) ?? 0) + origin.x
        let y = (proxy.position(forY: nearest.amount) ?? 0) + origin.y
        selected = nearest.date
        bubbleAnchor = CGPoint(x: x, y: y)
        hover.set(target: true)
    }

    private func tooltip(_ point: (date: Date, amount: Double)) -> DashboardTooltipData {
        let top = cost.services(on: point.date).prefix(3)
        return DashboardTooltipData(
            title: DashboardFormat.periodLabel(point.date, monthly: cost.monthly, language: language),
            subtitle: "\(DashboardFormat.money(point.amount, currency: cost.currency)) · \(DashboardFormat.signedPercent(point.amount, vs: cost.dailyAverage)) \(cost.monthly ? language.dashVsMonthlyAverageShort : language.dashVsDailyAverageShort)",
            rows: top.map { .init(label: DashboardFormat.shortServiceName($0.name), value: DashboardFormat.money($0.amount, currency: cost.currency)) },
            detail: .costPoint(date: point.date)
        )
    }
}

// MARK: - Spend by service (ranked bars)

struct DashboardSpendByService: View {
    let cost: DashboardModel.Cost
    let language: AppLanguage
    var onDetails: (DashboardDetail) -> Void = { _ in }

    private static let palette = ["#10B981", "#3B82F6", "#8B5CF6", "#F59E0B", "#EC4899", "#94A3B8"].map { Color(hex: $0) }

    private var rows: [(name: String, amount: Double, isOther: Bool)] {
        let sorted = cost.services.sorted { $0.amount > $1.amount }
        guard sorted.count > 6 else { return sorted.map { ($0.name, $0.amount, false) } }
        let rest = sorted.dropFirst(5).reduce(0) { $0 + $1.amount }
        return sorted.prefix(5).map { ($0.name, $0.amount, false) } + [(language.dashOther, rest, true)]
    }

    var body: some View {
        if rows.isEmpty {
            DashboardEmptyChart(icon: "dollarsign.circle", message: language.dashNoSpend)
        } else {
            let maxAmount = rows.map(\.amount).max() ?? 1
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let color = Self.palette[min(index, Self.palette.count - 1)]
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(DashboardFormat.shortServiceName(row.name))
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(DashboardFormat.money(row.amount, currency: cost.currency))
                                .font(.callout.weight(.semibold).monospacedDigit())
                            Text(DashboardFormat.percent(row.amount, of: cost.total))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                        GeometryReader { geo in
                            Capsule().fill(Color.primary.opacity(0.06))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(color.gradient)
                                        .frame(width: max(6, geo.size.width * row.amount / maxAmount))
                                }
                        }
                        .frame(height: 6)
                    }
                    .dashboardTooltip(tooltip(row, color: color), language: language, onDetails: onDetails)
                }
            }
        }
    }

    private func tooltip(_ row: (name: String, amount: Double, isOther: Bool), color: Color) -> DashboardTooltipData {
        let series = row.isOther ? [] : cost.series(of: row.name)
        let peak = series.max { $0.amount < $1.amount }
        var rows: [DashboardTooltipData.Row] = [
            .init(label: language.dashTotal, value: DashboardFormat.money(row.amount, currency: cost.currency), color: color),
            .init(label: language.dashShareOfPeriod, value: DashboardFormat.percent(row.amount, of: cost.total)),
        ]
        if let peak, peak.amount > 0 {
            rows.append(.init(label: cost.monthly ? language.dashPeakMonth : language.dashPeakDay, value: "\(DashboardFormat.periodLabel(peak.date, monthly: cost.monthly, language: language)) · \(DashboardFormat.money(peak.amount, currency: cost.currency))"))
        }
        return DashboardTooltipData(
            title: DashboardFormat.shortServiceName(row.name),
            subtitle: nil,
            rows: rows,
            detail: row.isOther ? nil : .costService(name: row.name)
        )
    }
}

struct DashboardEmptyChart: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }
}
