import SwiftUI

/// The dashboard layout, top to bottom - every block is its own component
/// (DashboardSections.swift) and can be switched off in the header or in
/// Settings › Display › Dashboard:
/// 1. header - title, profile / region / account, updated time, customize, refresh
/// 2. KPI cards - resources, active services, spend, attention
/// 3. resources by category (donut) + largest services (bars)
/// 4. spend trend (daily / monthly / one month switch) + spend by service
/// 5. every shown service, grouped by category
/// Pure rendering of a `DashboardModel`; columns adapt to `width`.
struct DashboardContent: View {
    let model: DashboardModel
    let prefs: DashboardPrefs
    let language: AppLanguage
    let profile: String
    let region: String
    let account: String?
    /// Starred services (Settings › Services) - shown in their own row.
    var favorites: Set<String> = []
    let width: CGFloat
    var isRefreshing = false
    /// The cost view shown now (starts from the settings' default).
    @Binding var costView: DashboardPrefs.CostView
    @Binding var costMonth: String
    @Binding var costMonths: Int
    /// Bars / lines / points - switched in the chart's header (default from Settings).
    @Binding var chartStyle: DashboardPrefs.ChartStyle
    /// The user's cards for this profile (the dashboard filters them).
    var visibleCards: [DashboardCard]? = nil
    var cardStates: [String: DashboardCardState] = [:]
    var runResults: [String: DashboardCached<CardActionResult>] = [:]
    var serviceName: (String) -> String = { $0 }
    var cardActions = DashboardCardActions()
    var onOpen: (String) -> Void = { _ in }
    var onRefresh: () -> Void = {}
    var onCustomize: () -> Void = {}

    /// Services whose count is still on its way.
    var loadingServices: Set<String> = []
    /// A section switched on / off from the header.
    var onToggleSection: (DashboardPrefs.Widget, Bool) -> Void = { _, _ in }

    /// Opened by a chart tooltip's "Details".
    @State private var detail: DashboardDetail?

    private func on(_ widget: DashboardPrefs.Widget) -> Bool { prefs.isOn(widget) }

    private var ctx: DashboardSectionContext {
        DashboardSectionContext(model: model, prefs: prefs, language: language, width: width, loadingServices: loadingServices, favorites: favorites, onOpen: onOpen, onDetails: { detail = $0 })
    }

    private var costSelection: DashboardCostSelection {
        DashboardCostSelection(view: $costView, month: $costMonth, months: $costMonths, chartStyle: $chartStyle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if !DashboardPrefs.Widget.allCases.contains(where: on) {
                EmptyStateView(message: language.dashSectionsOff).frame(minHeight: 300)
            }
            // Each section is its own component and shows its own loading.
            DashboardKPISection(ctx: ctx, cost: costSelection)
            if on(.customCards) {
                DashboardCardsSection(cards: visibleCards ?? prefs.cards, states: cardStates, runResults: runResults, language: language, serviceName: serviceName, actions: cardActions)
            }
            DashboardResourceSection(ctx: ctx)
            DashboardCostSection(ctx: ctx, cost: costSelection)
            if on(.services) { DashboardServicesSection(ctx: ctx) }
        }
        // Muted: the same palette, less saturated (neutral text is unaffected).
        .saturation(prefs.colorStyle == .muted ? 0.55 : 1)
        .sheet(item: $detail) { detail in
            DashboardDetailSheet(detail: detail, model: model, language: language, onOpen: onOpen) { self.detail = nil }
        }
    }

    // MARK: Header

    /// One row: title, then read-only info (profile / region / account /
    /// updated), then the buttons - sections, customize, refresh.
    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(language.dashTitle)
                    .font(.system(size: 30, weight: .bold))
                Text(language.dashSubtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 16) {
                if !profile.isEmpty { DashboardInfoItem(title: language.dashProfile, icon: "person.crop.circle", value: profile) }
                DashboardInfoItem(title: language.dashRegion, icon: "globe.europe.africa", value: region)
                if let account { DashboardInfoItem(title: language.dashAccount, icon: "building.columns", value: account) }
                DashboardInfoItem(title: language.dashUpdatedTitle, icon: "clock", value: model.updatedAt.formatted(date: .omitted, time: .shortened))
            }
            Divider().frame(height: 30)
            HStack(spacing: 8) {
                DashboardSectionSwitches(prefs: prefs, language: language, onToggle: onToggleSection)
                OpenButton(language.dsCustomize, systemImage: "slider.horizontal.3", compactSize: 30, action: onCustomize)
                RefreshButton(compactSize: 30, isLoading: isRefreshing, help: language.dashRefresh, action: onRefresh)
            }
        }
    }

    /// `YYYY-MM` of this month and the 13 before it (what Cost Explorer keeps).
    static var monthKeys: [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone(identifier: "UTC")
        return (0...13).compactMap { calendar.date(byAdding: .month, value: -$0, to: Date()).map(f.string(from:)) }
    }

    static var currentMonthKey: String { monthKeys[0] }
}
