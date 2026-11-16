import SwiftUI

/// What every dashboard section needs, in one value.
struct DashboardSectionContext {
    let model: DashboardModel
    let prefs: DashboardPrefs
    let language: AppLanguage
    let width: CGFloat
    /// Services whose count is still on its way (each tile / total fills in as it arrives).
    let loadingServices: Set<String>
    var favorites: Set<String> = []
    var onOpen: (String) -> Void = { _ in }
    var onDetails: (DashboardDetail) -> Void = { _ in }

    var wide: Bool { width >= 1050 }
    var spacing: CGFloat { 16 }
    var isCounting: Bool { !loadingServices.isEmpty }
    func on(_ widget: DashboardPrefs.Widget) -> Bool { prefs.isOn(widget) }

    /// "12 / 30 loaded" while counts arrive.
    var countingHint: String? {
        guard isCounting else { return nil }
        let total = model.services.count
        return language.dashLoadingCounts(done: total - loadingServices.count, total: total)
    }
}

/// The spend sections' period and chart style (shared by the KPI and the charts).
struct DashboardCostSelection {
    @Binding var view: DashboardPrefs.CostView
    @Binding var month: String
    @Binding var months: Int
    @Binding var chartStyle: DashboardPrefs.ChartStyle

    /// "This month" / "October 2026" / "Last 30 days" / "Last 6 months".
    func title(_ language: AppLanguage) -> String {
        switch view {
        case .daily: return language.dashLast30Days
        case .monthly: return language.dashLastMonths(months)
        case .month: return month == DashboardContent.currentMonthKey ? language.dashMonthToDate : language.monthName(month)
        }
    }

    static func averageText(_ cost: DashboardModel.Cost, _ language: AppLanguage) -> String {
        let value = DashboardFormat.money(cost.dailyAverage, currency: cost.currency)
        return cost.monthly ? language.dashMonthlyAverage(value) : language.dashDailyAverage(value)
    }
}

// MARK: - KPI cards

struct DashboardKPISection: View {
    let ctx: DashboardSectionContext
    let cost: DashboardCostSelection

    private var language: AppLanguage { ctx.language }

    var body: some View {
        let shown = [DashboardPrefs.Widget.resourcesKpi, .activeKpi, .costKpi, .attentionKpi].filter(ctx.on)
        if !shown.isEmpty {
            let columns = Array(repeating: GridItem(.flexible(), spacing: ctx.spacing), count: ctx.wide ? shown.count : min(2, shown.count))
            LazyVGrid(columns: columns, spacing: ctx.spacing) {
                ForEach(shown, id: \.self) { kpi($0) }
            }
        }
    }

    @ViewBuilder private func kpi(_ widget: DashboardPrefs.Widget) -> some View {
        let model = ctx.model
        switch widget {
        case .resourcesKpi:
            DashboardKPICard(
                title: language.dashResources,
                value: DashboardFormat.number(model.totalResources),
                hint: ctx.countingHint ?? language.dashResourcesHint(model.services.count),
                icon: "square.stack.3d.up.fill",
                colors: [Color(hex: "#3B82F6"), Color(hex: "#6366F1")]
            ) { countingIndicator }
        case .activeKpi:
            DashboardKPICard(
                title: language.dashActive,
                value: "\(model.activeServices)",
                hint: ctx.countingHint ?? language.dashActiveHint(model.services.count),
                icon: "bolt.horizontal.circle.fill",
                colors: [Color(hex: "#8B5CF6"), Color(hex: "#D946EF")]
            ) { countingIndicator }
        case .costKpi:
            costCard
        default:
            attentionCard
        }
    }

    @ViewBuilder private var countingIndicator: some View {
        if ctx.isCounting { ProgressView().controlSize(.small) }
    }

    @ViewBuilder private var costCard: some View {
        let title = cost.title(language)
        switch ctx.model.costState {
        case .loaded(let c):
            DashboardKPICard(
                title: title,
                value: DashboardFormat.money(c.total, currency: c.currency),
                hint: (ctx.prefs.cost.showEstimate ? c.monthEndEstimate : nil).map { language.dashEstimate(DashboardFormat.money($0, currency: c.currency)) } ?? DashboardCostSelection.averageText(c, language),
                icon: "dollarsign.circle.fill",
                colors: [Color(hex: "#10B981"), Color(hex: "#14B8A6")]
            ) {
                if c.daily.count > 1 { DashboardSpendTrend(cost: c, compact: true).frame(height: 30) }
            }
        case .loading:
            DashboardKPICard(title: title, value: "—", hint: language.cardPreviewLoading, icon: "dollarsign.circle.fill", colors: [Color(hex: "#10B981"), Color(hex: "#14B8A6")]) {
                ProgressView().controlSize(.small)
            }
        case .denied:
            DashboardKPICard(title: title, value: "—", hint: language.dashCostHiddenHint, icon: "lock.fill", colors: [Color(hex: "#94A3B8"), Color(hex: "#64748B")])
        case .failed, .hidden:
            DashboardKPICard(title: title, value: "—", hint: language.dashCostFailed, icon: "dollarsign.circle.fill", colors: [Color(hex: "#94A3B8"), Color(hex: "#64748B")])
        }
    }

    private var attentionCard: some View {
        let unreadable = ctx.model.services.filter { $0.count == nil && !$0.needsInstall && !$0.isLoading }.count
        let install = ctx.model.services.filter(\.needsInstall).count
        let ok = unreadable + install == 0
        return DashboardKPICard(
            title: language.dashAttention,
            value: "\(unreadable + install)",
            hint: ctx.countingHint ?? (ok ? language.dashAttentionNone : language.dashAttentionHint(unreadable: unreadable, install: install)),
            icon: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
            colors: ok ? [Color(hex: "#22C55E"), Color(hex: "#16A34A")] : [Color(hex: "#F59E0B"), Color(hex: "#F97316")]
        ) { countingIndicator }
    }
}

// MARK: - Resources by category + largest services

struct DashboardResourceSection: View {
    let ctx: DashboardSectionContext

    var body: some View {
        let language = ctx.language
        let model = ctx.model
        let donut = DashboardPanel(title: language.dashDistribution, icon: "chart.pie.fill") {
            if ctx.isCounting { ProgressView().controlSize(.small) }
        } content: {
            DashboardCategoryDonut(categories: model.categories, total: model.totalResources, language: language, onDetails: ctx.onDetails)
        }
        let top = DashboardPanel(title: language.dashTopServices, icon: "chart.bar.fill") {
            if ctx.isCounting { ProgressView().controlSize(.small) }
        } content: {
            DashboardTopServicesChart(services: model.topServices, language: language, total: model.totalResources, onOpen: ctx.onOpen, onDetails: ctx.onDetails)
        }
        switch (ctx.on(.distribution), ctx.on(.topServices)) {
        case (true, true) where ctx.wide:
            HStack(alignment: .top, spacing: ctx.spacing) {
                donut.frame(maxWidth: .infinity)
                top.frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        case (true, true):
            donut
            top
        case (true, false): donut
        case (false, true): top
        default: EmptyView()
        }
    }
}

// MARK: - Spend

struct DashboardCostSection: View {
    let ctx: DashboardSectionContext
    let cost: DashboardCostSelection

    private var language: AppLanguage { ctx.language }

    var body: some View {
        if ctx.on(.costTrend) || ctx.on(.costByService) {
            let title = cost.title(language)
            let trend = DashboardPanel(title: cost.view == .monthly ? language.dashSpendTrendMonthly : language.dashSpendTrend, subtitle: title, icon: "chart.xyaxis.line") {
                controls
            } content: {
                costBody(height: 300) { c in
                    if c.daily.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(DashboardCostSelection.averageText(c, language)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            DashboardCostChart(cost: c, style: cost.chartStyle, language: language, onDetails: ctx.onDetails).frame(height: 300)
                        }
                    } else {
                        DashboardEmptyChart(icon: "chart.xyaxis.line", message: language.dashNoSpend)
                    }
                }
            }
            let byService = DashboardPanel(title: language.dashSpendByService, subtitle: title, icon: "list.bullet.rectangle.fill") {
                // Without the trend panel the switch lives here.
                if !ctx.on(.costTrend) { controls }
            } content: {
                costBody(height: 220) { c in DashboardSpendByService(cost: c, language: language, onDetails: ctx.onDetails) }
            }
            switch (ctx.on(.costTrend), ctx.on(.costByService)) {
            case (true, true) where ctx.wide:
                HStack(alignment: .top, spacing: ctx.spacing) {
                    trend.frame(maxWidth: .infinity)
                    byService.frame(width: min(420, ctx.width * 0.38))
                }
                .fixedSize(horizontal: false, vertical: true)
            case (true, true):
                trend
                byService
            case (true, false): trend
            default: byService
            }
        }
    }

    /// Bars / lines / points, like a chart toolbar: icon segments, the current one filled.
    private var chartStyleSwitch: some View {
        HStack(spacing: 2) {
            ForEach(DashboardPrefs.ChartStyle.allCases, id: \.self) { style in
                Button { cost.chartStyle = style } label: {
                    Image(systemName: style == .bar ? "chart.bar.fill" : style == .line ? "chart.xyaxis.line" : "chart.dots.scatter")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 24)
                        .foregroundStyle(cost.chartStyle == style ? Color.white : Color.secondary)
                        .background(cost.chartStyle == style ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(language.chartStyleLabel(style))
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Chart style, then Daily / Monthly / One month with the month or range picker.
    private var controls: some View {
        HStack(spacing: 8) {
            if ctx.on(.costTrend) {
                chartStyleSwitch
                Divider().frame(height: 20)
            }
            if cost.view == .month {
                Picker("", selection: cost.$month) {
                    ForEach(DashboardContent.monthKeys, id: \.self) { Text(language.monthName($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            } else if cost.view == .monthly {
                Picker("", selection: cost.$months) {
                    ForEach(DashboardPrefs.monthRanges, id: \.self) { Text(language.monthsLabel($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            MultiSwitchBox(selection: cost.$view, options: DashboardPrefs.CostView.allCases.map { ($0, language.costViewLabel($0)) }, segmentWidth: 74, height: 24)
        }
    }

    @ViewBuilder private func costBody<V: View>(height: CGFloat, @ViewBuilder _ loaded: (DashboardModel.Cost) -> V) -> some View {
        switch ctx.model.costState {
        case .loaded(let c): loaded(c)
        case .loading:
            ProgressView().controlSize(.regular).frame(maxWidth: .infinity, minHeight: height)
        case .denied:
            DashboardEmptyChart(icon: "lock", message: language.dashCostHiddenHint)
        case .failed(let message):
            DashboardEmptyChart(icon: "exclamationmark.triangle", message: "\(language.dashCostFailed): \(message)")
        case .hidden:
            EmptyView()
        }
    }
}

// MARK: - Services

/// Favorites first (always), then every shown service - one block per
/// category, or one row of icons sorted by resources. Each tile shows its
/// own loader until its count arrives.
struct DashboardServicesSection: View {
    let ctx: DashboardSectionContext

    var body: some View {
        let language = ctx.language
        let prefs = ctx.prefs
        let visible = ctx.model.services.filter { $0.isLoading || !prefs.hideEmptyServices || ($0.count ?? 1) > 0 }
        let favoriteServices = visible.filter { ctx.favorites.contains($0.id) }
        VStack(alignment: .leading, spacing: 18) {
            if !favoriteServices.isEmpty {
                title(language.dashFavorites, icon: "star.fill", tint: .yellow)
                DashboardTileGrid(services: favoriteServices, language: language, favorites: ctx.favorites, onOpen: ctx.onOpen)
                    .padding(16)
                    .dashboardSurface()
            }
            HStack(spacing: 8) {
                title(prefs.servicesLayout == .flat ? language.dashAllServices : language.dashServices, icon: "square.grid.2x2.fill", tint: .secondary)
                if let hint = ctx.countingHint {
                    ProgressView().controlSize(.small)
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
            if prefs.servicesLayout == .flat {
                DashboardTileGrid(
                    services: visible.sorted { ($0.count ?? -1, $1.entry.name) > ($1.count ?? -1, $0.entry.name) },
                    language: language, favorites: ctx.favorites, onOpen: ctx.onOpen
                )
                .padding(16)
                .dashboardSurface()
            } else {
                // Category cards side by side; each wraps its own tiles.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: ctx.spacing, alignment: .top)], alignment: .leading, spacing: ctx.spacing) {
                    ForEach(ctx.model.categories) { category in
                        let services = category.services.filter { service in visible.contains { $0.id == service.id } }
                        if !services.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 2).fill(category.color.gradient).frame(width: 4, height: 16)
                                    Text(category.name).font(.headline).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(language.dashCategorySummary(services: services.count, resources: services.reduce(0) { $0 + ($1.count ?? 0) }))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                DashboardTileGrid(services: services, language: language, favorites: ctx.favorites, onOpen: ctx.onOpen)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .dashboardSurface()
                        }
                    }
                }
            }
        }
    }

    private func title(_ text: String, icon: String, tint: Color) -> some View {
        Label {
            Text(text).font(.title3.bold())
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
    }
}

// MARK: - Section switches

/// The header's "Sections" popover: one switch per section, applied right
/// away - turning one on shows it and fetches its data, turning it off
/// hides it and stops its requests.
struct DashboardSectionSwitches: View {
    let prefs: DashboardPrefs
    let language: AppLanguage
    var onToggle: (DashboardPrefs.Widget, Bool) -> Void

    @State private var isOpen = false

    var body: some View {
        SecondaryButton(systemImage: "switch.2", compactSize: 30, help: language.dashSections) { isOpen.toggle() }
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(language.dashSections).font(.headline)
                    ForEach(DashboardPrefs.Widget.allCases, id: \.self) { widget in
                        HStack {
                            Text(language.dsWidget(widget))
                            Spacer(minLength: 16)
                            SwitchBox(isOn: Binding(get: { prefs.isOn(widget) }, set: { onToggle(widget, $0) }))
                        }
                    }
                    Text(language.dashSectionsHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(width: 320)
            }
    }
}
