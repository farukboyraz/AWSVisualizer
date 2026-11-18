import SwiftUI

/// What a KPI card's click opens:
/// - Resources: every service, most resources first;
/// - Active services: the services that have resources, most first;
/// - Spend: by month (newest first, each month's total on the right and its
///   services under it, most expensive first) or All (services over the
///   whole period) - the switch shows only when the data spans more than one month;
/// - One spend period (a click on the spend chart's bar / point): its
///   services, most expensive first;
/// - One service's spend (a click in spend by service): the same window as
///   Spend, listing that service's months / days, newest first;
/// - Needs attention: services whose packages are missing (Install) and
///   services whose count failed (open the service to see why).
/// A service row opens that service's screen.
struct DashboardKPIDetailSheet: View {
    let detail: DashboardKPIDetail
    let model: DashboardModel
    let language: AppLanguage
    /// "Last 30 days" / "Last 6 months" / a month.
    let costTitle: String
    var onOpen: (String) -> Void
    var onInstall: ([String]) -> Void
    var onClose: () -> Void

    @State private var search = ""
    @State private var costMode: CostMode = .byMonth
    /// Open months in the Month based tree; nil = only the newest one.
    @State private var expandedMonths: Set<String>?

    enum CostMode: Hashable { case byMonth, all }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title).font(.title2.bold()).lineLimit(1)
                        if serviceName != nil {
                            Text("(\(costTitle))").italic().foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
                }
                Spacer()
                CloseButton(compactSize: 28, help: language.dashClose, action: onClose).keyboardShortcut(.cancelAction)
            }
            toolbar
            Divider()
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
            }
        }
        .padding(22)
        .frame(width: 640, height: 600)
    }

    private var title: String {
        switch detail {
        case .resources: language.dashResources
        case .active: language.dashActive
        case .cost: costTitle
        case .attention: language.dashAttention
        case .costPeriod(let date): model.cost.map { DashboardFormat.periodLabel(date, monthly: $0.monthly, language: language) } ?? ""
        case .costService(let name): DashboardFormat.shortServiceName(name)
        }
    }

    /// The service of a `.costService` window.
    private var serviceName: String? {
        if case .costService(let name) = detail { return name }
        return nil
    }

    /// Spend and one service's spend share their toolbar and tree.
    private var isSpendList: Bool { detail == .cost || serviceName != nil }

    /// What the list adds up to.
    private var spendTotal: Double? {
        guard let cost = model.cost else { return nil }
        guard let serviceName else { return cost.total }
        return cost.services.first { $0.name == serviceName }?.amount ?? months.reduce(0) { $0 + $1.total }
    }

    /// The spend window has none: its filters sit right under the title.
    private var subtitle: String? {
        switch detail {
        case .resources: language.dashResourcesDetailSubtitle
        case .active: language.dashActiveDetailSubtitle
        case .cost, .costService: nil
        case .attention: language.dashAttentionDetailSubtitle
        case .costPeriod: language.dashCostPeriodSubtitle
        }
    }

    @ViewBuilder private var toolbar: some View {
        HStack(spacing: 10) {
            if isSpendList {
                // Left: expand / collapse all, middle: Month based / All, right: total.
                // The side columns always take their share (also when empty, e.g.
                // no expand button under All), so the switch stays in the middle.
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: Self.segmentHeight, maxHeight: Self.segmentHeight)
                    .overlay(alignment: .leading) {
                        if showsCostSwitch && costMode == .byMonth { expandAllButton }
                    }
                if showsCostSwitch {
                    MultiSwitchBox(selection: $costMode, options: [(.byMonth, language.dashCostDetailByMonth), (.all, language.dashCostDetailAll)], segmentWidth: Self.segmentWidth, height: Self.segmentHeight)
                }
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: Self.segmentHeight, maxHeight: Self.segmentHeight)
                    .overlay(alignment: .trailing) { totalText(spendTotal) }
            } else if case .costPeriod(let date) = detail {
                Spacer()
                totalText(model.cost?.daily.first { $0.date == date }?.amount)
            } else {
                TextField(language.dashSearchServices, text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
                if detail == .attention, !installable.isEmpty {
                    DownloadButton(language.dashInstallAll, compactSize: 26) { onInstall(installable.map(\.id)); onClose() }
                }
            }
        }
    }

    private static let segmentWidth: CGFloat = 110
    private static let segmentHeight: CGFloat = 26

    /// Same size and track as one segment of the Month based / All switch.
    private var expandAllButton: some View {
        let open = allMonthsOpen
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { expandedMonths = open ? [] : Set(months.map(\.key)) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2.weight(.bold))
                Text(open ? language.dashCollapseAll : language.dashExpandAll).font(.caption)
            }
            .frame(width: Self.segmentWidth, height: Self.segmentHeight)
            .background(Color.secondary.opacity(0.18), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func totalText(_ amount: Double?) -> some View {
        if let amount, let cost = model.cost {
            Text("\(language.dashTotal): \(DashboardFormat.money(amount, currency: cost.currency))")
                .font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    @ViewBuilder private var content: some View {
        switch detail {
        case .costPeriod(let date):
            if let cost = model.cost {
                let services = cost.services(on: date)
                let total = cost.daily.first { $0.date == date }?.amount ?? 0
                if services.isEmpty {
                    empty(language.dashNoBreakdown)
                } else {
                    spendRows(services, total: total, currency: cost.currency)
                }
            }
        case .resources:
            serviceList(model.services.sorted { ($0.count ?? -1, $1.entry.name) > ($1.count ?? -1, $0.entry.name) })
        case .active:
            serviceList(model.services.filter { ($0.count ?? 0) > 0 }.sorted { ($0.count ?? 0) > ($1.count ?? 0) })
        case .cost, .costService:
            costContent
        case .attention:
            attentionContent
        }
    }

    // MARK: Services (resources / active)

    private func matches(_ service: DashboardModel.Service) -> Bool {
        let text = "\(service.entry.name) \(service.entry.category) \(service.id)".lowercased()
        return search.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { text.contains($0) }
    }

    @ViewBuilder private func serviceList(_ services: [DashboardModel.Service]) -> some View {
        let shown = services.filter(matches)
        let maxCount = max(services.compactMap(\.count).max() ?? 1, 1)
        if shown.isEmpty {
            empty(search.isEmpty ? language.dashNoResources : language.dashNoMatch)
        } else {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, service in
                    DashboardDetailRow(onTap: { onOpen(service.id); onClose() }) {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                        serviceIcon(service)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(service.entry.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text(service.entry.category).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(service.count.map(DashboardFormat.number) ?? "—").font(.callout.weight(.semibold)).monospacedDigit()
                                Text(DashboardFormat.percent(Double(service.count ?? 0), of: Double(model.totalResources)))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                            }
                            bar(Double(service.count ?? 0) / Double(maxCount), tint: service.entry.tint)
                        }
                    }
                }
            }
        }
    }

    // MARK: Spend

    private struct Month: Identifiable {
        let key: String
        let total: Double
        /// Under the month: its services, or for one service its days.
        let rows: [(name: String, amount: Double)]
        var id: String { key }
    }

    /// One service's periods with spend, newest first.
    private func servicePoints(_ name: String, _ cost: DashboardModel.Cost) -> [(date: Date, amount: Double)] {
        cost.series(of: name).filter { $0.amount >= 0.005 }.sorted { $0.date > $1.date }
    }

    private func periodLabel(_ date: Date, _ cost: DashboardModel.Cost) -> String {
        DashboardFormat.periodLabel(date, monthly: cost.monthly, language: language)
    }

    /// The period's points grouped by calendar month, newest first.
    private var months: [Month] {
        guard let cost = model.cost else { return [] }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone(identifier: "UTC")
        if let serviceName {
            let grouped = Dictionary(grouping: servicePoints(serviceName, cost)) { f.string(from: $0.date) }
            return grouped.keys.sorted(by: >).map { key in
                let points = grouped[key] ?? []
                return Month(
                    key: key,
                    total: points.reduce(0) { $0 + $1.amount },
                    rows: cost.monthly ? [] : points.map { (periodLabel($0.date, cost), $0.amount) }
                )
            }
        }
        var totals: [String: Double] = [:]
        var services: [String: [String: Double]] = [:]
        for point in cost.daily {
            let key = f.string(from: point.date)
            totals[key, default: 0] += point.amount
            for service in cost.services(on: point.date) {
                services[key, default: [:]][service.name, default: 0] += service.amount
            }
        }
        return totals.keys.sorted(by: >).map { key in
            Month(key: key, total: totals[key] ?? 0, rows: (services[key] ?? [:]).map { ($0.key, $0.value) }.sorted { $0.amount > $1.amount })
        }
    }

    /// Months to group by. One service by month is already a flat list of months.
    private var showsCostSwitch: Bool {
        months.count > 1 && !(serviceName != nil && model.cost?.monthly == true)
    }

    private func isExpanded(_ key: String) -> Bool {
        expandedMonths?.contains(key) ?? (key == months.first?.key)
    }

    private func toggle(_ key: String) {
        var open = expandedMonths ?? Set(months.first.map { [$0.key] } ?? [])
        if open.contains(key) { open.remove(key) } else { open.insert(key) }
        expandedMonths = open
    }

    private var allMonthsOpen: Bool { months.allSatisfy { isExpanded($0.key) } }

    @ViewBuilder private var costContent: some View {
        if let cost = model.cost {
            if cost.services.isEmpty {
                empty(language.dashNoSpend)
            } else if serviceName != nil && months.isEmpty {
                empty(language.dashNoBreakdown)
            } else if showsCostSwitch && costMode == .byMonth {
                // A tree: each month a row that opens / closes, its services under it.
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(months) { month in
                        let isOpen = isExpanded(month.key)
                        VStack(alignment: .leading, spacing: 4) {
                            Button { toggle(month.key) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                                        .frame(width: 14)
                                    Image(systemName: "calendar")
                                        .foregroundStyle(Color(hex: "#10B981"))
                                    Text(language.monthName(month.key)).font(.headline)
                                    Text(serviceName == nil ? language.dashServiceCount(month.rows.count) : language.dashDayCount(month.rows.count))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(DashboardFormat.money(month.total, currency: cost.currency)).font(.headline).monospacedDigit()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(isOpen ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if isOpen {
                                Group {
                                    if month.rows.isEmpty {
                                        Text(language.dashNoBreakdown).font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
                                    } else {
                                        spendRows(month.rows, total: month.total, currency: cost.currency)
                                    }
                                }
                                .padding(.leading, 18)
                                .overlay(alignment: .leading) {
                                    // Tree guide line from the month to its services.
                                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1).padding(.leading, 16)
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: expandedMonths)
            } else if let serviceName {
                spendRows(servicePoints(serviceName, cost).map { (periodLabel($0.date, cost), $0.amount) }, total: spendTotal ?? 0, currency: cost.currency)
            } else {
                spendRows(cost.services.sorted { $0.amount > $1.amount }, total: cost.total, currency: cost.currency)
            }
        } else {
            empty(language.dashCostFailed)
        }
    }

    /// Services (ranked, each in its fixed color) or one service's periods
    /// (in that service's color).
    private func spendRows(_ rows: [(name: String, amount: Double)], total: Double, currency: String) -> some View {
        let service = serviceName
        let maxAmount = max(rows.map(\.amount).max() ?? 1, 0.0001)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                DashboardDetailRow(onTap: nil) {
                    if service == nil {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(service == nil ? DashboardFormat.shortServiceName(row.name) : row.name).font(.callout).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(DashboardFormat.money(row.amount, currency: currency)).font(.callout.weight(.semibold)).monospacedDigit()
                            Text(DashboardFormat.percent(row.amount, of: total)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                        bar(row.amount / maxAmount, tint: DashboardServiceColor.color(for: service ?? row.name))
                    }
                }
            }
        }
    }

    // MARK: Needs attention

    private var installable: [DashboardModel.Service] {
        model.services.filter { !$0.isLoading && $0.needsInstall }
    }

    private var unreadable: [DashboardModel.Service] {
        model.services.filter { !$0.isLoading && $0.count == nil && !$0.needsInstall }
    }

    @ViewBuilder private var attentionContent: some View {
        let install = installable.filter(matches)
        let failed = unreadable.filter(matches)
        if install.isEmpty && failed.isEmpty {
            empty(search.isEmpty ? language.dashAttentionNone : language.dashNoMatch)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                if !install.isEmpty {
                    attentionGroup(language.dashAttentionInstall, hint: language.dashAttentionInstallHint, icon: "shippingbox", services: install) { service in
                        DownloadButton(language.dashInstall, compactSize: 24) { onInstall([service.id]); onClose() }
                    }
                }
                if !failed.isEmpty {
                    attentionGroup(language.dashAttentionUnreadable, hint: language.dashAttentionUnreadableHint, icon: "exclamationmark.triangle", services: failed) { service in
                        OpenButton(compactSize: 24, help: language.dashOpen) { onOpen(service.id); onClose() }
                    }
                }
            }
        }
    }

    private func attentionGroup<Action: View>(_ title: String, hint: String, icon: String, services: [DashboardModel.Service], @ViewBuilder action: @escaping (DashboardModel.Service) -> Action) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(title) · \(services.count)", systemImage: icon).font(.headline)
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(services) { service in
                    DashboardDetailRow(onTap: nil) {
                        serviceIcon(service)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(service.entry.name).font(.callout.weight(.medium))
                            Text(service.entry.category).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        action(service)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func serviceIcon(_ service: DashboardModel.Service) -> some View {
        Image(systemName: service.entry.icon)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(service.entry.tint)
            .frame(width: 28, height: 28)
            .background(service.entry.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func bar(_ fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            Capsule().fill(Color.primary.opacity(0.06))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint.gradient).frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
                }
        }
        .frame(height: 5)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
    }
}

/// A row of the KPI detail lists; highlighted on hover when it opens something.
private struct DashboardDetailRow<Content: View>: View {
    var onTap: (() -> Void)?
    @ViewBuilder var content: () -> Content

    @State private var isHovering = false

    var body: some View {
        let row = HStack(spacing: 10, content: content)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(isHovering && onTap != nil ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
        if let onTap {
            Button(action: onTap) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }
}
