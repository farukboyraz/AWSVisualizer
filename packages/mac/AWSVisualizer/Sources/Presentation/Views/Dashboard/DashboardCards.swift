import SwiftUI

// MARK: - Panel

/// The dashboard's card surface: rounded, hairline border, soft shadow.
struct DashboardPanel<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    /// Next to the title, in parentheses and italics: "(Last 6 months)".
    var titleDetail: String?
    var icon: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(title).font(.headline).lineLimit(1)
                        if let titleDetail {
                            Text("(\(titleDetail))").font(.subheadline).italic().foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardSurface()
    }
}

extension DashboardPanel where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, icon: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, icon: icon, accessory: { EmptyView() }, content: content)
    }
}

extension View {
    func dashboardSurface(cornerRadius: CGFloat = 16) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(DashboardFormat.surface)
                .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}

// MARK: - KPI card

/// One headline number with an icon badge, a hint line and an optional
/// footer (the spend sparkline), on a faint wash of its accent color.
struct DashboardKPICard<Footer: View>: View {
    let title: String
    let value: String
    let hint: String
    let icon: String
    let colors: [Color]
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .shadow(color: colors.first!.opacity(0.35), radius: 6, y: 3)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            footer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(colors: [colors.first!.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .center)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .dashboardSurface()
    }
}

extension DashboardKPICard where Footer == EmptyView {
    init(title: String, value: String, hint: String, icon: String, colors: [Color]) {
        self.init(title: title, value: value, hint: hint, icon: icon, colors: colors, footer: { EmptyView() })
    }
}

// MARK: - Service tile

/// A rounded square per service: large icon, resource count underneath.
/// Hovering lifts it, tints its border and shows the service name in a
/// bubble above (plus the tooltip); a click opens the service.
struct DashboardServiceTile: View {
    let service: DashboardModel.Service
    let language: AppLanguage
    var isFavorite = false
    var onOpen: () -> Void

    static let size: CGFloat = 92

    @State private var isHovering = false

    private var tint: Color { service.entry.tint }
    private var count: Int? { service.count }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 7) {
                Image(systemName: service.entry.icon)
                    .font(.system(size: 28, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(height: 34)
                if service.isLoading {
                    // Its own loader until this service's count arrives.
                    ProgressView().controlSize(.small).frame(height: 18)
                } else {
                    Text(count.map(DashboardFormat.number) ?? "—")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle((count ?? 0) == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .dashboardLoadingBlur()
                }
            }
            .frame(width: Self.size, height: Self.size)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(isHovering ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(DashboardFormat.surface))
                    .shadow(color: isHovering ? tint.opacity(0.35) : .black.opacity(0.06), radius: isHovering ? 12 : 6, y: isHovering ? 6 : 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(isHovering ? tint.opacity(0.85) : Color.primary.opacity(0.07), lineWidth: isHovering ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) { badge.padding(7) }
            .overlay(alignment: .top) {
                if isHovering {
                    Text(service.entry.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(tint.opacity(0.5)))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        .offset(y: -30)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(isHovering ? 1.06 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .zIndex(isHovering ? 1 : 0)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovering)
        .help("\(service.entry.name) · \(service.needsInstall ? language.dashNeedsInstall : count == nil ? language.dashUnreadable : language.dashResourceCount(count))")
        .accessibilityLabel("\(service.entry.name), \(language.dashResourceCount(count))")
    }

    @ViewBuilder private var badge: some View {
        if service.isLoading {
            EmptyView()
        } else if service.needsInstall {
            Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.blue)
        } else if count == nil {
            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        } else if isFavorite {
            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
        }
    }
}

/// Tiles wrapping into as many columns as fit.
struct DashboardTileGrid: View {
    let services: [DashboardModel.Service]
    let language: AppLanguage
    var favorites: Set<String> = []
    var onOpen: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: DashboardServiceTile.size, maximum: DashboardServiceTile.size), spacing: 14)], alignment: .leading, spacing: 14) {
            ForEach(services) { service in
                DashboardServiceTile(service: service, language: language, isFavorite: favorites.contains(service.id)) { onOpen(service.id) }
            }
        }
        // Room for the hover bubble above the first row.
        .padding(.top, 6)
    }
}

/// "Profile / sample-profile" - read-only info, deliberately not button-like.
struct DashboardInfoItem: View {
    let title: String
    let icon: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Small pieces

enum DashboardFormat {
    /// Hover bubbles: a touch brighter than cards so they float above them.
    static let tooltipSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.27, alpha: 1) : NSColor(white: 1, alpha: 1)
    })

    /// "12 Nov 2026" / "November 2026" in the app's language (UTC dates).
    static func periodLabel(_ date: Date, monthly: Bool, language: AppLanguage) -> String {
        let f = DateFormatter()
        f.locale = language.locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(monthly ? "MMMMyyyy" : "dMMMyyyyEEE")
        return f.string(from: date)
    }

    /// Short axis dates: "23 Eki" / "Oct 23", "Eki 26" / "Oct 26".
    static func axisDate(_ date: Date, monthly: Bool, language: AppLanguage) -> String {
        let f = DateFormatter()
        f.locale = language.locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(monthly ? "MMMyy" : "dMMM")
        return f.string(from: date)
    }

    /// "+12%" / "−8%" against a reference.
    static func signedPercent(_ value: Double, vs reference: Double) -> String {
        guard reference > 0 else { return "—" }
        let change = Int(((value - reference) / reference * 100).rounded())
        return change > 0 ? "+\(change)%" : change < 0 ? "−\(-change)%" : "0%"
    }

    /// "7 minutes ago" / "7 dakika önce" in the app's language.
    static func relative(_ date: Date, language: AppLanguage) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = language.locale
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    /// Cards: a step lighter than the detail background in both schemes.
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.215, alpha: 1) : NSColor(white: 1, alpha: 1)
    })

    static func money(_ value: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = value >= 1000 ? 0 : 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f %@", value, currency)
    }

    static func number(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func percent(_ part: Double, of total: Double) -> String {
        total > 0 ? "\(Int((part / total * 100).rounded()))%" : "0%"
    }

    /// AWS bill names are long ("Amazon Elastic Compute Cloud - Compute").
    static func shortServiceName(_ name: String) -> String {
        var s = name
        for prefix in ["Amazon ", "AWS "] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        return s
    }
}
