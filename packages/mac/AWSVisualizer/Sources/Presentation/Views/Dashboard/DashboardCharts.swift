import SwiftUI
import Charts

// MARK: - Resources by category (donut + legend)

/// The ring and its legend. Pointing at a slice or a legend row highlights
/// that category and shows its number in the middle; no popups.
struct DashboardCategoryDonut: View {
    let categories: [DashboardModel.Category]
    let total: Int
    let language: AppLanguage
    /// Diameter; small sections draw the ring alone, large ones a two-column legend.
    var size: CGFloat = 200
    var legendLimit = 11
    var legendColumns = 1

    @State private var hovered: DashboardModel.Category?

    private var slices: [DashboardModel.Category] {
        categories.filter { $0.resources > 0 }.sorted { $0.resources > $1.resources }
    }

    var body: some View {
        if slices.isEmpty {
            DashboardEmptyChart(icon: "chart.pie", message: language.dashNoResources)
        } else {
            HStack(alignment: .center, spacing: 22) {
                Chart(slices) { category in
                    let shape = sliceShape(category)
                    SectorMark(
                        angle: .value("Resources", category.resources),
                        innerRadius: .ratio(0.64),
                        outerRadius: .ratio(hovered?.id == category.id ? 1 : 0.94),
                        angularInset: shape.inset
                    )
                    .cornerRadius(shape.corner)
                    .foregroundStyle(category.color.gradient)
                    .opacity(hovered == nil || hovered?.id == category.id ? 1 : 0.45)
                }
                .chartLegend(.hidden)
                .frame(width: size, height: size)
                // Never morph the slices: an animated data change passes through
                // slices thinner than their insets / corners (see `sliceShape`).
                .transaction { $0.animation = nil }
                .overlay {
                    VStack(spacing: 0) {
                        Text(DashboardFormat.number(hovered?.resources ?? total))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .dashboardLoadingBlur()
                        Text(hovered?.name ?? language.dashResources)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 96)
                            .dashboardLoadingBlur()
                    }
                    .allowsHitTesting(false)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hovered = slice(at: location)
                    case .ended: hovered = nil
                    }
                }

                if legendLimit > 0 {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: legendColumns), alignment: .leading, spacing: 9) {
                        ForEach(slices.prefix(legendLimit)) { category in
                            HStack(spacing: 8) {
                                Circle().fill(category.color).frame(width: 8, height: 8)
                                Text(category.name)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .dashboardLoadingBlur()
                                Spacer(minLength: 8)
                                Text(DashboardFormat.number(category.resources))
                                    .font(.callout.weight(.semibold))
                                    .monospacedDigit()
                                    .dashboardLoadingBlur()
                                Text(DashboardFormat.percent(Double(category.resources), of: Double(total)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                                    .dashboardLoadingBlur()
                            }
                            .contentShape(Rectangle())
                            .onHover { hovered = $0 ? category : nil }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Gap and corner rounding for a slice, only as big as the slice allows.
    /// Swift Charts traps (NaN sector geometry, `acos` out of range) when a
    /// slice's arc is narrower than its two gaps plus rounded corners - e.g.
    /// 1 resource next to hundreds, or a lone slice (a full ring has no edges).
    private func sliceShape(_ category: DashboardModel.Category) -> (inset: CGFloat, corner: CGFloat) {
        let sum = slices.reduce(0) { $0 + $1.resources }
        guard slices.count > 1, sum > 0 else { return (0, 0) }
        let fraction = Double(category.resources) / Double(sum)
        // Arc length on the inner edge (the narrowest), in points.
        let innerArc = 2 * Double.pi * Double(size) / 2 * 0.94 * 0.64 * fraction
        if innerArc >= 24 { return (1.5, 4) }
        if innerArc >= 10 { return (1, 1.5) }
        return (0, 0)
    }

    /// Which slice the pointer is on: Swift Charts draws sectors clockwise
    /// from 12 o'clock in data order.
    private func slice(at point: CGPoint) -> DashboardModel.Category? {
        let center = CGPoint(x: size / 2, y: size / 2)
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let outer = size / 2
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

/// Hovering a row outlines it; a click opens the service.
struct DashboardTopServicesChart: View {
    let services: [DashboardModel.Service]
    let language: AppLanguage
    var onOpen: (String) -> Void = { _ in }
    /// Two columns in a large section.
    var columns = 1

    var body: some View {
        if services.isEmpty {
            DashboardEmptyChart(icon: "chart.bar", message: language.dashNoResources)
        } else {
            let maxCount = services.compactMap(\.count).max() ?? 1
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22, alignment: .top), count: columns), alignment: .leading, spacing: 11) {
                ForEach(services) { service in
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
                                    Text(service.entry.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .dashboardLoadingBlur()
                                    Spacer(minLength: 8)
                                    Text(DashboardFormat.number(service.count ?? 0))
                                        .font(.callout.weight(.semibold).monospacedDigit())
                                        .dashboardLoadingBlur()
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
                        .dashboardRowHover(tint: service.entry.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Spend by service (ranked bars)

/// Each service in its own color. Hovering a row outlines it; a click
/// reports the service (nil = the "Other" row).
struct DashboardSpendByService: View {
    let cost: DashboardModel.Cost
    let language: AppLanguage
    /// Rows shown (the last one sums the rest as "Other"), and columns.
    var limit = 6
    var columns = 1
    var onSelect: (String?) -> Void = { _ in }

    private var rows: [(name: String, amount: Double, isOther: Bool)] {
        let sorted = cost.services.sorted { $0.amount > $1.amount }
        guard sorted.count > limit else { return sorted.map { ($0.name, $0.amount, false) } }
        let rest = sorted.dropFirst(limit - 1).reduce(0) { $0 + $1.amount }
        return sorted.prefix(limit - 1).map { ($0.name, $0.amount, false) } + [(language.dashOther, rest, true)]
    }

    var body: some View {
        if rows.isEmpty {
            DashboardEmptyChart(icon: "dollarsign.circle", message: language.dashNoSpend)
        } else {
            let maxAmount = rows.map(\.amount).max() ?? 1
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22, alignment: .top), count: columns), alignment: .leading, spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let color = row.isOther ? DashboardServiceColor.other : DashboardServiceColor.color(for: row.name)
                    Button { onSelect(row.isOther ? nil : row.name) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(DashboardFormat.shortServiceName(row.name))
                                    .font(.callout)
                                    .lineLimit(1)
                                    .dashboardLoadingBlur()
                                Spacer(minLength: 8)
                                Text(DashboardFormat.money(row.amount, currency: cost.currency))
                                    .font(.callout.weight(.semibold).monospacedDigit())
                                    .dashboardLoadingBlur()
                                Text(DashboardFormat.percent(row.amount, of: cost.total))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                                    .dashboardLoadingBlur()
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
                        .dashboardRowHover(tint: color)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
