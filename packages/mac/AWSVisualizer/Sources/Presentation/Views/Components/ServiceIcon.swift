import SwiftUI

extension AWSServiceCatalogEntry {
    /// Fixed color per catalog category, so a service's icon keeps its
    /// color everywhere (sidebar, tabs, Select Services, dashboard).
    var tint: Color { Self.categoryTint(category) }

    static func categoryTint(_ category: String) -> Color {
        switch category {
        case "Compute": return Color(hex: "#F97316")
        case "Containers": return Color(hex: "#EA580C")
        case "Storage": return Color(hex: "#16A34A")
        case "Database": return Color(hex: "#2563EB")
        case "Networking & Content Delivery": return Color(hex: "#7C3AED")
        case "Security, Identity & Compliance": return Color(hex: "#DC2626")
        case "Management & Governance": return Color(hex: "#DB2777")
        case "Developer Tools": return Color(hex: "#0891B2")
        case "Analytics": return Color(hex: "#9333EA")
        case "Machine Learning": return Color(hex: "#0D9488")
        case "Application Integration": return Color(hex: "#C026D3")
        case "Migration & Transfer": return Color(hex: "#0284C7")
        case "Media Services": return Color(hex: "#E11D48")
        case "Internet of Things": return Color(hex: "#65A30D")
        case "Business Applications": return Color(hex: "#CA8A04")
        case "End User Computing": return Color(hex: "#4F46E5")
        case "Front-End Web & Mobile": return Color(hex: "#DC2626")
        default: return Color(hex: "#64748B")
        }
    }
}

/// A service's symbol in its category color; not-yet-implemented services
/// are drawn faded.
struct ServiceIcon: View {
    let entry: AWSServiceCatalogEntry
    var size: CGFloat?

    var body: some View {
        Image(systemName: entry.icon)
            .font(size.map { .system(size: $0) } ?? .body)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(entry.tint)
            .opacity(entry.implemented ? 1 : 0.55)
    }
}
