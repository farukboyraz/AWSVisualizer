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
    /// A KPI card was clicked.
    var onKPI: (DashboardKPIDetail) -> Void = { _ in }

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
    /// The chart in one color (switch in the panel header; default from Settings).
    @Binding var singleColor: Bool

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

// MARK: - Resources by category + largest services

/// Resources by category (donut) or the largest services, at its size:
/// small = the ring alone / top 4, medium = ring and legend of 11 / top 8,
/// large = bigger ring with a two-column legend of 22 / top 16 in two columns.
struct DashboardResourceWidget: View {
    let widget: DashboardPrefs.Widget
    let size: DashboardPrefs.WidgetSize
    let ctx: DashboardSectionContext

    var body: some View {
        let language = ctx.language
        let model = ctx.model
        Group {
            if widget == .distribution {
                DashboardPanel(title: language.dashDistribution, icon: "chart.pie.fill") {
                    DashboardCategoryDonut(
                        categories: model.categories, total: model.totalResources, language: language,
                        size: size == .small ? 170 : size == .medium ? 200 : 260,
                        legendLimit: size == .small ? 0 : size == .medium ? 11 : 22,
                        legendColumns: size == .large ? 2 : 1
                    )
                }
            } else {
                let limit = size == .small ? 4 : size == .medium ? 8 : 16
                let services = Array(model.services.filter { ($0.count ?? 0) > 0 }.sorted { ($0.count ?? 0) > ($1.count ?? 0) }.prefix(limit))
                DashboardPanel(title: language.dashTopServices, icon: "chart.bar.fill") {
                    DashboardTopServicesChart(services: services, language: language, onOpen: ctx.onOpen, columns: size == .large ? 2 : 1)
                }
            }
        }
        .dashboardLoading(ctx.isCounting, label: ctx.countingHint)
    }
}

// MARK: - Spend

/// The spend chart or spend by service. The gear on the chart's panel (on
/// spend by service when the chart is off) opens every spend filter.
struct DashboardCostWidget: View {
    let widget: DashboardPrefs.Widget
    let size: DashboardPrefs.WidgetSize
    let ctx: DashboardSectionContext
    let cost: DashboardCostSelection

    @State private var isSettingsOpen = false
    @State private var settingsClosedAt: Date?

    private var language: AppLanguage { ctx.language }

    var body: some View {
        Group {
            let title = cost.title(language)
            let trend = DashboardPanel(title: cost.view == .monthly ? language.dashSpendTrendMonthly : language.dashSpendTrend, titleDetail: title, icon: "chart.xyaxis.line") {
                settingsButton
            } content: {
                costBody(height: chartHeight) { c in
                    if c.daily.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(DashboardCostSelection.averageText(c, language)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            DashboardCostChart(cost: c, style: cost.chartStyle, language: language, singleColor: cost.singleColor, isInteractive: !isSettingsOpen, onSelectPeriod: openPeriod)
                                .frame(height: chartHeight)
                        }
                    } else {
                        DashboardEmptyChart(icon: "chart.xyaxis.line", message: language.dashNoSpend)
                    }
                }
            }
            let byService = DashboardPanel(title: language.dashSpendByService, titleDetail: title, icon: "list.bullet.rectangle.fill") {
                // Without the trend panel the filters live here.
                if !ctx.on(.costTrend) { settingsButton }
            } content: {
                costBody(height: 220) { c in
                    DashboardSpendByService(cost: c, language: language, limit: size == .small ? 4 : size == .medium ? 6 : 16, columns: size == .large ? 2 : 1) { service in
                        // A service: its own spend, period by period. "Other": every service.
                        ctx.onKPI(service.map(DashboardKPIDetail.costService) ?? .cost)
                    }
                }
            }
            if widget == .costTrend { trend } else { byService }
        }
        .dashboardLoading(isLoading)
    }

    private var chartHeight: CGFloat { size == .large ? 320 : 220 }

    private var isLoading: Bool {
        if case .loading = ctx.model.costState { return true }
        return false
    }

    /// The gear: its popover grows out of it over the dashboard (nothing
    /// moves or dims) and closes on a click anywhere else.
    private var settingsButton: some View {
        SecondaryButton(systemImage: "gearshape", compactSize: 26, help: language.dashSpendSettings) {
            if isSettingsOpen {
                isSettingsOpen = false
            } else if !justClosedSettings {
                isSettingsOpen = true
            }
        }
        .popover(isPresented: $isSettingsOpen, arrowEdge: .bottom) {
            DashboardCostSettingsPanel(cost: cost, language: language, showsChartOptions: ctx.on(.costTrend))
        }
        .onChange(of: isSettingsOpen) { _, open in
            if !open { settingsClosedAt = Date() }
        }
    }

    /// The click that dismissed the popover (on the gear or on a bar) must
    /// not also reopen it or open that bar's details.
    private var justClosedSettings: Bool {
        settingsClosedAt.map { Date().timeIntervalSince($0) < 0.4 } ?? false
    }

    private func openPeriod(_ date: Date) {
        guard !isSettingsOpen, !justClosedSettings else { return }
        ctx.onKPI(.costPeriod(date))
    }

    @ViewBuilder private func costBody<V: View>(height: CGFloat, @ViewBuilder _ loaded: (DashboardModel.Cost) -> V) -> some View {
        switch ctx.model.costState {
        case .loaded(let c): loaded(c)
        case .loading:
            Color.clear.frame(maxWidth: .infinity, minHeight: height)
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
                                        .dashboardLoadingBlur()
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
        .dashboardLoading(ctx.isCounting, label: ctx.countingHint)
    }

    private func title(_ text: String, icon: String, tint: Color) -> some View {
        Label {
            Text(text).font(.title3.bold())
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
    }
}

/// The Install button beside a section switch whose packages are missing
/// (the dashboard's Sections menu and Settings › Display › Dashboard).
struct DashboardSectionInstallButton: View {
    let service: String
    let language: AppLanguage
    let action: () -> Void

    var body: some View {
        DownloadButton(language.dashPackagesInstall, compactSize: 22, help: language.dashPackagesInstallHelp(service), action: action)
    }
}
