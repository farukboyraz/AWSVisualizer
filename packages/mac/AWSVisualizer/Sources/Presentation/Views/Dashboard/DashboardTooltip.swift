import SwiftUI

/// The hover bubble of the dashboard charts: a short summary of the point
/// under the pointer, an arrow pointing at it, and an underlined "Details"
/// link that opens the full breakdown (`DashboardDetailSheet`). The bubble
/// stays while the pointer moves onto it, so Details can be clicked.
struct DashboardTooltipData: Equatable {
    struct Row: Equatable, Identifiable {
        var id: String { label }
        let label: String
        let value: String
        var color: Color?
    }

    let title: String
    var subtitle: String?
    var rows: [Row]
    /// What "Details" opens; nil = no link.
    var detail: DashboardDetail?
}

struct DashboardTooltipView: View {
    let data: DashboardTooltipData
    let language: AppLanguage
    var onDetails: (DashboardDetail) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(data.title).font(.callout.weight(.semibold)).lineLimit(1)
                    if let subtitle = data.subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ForEach(data.rows) { row in
                    HStack(spacing: 6) {
                        if let color = row.color {
                            Circle().fill(color).frame(width: 7, height: 7)
                        }
                        Text(row.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 10)
                        Text(row.value).font(.caption.weight(.semibold).monospacedDigit())
                    }
                }
                if let detail = data.detail {
                    Button { onDetails(detail) } label: {
                        Text(language.dashDetails)
                            .font(.caption.weight(.semibold))
                            .underline()
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(minWidth: 170, maxWidth: 260, alignment: .leading)
            .background(DashboardFormat.tooltipSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            TooltipArrow()
                .fill(DashboardFormat.tooltipSurface)
                .overlay(TooltipArrow().stroke(Color.primary.opacity(0.12), lineWidth: 1).mask(Rectangle().padding(.top, 1)))
                .frame(width: 14, height: 7)
                .offset(y: -0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .fixedSize()
    }
}

/// Downward-pointing triangle under the bubble.
struct TooltipArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

/// Keeps a hover bubble up while the pointer is on the target *or* on the
/// bubble, and hides it shortly after it leaves both.
@Observable
final class TooltipHoverState {
    var onTarget = false
    var onBubble = false
    private var hideTask: Task<Void, Never>?

    var isVisible: Bool { onTarget || onBubble || lingering }
    private var lingering = false

    func set(target: Bool) { onTarget = target; scheduleHide() }
    func set(bubble: Bool) { onBubble = bubble; scheduleHide() }

    private func scheduleHide() {
        hideTask?.cancel()
        if onTarget || onBubble { lingering = true; return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.lingering = false
        }
    }
}

/// Hover bubble above a row-like view (bars, legend rows, spend rows).
struct DashboardHoverTooltip: ViewModifier {
    let data: DashboardTooltipData
    let language: AppLanguage
    var onDetails: (DashboardDetail) -> Void

    @State private var hover = TooltipHoverState()
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { hover.set(target: $0) }
            .overlay(alignment: .top) {
                if hover.isVisible {
                    DashboardTooltipView(data: data, language: language, onDetails: onDetails)
                        .onHover { hover.set(bubble: $0) }
                        .background(GeometryReader { geo in Color.clear.onAppear { height = geo.size.height } })
                        .offset(y: -height - 2)
                        .transition(.opacity)
                }
            }
            .zIndex(hover.isVisible ? 10 : 0)
            .animation(.easeOut(duration: 0.12), value: hover.isVisible)
    }
}

extension View {
    func dashboardTooltip(_ data: DashboardTooltipData, language: AppLanguage, onDetails: @escaping (DashboardDetail) -> Void) -> some View {
        modifier(DashboardHoverTooltip(data: data, language: language, onDetails: onDetails))
    }
}

// MARK: - Details

/// What a tooltip's "Details" opens.
enum DashboardDetail: Equatable, Identifiable {
    case costPoint(date: Date)
    case costService(name: String)
    case category(name: String)
    case service(id: String)

    var id: String {
        switch self {
        case .costPoint(let date): return "cost-\(date.timeIntervalSince1970)"
        case .costService(let name): return "costService-\(name)"
        case .category(let name): return "category-\(name)"
        case .service(let id): return "service-\(id)"
        }
    }
}

/// The full breakdown behind one chart point.
struct DashboardDetailSheet: View {
    let detail: DashboardDetail
    let model: DashboardModel
    let language: AppLanguage
    var onOpen: (String) -> Void
    var onClose: () -> Void
    /// Off only for the snapshot (ImageRenderer can't draw a ScrollView).
    var scrollable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.bold())
                    if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
                }
                Spacer()
                CloseButton(language.dashClose, action: onClose).keyboardShortcut(.cancelAction)
            }
            Divider()
            if scrollable {
                ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                content.frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        .padding(22)
        .frame(width: 560, height: 520)
    }

    private var cost: DashboardModel.Cost? { model.cost }

    private var title: String {
        switch detail {
        case .costPoint(let date): return cost.map { DashboardFormat.periodLabel(date, monthly: $0.monthly, language: language) } ?? ""
        case .costService(let name): return DashboardFormat.shortServiceName(name)
        case .category(let name): return name
        case .service(let id): return model.services.first { $0.id == id }?.entry.name ?? id
        }
    }

    private var subtitle: String? {
        switch detail {
        case .costPoint: return language.dashSpendTrend
        case .costService: return language.dashSpendByService
        case .category: return language.dashDistribution
        case .service(let id): return model.services.first { $0.id == id }?.entry.category
        }
    }

    @ViewBuilder private var content: some View {
        switch detail {
        case .costPoint(let date): costPointDetail(date)
        case .costService(let name): costServiceDetail(name)
        case .category(let name): categoryDetail(name)
        case .service(let id): serviceDetail(id)
        }
    }

    // Spend of one day / month: every service that cost something.
    @ViewBuilder private func costPointDetail(_ date: Date) -> some View {
        if let cost, let point = cost.daily.first(where: { $0.date == date }) {
            let services = cost.services(on: date)
            let average = cost.dailyAverage
            VStack(alignment: .leading, spacing: 14) {
                facts([
                    (language.dashTotal, DashboardFormat.money(point.amount, currency: cost.currency)),
                    (cost.monthly ? language.dashVsMonthlyAverage : language.dashVsDailyAverage, DashboardFormat.signedPercent(point.amount, vs: average)),
                    (language.dashShareOfPeriod, DashboardFormat.percent(point.amount, of: cost.total)),
                ])
                if services.isEmpty {
                    Text(language.dashNoBreakdown).font(.callout).foregroundStyle(.secondary)
                } else {
                    amountTable(services.map { (DashboardFormat.shortServiceName($0.name), $0.amount) }, total: point.amount, currency: cost.currency)
                }
            }
        }
    }

    // One service across the period: per day / month.
    @ViewBuilder private func costServiceDetail(_ name: String) -> some View {
        if let cost {
            let total = cost.services.first { $0.name == name }?.amount ?? 0
            let series = cost.series(of: name)
            VStack(alignment: .leading, spacing: 14) {
                facts([
                    (language.dashTotal, DashboardFormat.money(total, currency: cost.currency)),
                    (language.dashShareOfPeriod, DashboardFormat.percent(total, of: cost.total)),
                    (cost.monthly ? language.dashMonthlyAverageTitle : language.dashDailyAverageTitle, DashboardFormat.money(series.isEmpty ? 0 : total / Double(series.count), currency: cost.currency)),
                ])
                if cost.breakdown.isEmpty {
                    Text(language.dashNoBreakdown).font(.callout).foregroundStyle(.secondary)
                } else {
                    amountTable(series.reversed().map { (DashboardFormat.periodLabel($0.date, monthly: cost.monthly, language: language), $0.amount) }, total: total, currency: cost.currency)
                }
            }
        }
    }

    @ViewBuilder private func categoryDetail(_ name: String) -> some View {
        if let category = model.categories.first(where: { $0.name == name }) {
            VStack(alignment: .leading, spacing: 14) {
                facts([
                    (language.dashResources, DashboardFormat.number(category.resources)),
                    (language.dashShareOfResources, DashboardFormat.percent(Double(category.resources), of: Double(model.totalResources))),
                    (language.dashServices, "\(category.services.count)"),
                ])
                ForEach(category.services.sorted { ($0.count ?? -1) > ($1.count ?? -1) }) { service in
                    serviceRow(service)
                }
            }
        }
    }

    @ViewBuilder private func serviceDetail(_ id: String) -> some View {
        if let service = model.services.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 14) {
                facts([
                    (language.dashResources, service.count.map(DashboardFormat.number) ?? "—"),
                    (language.dashShareOfResources, DashboardFormat.percent(Double(service.count ?? 0), of: Double(model.totalResources))),
                    (language.dashRank, model.topServices.firstIndex { $0.id == id }.map { "#\($0 + 1)" } ?? "—"),
                ])
                serviceRow(service)
            }
        }
    }

    private func serviceRow(_ service: DashboardModel.Service) -> some View {
        HStack(spacing: 10) {
            Image(systemName: service.entry.icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(service.entry.tint)
                .frame(width: 28, height: 28)
                .background(service.entry.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(service.entry.name)
            Spacer()
            Text(language.dashResourceCount(service.count)).monospacedDigit().foregroundStyle(.secondary)
            OpenButton(compactSize: 22, help: language.dashOpen) { onOpen(service.id); onClose() }
        }
    }

    private func facts(_ items: [(String, String)]) -> some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.0.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.tertiary)
                    Text(item.1).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit()
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func amountTable(_ rows: [(String, Double)], total: Double, currency: String) -> some View {
        let maxAmount = rows.map(\.1).max() ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Text(row.0).font(.callout).lineLimit(1).frame(width: 210, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(Color(hex: "#10B981").opacity(0.8))
                            .frame(width: max(3, geo.size.width * row.1 / max(maxAmount, 0.0001)))
                    }
                    .frame(height: 6)
                    Text(DashboardFormat.money(row.1, currency: currency)).font(.callout.monospacedDigit()).frame(width: 90, alignment: .trailing)
                    Text(DashboardFormat.percent(row.1, of: total)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
}
