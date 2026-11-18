import Foundation

/// Settings › Display › Dashboard, stored in ~/.awsvisualizer under
/// `display.dashboard` (see packages/api/src/config/index.ts).
struct DashboardPrefs: Codable, Equatable {
    enum Widget: String, CaseIterable, Codable {
        case resourcesKpi, activeKpi, costKpi, attentionKpi, customCards, distribution, topServices, costTrend, costByService, services

        /// Needs the per-service resource counts (one AWS list call per service).
        var usesCounts: Bool { !usesCost && self != .customCards }
        /// Needs Cost Explorer (billed per request).
        var usesCost: Bool { self == .costKpi || self == .costTrend || self == .costByService }
    }

    enum CostView: String, Codable, CaseIterable { case daily, monthly, month }
    /// How the spend chart draws its series.
    enum ChartStyle: String, Codable, CaseIterable { case bar, line, points }
    enum ColorStyle: String, Codable, CaseIterable { case muted, vivid }
    /// categories = a block per catalog category; flat = one row of icons, most resources first.
    enum ServicesLayout: String, Codable, CaseIterable { case categories, flat }

    struct Cost: Codable, Equatable {
        var view: CostView = .month
        var months: Int = 6
        var showEstimate: Bool = true
        var chartStyle: ChartStyle = .bar
        /// The spend chart in one color (the total only) instead of a color per service.
        var singleColor = false

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            view = (try? c.decodeIfPresent(CostView.self, forKey: .view)) ?? .month
            let months = (try? c.decodeIfPresent(Int.self, forKey: .months)) ?? 6
            self.months = DashboardPrefs.monthRanges.contains(months) ? months : 6
            showEstimate = (try? c.decodeIfPresent(Bool.self, forKey: .showEstimate)) ?? true
            chartStyle = (try? c.decodeIfPresent(ChartStyle.self, forKey: .chartStyle)) ?? .bar
            singleColor = (try? c.decodeIfPresent(Bool.self, forKey: .singleColor)) ?? false
        }
    }

    var widgets: [String: Bool] = [:]
    var excludedServices: [String] = []
    var cost = Cost()
    var colorStyle: ColorStyle = .muted
    var hideEmptyServices = false
    var servicesLayout: ServicesLayout = .categories
    /// Saved data older than this is fetched again (0 = only with Refresh).
    var refreshMinutes = 15
    /// Fetch every time the dashboard opens, even when the saved data is fresh.
    var refreshOnOpen = false
    /// The user's own cards, in display order.
    var cards: [DashboardCard] = []
    /// Sections as rows and their sizes (the layout editor).
    var layout: DashboardLayout = .default

    static let defaults = DashboardPrefs()
    static let monthRanges = [3, 6, 12]
    /// Suggested intervals; any 1 minute .. 24 hours can be typed in.
    static let refreshPresets = [5, 15, 60]
    static let refreshMax = 24 * 60
    static let maxCards = 30

    init() {}

    /// Missing or unknown values fall back to the defaults field by field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        widgets = (try? c.decodeIfPresent([String: Bool].self, forKey: .widgets)) ?? [:]
        excludedServices = (try? c.decodeIfPresent([String].self, forKey: .excludedServices)) ?? []
        cost = (try? c.decodeIfPresent(Cost.self, forKey: .cost)) ?? Cost()
        colorStyle = (try? c.decodeIfPresent(ColorStyle.self, forKey: .colorStyle)) ?? .muted
        hideEmptyServices = (try? c.decodeIfPresent(Bool.self, forKey: .hideEmptyServices)) ?? false
        servicesLayout = (try? c.decodeIfPresent(ServicesLayout.self, forKey: .servicesLayout)) ?? .categories
        let minutes = (try? c.decodeIfPresent(Int.self, forKey: .refreshMinutes)) ?? 15
        refreshMinutes = (0...Self.refreshMax).contains(minutes) ? minutes : 15
        refreshOnOpen = (try? c.decodeIfPresent(Bool.self, forKey: .refreshOnOpen)) ?? false
        cards = (try? c.decodeIfPresent([DashboardCard].self, forKey: .cards)) ?? []
        let rows = (try? c.decodeIfPresent([[String]].self, forKey: .layout)) ?? DashboardLayout.defaultRows.map { $0.map(\.rawValue) }
        let sizes = (try? c.decodeIfPresent([String: String].self, forKey: .sizes)) ?? [:]
        layout = DashboardLayout(reading: rows, sizes: sizes)
    }

    /// The layout's rows and sizes are stored as two keys (`layout`, `sizes`).
    private enum CodingKeys: String, CodingKey {
        case widgets, excludedServices, cost, colorStyle, hideEmptyServices, servicesLayout, refreshMinutes, refreshOnOpen, cards, layout, sizes
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(widgets, forKey: .widgets)
        try c.encode(excludedServices, forKey: .excludedServices)
        try c.encode(cost, forKey: .cost)
        try c.encode(colorStyle, forKey: .colorStyle)
        try c.encode(hideEmptyServices, forKey: .hideEmptyServices)
        try c.encode(servicesLayout, forKey: .servicesLayout)
        try c.encode(refreshMinutes, forKey: .refreshMinutes)
        try c.encode(refreshOnOpen, forKey: .refreshOnOpen)
        try c.encode(cards, forKey: .cards)
        try c.encode(layout.rowsJSON, forKey: .layout)
        try c.encode(layout.sizesJSON, forKey: .sizes)
    }

    func isOn(_ widget: Widget) -> Bool { widgets[widget.rawValue] ?? true }

    mutating func set(_ widget: Widget, _ on: Bool) { widgets[widget.rawValue] = on }

    /// Whether the dashboard may ask for counts / cost / card values at all.
    var needsCounts: Bool { Widget.allCases.contains { $0.usesCounts && isOn($0) } }
    var needsCost: Bool { Widget.allCases.contains { $0.usesCost && isOn($0) } }
    var needsCards: Bool { isOn(.customCards) && cards.contains { $0.kind == .metric } }

    /// Every widget spelled out, so the saved file lists them all.
    var normalized: DashboardPrefs {
        var copy = self
        for widget in Widget.allCases { copy.widgets[widget.rawValue] = isOn(widget) }
        return copy
    }

    var asJSON: [String: Any] {
        let n = normalized
        return [
            "widgets": n.widgets,
            "excludedServices": n.excludedServices,
            "cost": ["view": n.cost.view.rawValue, "months": n.cost.months, "showEstimate": n.cost.showEstimate, "chartStyle": n.cost.chartStyle.rawValue, "singleColor": n.cost.singleColor],
            "colorStyle": n.colorStyle.rawValue,
            "hideEmptyServices": n.hideEmptyServices,
            "servicesLayout": n.servicesLayout.rawValue,
            "refreshMinutes": n.refreshMinutes,
            "refreshOnOpen": n.refreshOnOpen,
            "cards": n.cards.map(\.asJSON),
            "layout": n.layout.rowsJSON,
            "sizes": n.layout.sizesJSON,
        ]
    }
}

/// A card the user added: a template of a service (see
/// packages/api/src/infrastructure/dashboard-cards) with its parameters.
/// `kind` and `icon` are filled in by the sidecar from the template.
struct DashboardCard: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString.lowercased()
    var title = ""
    /// Catalog service id, or "note".
    var service = ""
    /// e.g. "codecommit.createPullRequest".
    var template = ""
    var kind: CardTemplate.Kind = .metric
    var icon = "square.dashed"
    /// The profiles whose dashboard shows the card (one or several).
    var profiles: [String] = []
    /// Region the card reads; "" = the region in use at the time.
    var region = ""
    /// On every profile's dashboard.
    var allProfiles = false
    var params: [String: String] = [:]

    init(id: String = UUID().uuidString.lowercased(), title: String = "", service: String = "", template: String = "", kind: CardTemplate.Kind = .metric, icon: String = "square.dashed", profiles: [String] = [], region: String = "", allProfiles: Bool = false, params: [String: String] = [:]) {
        self.id = id; self.title = title; self.service = service; self.template = template
        self.kind = kind; self.icon = icon; self.profiles = profiles; self.region = region; self.allProfiles = allProfiles; self.params = params
    }

    /// Shown on this profile's dashboard.
    func isVisible(on profile: String) -> Bool { allProfiles || profiles.isEmpty || profiles.contains(profile) }

    /// The profile / region the card runs with right now: always the
    /// profile in use; its own region, or the one in use when it has none.
    func context(currentProfile: String, currentRegion: String) -> (profile: String, region: String) {
        (currentProfile, region.isEmpty ? currentRegion : region)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        service = (try? c.decode(String.self, forKey: .service)) ?? ""
        template = (try? c.decode(String.self, forKey: .template)) ?? ""
        kind = (try? c.decode(CardTemplate.Kind.self, forKey: .kind)) ?? .metric
        icon = (try? c.decode(String.self, forKey: .icon)) ?? "square.dashed"
        let single = (try? c.decode(String.self, forKey: .profile)) ?? ""
        profiles = (try? c.decode([String].self, forKey: .profiles)) ?? (single.isEmpty ? [] : [single])
        region = (try? c.decode(String.self, forKey: .region)) ?? ""
        allProfiles = (try? c.decode(Bool.self, forKey: .allProfiles)) ?? profiles.isEmpty
        params = (try? c.decode([String: String].self, forKey: .params)) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case id, title, service, template, kind, icon, profile, profiles, region, allProfiles, params }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(service, forKey: .service)
        try c.encode(template, forKey: .template); try c.encode(kind, forKey: .kind); try c.encode(icon, forKey: .icon)
        try c.encode(profiles.first ?? "", forKey: .profile); try c.encode(profiles, forKey: .profiles)
        try c.encode(region, forKey: .region); try c.encode(allProfiles, forKey: .allProfiles); try c.encode(params, forKey: .params)
    }

    var asJSON: [String: Any] {
        ["id": id, "title": title, "service": service, "template": template, "kind": kind.rawValue, "icon": icon, "profile": profiles.first ?? "", "profiles": profiles, "region": region, "allProfiles": allProfiles, "params": params]
    }
}

/// What `POST /api/dashboard/cards/:id/value` answers for a metric card.
struct DashboardCardValue: Codable, Equatable {
    let value: Int
    let unit: LocalizedText
    var details: [LocalizedText]?
    var truncated: Bool?
    var approximate: Bool?
}

/// One saved answer from ~/.awsvisualizer's `dashboardCache`.
struct DashboardCached<T> {
    let fetchedAt: Date
    let data: T

    /// Older than `minutes` (0 = never stale - manual refresh only).
    func isStale(after minutes: Int, now: Date = Date()) -> Bool {
        minutes > 0 && now.timeIntervalSince(fetchedAt) >= Double(minutes) * 60
    }
}

/// Cache keys - must match packages/api/src/presentation/routes/dashboard.ts.
enum DashboardCacheKey {
    static func counts(profile: String, region: String) -> String { "counts|\(profile)|\(region)" }
    static func cost(profile: String, view: DashboardPrefs.CostView, months: Int, month: String) -> String {
        "cost|\(profile)|\(view.rawValue)|\(view == .monthly ? "\(months)" : "")|\(view == .month ? month : "")"
    }
    static func card(_ id: String, profile: String, region: String) -> String { "card|\(id)|\(profile)|\(region)" }
    static func run(_ id: String, profile: String, region: String) -> String { "run|\(id)|\(profile)|\(region)" }
}

// MARK: - Sections that need extra packages

extension DashboardPrefs {
    /// The catalog service whose SDK packages a section needs on top of the
    /// selected services' own: Cost Explorer for the cost sections.
    static func requiredService(for widget: Widget) -> String? {
        widget.usesCost ? "costexplorer" : nil
    }

    /// Every service any section can need.
    static var requiredServices: Set<String> {
        Set(Widget.allCases.compactMap(requiredService(for:)))
    }

    /// What the dashboard draws and fetches: a section whose packages are
    /// missing counts as off. The saved setting itself is left alone, so
    /// the section comes back on its own once the packages are installed.
    func available(missing: Set<String>) -> DashboardPrefs {
        guard !missing.isEmpty else { return self }
        var copy = self
        for widget in Widget.allCases {
            if let service = Self.requiredService(for: widget), missing.contains(service) { copy.set(widget, false) }
        }
        return copy
    }

    /// Sections switched on whose packages are missing.
    func sectionsWaiting(missing: Set<String>) -> [Widget] {
        Widget.allCases.filter { widget in
            isOn(widget) && Self.requiredService(for: widget).map(missing.contains) == true
        }
    }
}
