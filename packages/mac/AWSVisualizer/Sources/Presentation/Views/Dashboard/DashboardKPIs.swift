import SwiftUI

/// What a KPI card's click opens (`DashboardKPIDetailSheet`).
enum DashboardKPIDetail: Identifiable, Equatable {
    case resources, active, cost, attention
    /// One period of the spend chart (a click on its bar / point).
    case costPeriod(Date)
    /// One service's spend, period by period (a click in spend by service).
    case costService(String)

    var id: String {
        switch self {
        case .resources: "resources"
        case .active: "active"
        case .cost: "cost"
        case .attention: "attention"
        case .costPeriod(let date): "costPeriod-\(date.timeIntervalSince1970)"
        case .costService(let name): "costService-\(name)"
        }
    }
}

/// One line of a KPI card's list (medium / large sizes).
struct DashboardKPIItem: Identifiable {
    let id: String
    var icon: String?
    let tint: Color
    let label: String
    let value: String
}

// MARK: - The four KPI cards

/// One KPI card at its size (the layout places it; see `DashboardRowsView`).
/// Small: the number. Medium: the number and the first 3 of its list beside
/// it. Large: the number and up to 8 of its list in two columns. A click
/// opens the full list (`DashboardKPIDetail`).
struct DashboardKPIWidget: View {
    let widget: DashboardPrefs.Widget
    let size: DashboardPrefs.WidgetSize
    let ctx: DashboardSectionContext
    let cost: DashboardCostSelection

    private var language: AppLanguage { ctx.language }
    private var model: DashboardModel { ctx.model }

    var body: some View {
        switch widget {
        case .resourcesKpi:
            DashboardKPITile(
                title: language.dashResources,
                value: DashboardFormat.number(model.totalResources),
                hint: ctx.countingHint ?? language.dashResourcesHint(model.services.count),
                icon: "square.stack.3d.up.fill",
                colors: [Color(hex: "#3B82F6"), Color(hex: "#6366F1")],
                size: size,
                items: resourceItems,
                emptyText: language.dashNoResources,
                language: language
            ) { ctx.onKPI(.resources) }
            .dashboardLoading(ctx.isCounting, label: ctx.countingHint)
        case .activeKpi:
            DashboardKPITile(
                title: language.dashActive,
                value: "\(model.activeServices)",
                hint: ctx.countingHint ?? language.dashActiveHint(model.services.count),
                icon: "bolt.horizontal.circle.fill",
                colors: [Color(hex: "#8B5CF6"), Color(hex: "#D946EF")],
                size: size,
                items: activeItems,
                emptyText: language.dashNothingActive,
                language: language
            ) { ctx.onKPI(.active) }
            .dashboardLoading(ctx.isCounting, label: ctx.countingHint)
        case .costKpi:
            costCard
        default:
            attentionCard
        }
    }

    private var resourceItems: [DashboardKPIItem] {
        model.services.filter { ($0.count ?? 0) > 0 }.sorted { ($0.count ?? 0) > ($1.count ?? 0) }.map {
            DashboardKPIItem(id: $0.id, icon: $0.entry.icon, tint: $0.entry.tint, label: $0.entry.name, value: DashboardFormat.number($0.count ?? 0))
        }
    }

    /// Per category: how many of its services have resources.
    private var activeItems: [DashboardKPIItem] {
        model.categories.compactMap { category -> (DashboardModel.Category, Int)? in
            let active = category.services.filter { ($0.count ?? 0) > 0 }.count
            return active > 0 ? (category, active) : nil
        }
        .sorted { $0.1 > $1.1 }
        .map { DashboardKPIItem(id: $0.0.id, tint: $0.0.color, label: $0.0.name, value: language.dashActiveOfCategory(active: $0.1, total: $0.0.services.count)) }
    }

    @ViewBuilder private var costCard: some View {
        let title = cost.title(language)
        let colors = [Color(hex: "#10B981"), Color(hex: "#14B8A6")]
        let grey = [Color(hex: "#94A3B8"), Color(hex: "#64748B")]
        switch model.costState {
        case .loaded(let c):
            DashboardKPITile(
                title: title,
                value: DashboardFormat.money(c.total, currency: c.currency),
                hint: (ctx.prefs.cost.showEstimate ? c.monthEndEstimate : nil).map { language.dashEstimate(DashboardFormat.money($0, currency: c.currency)) } ?? DashboardCostSelection.averageText(c, language),
                icon: "dollarsign.circle.fill",
                colors: colors,
                size: size,
                items: c.services.sorted { $0.amount > $1.amount }.map {
                    DashboardKPIItem(id: $0.name, tint: DashboardServiceColor.color(for: $0.name), label: DashboardFormat.shortServiceName($0.name), value: DashboardFormat.money($0.amount, currency: c.currency))
                },
                emptyText: language.dashNoSpend,
                language: language
            ) { ctx.onKPI(.cost) }
        case .loading:
            DashboardKPITile(title: title, value: "—", hint: language.cardPreviewLoading, icon: "dollarsign.circle.fill", colors: colors, size: size, items: [], language: language)
                .dashboardLoading(true)
        case .denied:
            DashboardKPITile(title: title, value: "—", hint: language.dashCostHiddenHint, icon: "lock.fill", colors: grey, size: size, items: [], language: language)
        case .failed, .hidden:
            DashboardKPITile(title: title, value: "—", hint: language.dashCostFailed, icon: "dollarsign.circle.fill", colors: grey, size: size, items: [], language: language)
        }
    }

    private var attentionCard: some View {
        let waiting = model.services.filter { !$0.isLoading }
        let unreadable = waiting.filter { $0.count == nil && !$0.needsInstall }
        let install = waiting.filter(\.needsInstall)
        let ok = unreadable.isEmpty && install.isEmpty
        let items = (install + unreadable).map {
            DashboardKPIItem(id: $0.id, icon: $0.entry.icon, tint: $0.entry.tint, label: $0.entry.name, value: $0.needsInstall ? language.dashAttentionInstall : language.dashAttentionUnreadable)
        }
        return DashboardKPITile(
            title: language.dashAttention,
            value: "\(unreadable.count + install.count)",
            hint: ctx.countingHint ?? (ok ? language.dashAttentionNone : language.dashAttentionHint(unreadable: unreadable.count, install: install.count)),
            icon: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
            colors: ok ? [Color(hex: "#22C55E"), Color(hex: "#16A34A")] : [Color(hex: "#F59E0B"), Color(hex: "#F97316")],
            size: size,
            items: items,
            emptyText: language.dashAttentionNone,
            language: language
        ) { ctx.onKPI(.attention) }
        .dashboardLoading(ctx.isCounting, label: ctx.countingHint)
    }
}

// MARK: - KPI card

/// The KPI card's look at each size; clickable when `onTap` is set.
struct DashboardKPITile: View {
    let title: String
    let value: String
    let hint: String
    let icon: String
    let colors: [Color]
    let size: DashboardPrefs.WidgetSize
    let items: [DashboardKPIItem]
    var emptyText: String?
    let language: AppLanguage
    var onTap: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { card }
                    .buttonStyle(.plain)
                    .help(language.dashKpiOpenHint)
                    .onHover { isHovering = $0 }
            } else {
                card
            }
        }
    }

    private var card: some View {
        Group {
            switch size {
            case .small:
                summary
            case .medium:
                HStack(alignment: .top, spacing: 16) {
                    summary.frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    list(Array(items.prefix(3)), columns: 1).frame(maxWidth: .infinity, alignment: .leading)
                }
            case .large:
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    Divider()
                    list(Array(items.prefix(8)), columns: 2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(colors: [colors[0].opacity(isHovering ? 0.16 : 0.10), .clear], startPoint: .topLeading, endPoint: .center)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .dashboardSurface()
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(colors[0].opacity(isHovering ? 0.45 : 0), lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: colors[0].opacity(0.35), radius: 6, y: 3)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .dashboardLoadingBlur()
                Spacer(minLength: 0)
                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isHovering ? AnyShapeStyle(colors[0]) : AnyShapeStyle(.tertiary))
                }
            }
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .dashboardLoadingBlur()
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .dashboardLoadingBlur()
        }
    }

    private func list(_ items: [DashboardKPIItem], columns: Int) -> some View {
        listBody(items, columns: columns).dashboardLoadingBlur()
    }

    @ViewBuilder private func listBody(_ items: [DashboardKPIItem], columns: Int) -> some View {
        if items.isEmpty {
            Text(emptyText ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .leading), count: columns), alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        if let icon = item.icon {
                            Image(systemName: icon)
                                .font(.system(size: 10, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(item.tint)
                                .frame(width: 20, height: 20)
                                .background(item.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        } else {
                            Circle().fill(item.tint).frame(width: 8, height: 8).frame(width: 20)
                        }
                        Text(item.label).font(.callout).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(item.value).font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1)
                    }
                }
            }
        }
    }
}

// MARK: - Loading veil

extension EnvironmentValues {
    /// The section's data is still on its way (`dashboardLoading`).
    @Entry var dashboardIsLoading = false
}

extension View {
    /// While a section's data is on its way: a loader on top, and the
    /// section's text (only what's marked `dashboardLoadingBlur()`) blurred -
    /// frames, borders, dividers and the surface stay sharp. Clicks still
    /// go through to what's underneath.
    func dashboardLoading(_ isLoading: Bool, label: String? = nil) -> some View {
        modifier(DashboardLoadingVeil(isLoading: isLoading, label: label))
    }

    /// Blurred while the enclosing `dashboardLoading` section is loading.
    func dashboardLoadingBlur() -> some View {
        modifier(DashboardLoadingBlur())
    }
}

private struct DashboardLoadingBlur: ViewModifier {
    @Environment(\.dashboardIsLoading) private var isLoading

    func body(content: Content) -> some View {
        content
            .blur(radius: isLoading ? 4 : 0)
            .animation(.easeInOut(duration: 0.2), value: isLoading)
    }
}

private struct DashboardLoadingVeil: ViewModifier {
    let isLoading: Bool
    let label: String?

    func body(content: Content) -> some View {
        content
            .environment(\.dashboardIsLoading, isLoading)
            .overlay {
                // The fade is scoped to the loader alone. An `.animation` on the
                // whole section also animated its charts when the data landed -
                // Swift Charts morphing donut slices crashed (NaN sector geometry).
                ZStack {
                    if isLoading {
                        VStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            if let label {
                                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isLoading)
                .allowsHitTesting(false)
            }
    }
}
