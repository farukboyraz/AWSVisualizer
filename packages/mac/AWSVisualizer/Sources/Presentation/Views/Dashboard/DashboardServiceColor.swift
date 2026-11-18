import SwiftUI

/// Every service's spend color - the same one in the chart, its tooltip,
/// spend by service and all detail windows, whatever its rank in the period.
/// The common services have a color of their own (no two alike); any other
/// gets one from its name, so it never changes either. Grey is kept for "Other".
enum DashboardServiceColor {
    static let other = Color(hex: "#94A3B8")

    private static let palette = [
        "#3B82F6", "#10B981", "#F59E0B", "#8B5CF6", "#EC4899", "#06B6D4",
        "#EF4444", "#84CC16", "#6366F1", "#F97316", "#14B8A6", "#D946EF",
        "#0EA5E9", "#22C55E", "#EAB308", "#A855F7", "#F43F5E", "#0D9488",
        "#2563EB", "#CA8A04", "#7C3AED", "#DB2777", "#059669", "#EA580C",
    ].map { Color(hex: $0) }

    /// Cost Explorer's service names, normalized (`key`), one palette slot each.
    private static let known = [
        "elasticcomputecloudcompute", "relationaldatabaseservice", "simplestorageservice", "lambda",
        "cloudfront", "dynamodb", "cloudwatch", "elasticloadbalancing",
        "ec2other", "virtualprivatecloud", "elasticcontainerservice", "elastickubernetesservice",
        "ec2containerregistryecr", "apigateway", "route53", "keymanagementservice",
        "secretsmanager", "simplenotificationservice", "simplequeueservice", "elasticache",
        "elasticfilesystem", "waf", "tax", "costexplorer",
    ]

    /// "Amazon Elastic Load Balancing" -> "elasticloadbalancing".
    private static func key(_ name: String) -> String {
        var text = name.lowercased().filter { $0.isLetter || $0.isNumber }
        for prefix in ["amazon", "aws"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
    }

    static func color(for name: String) -> Color {
        let key = key(name)
        if let index = known.firstIndex(of: key) { return palette[index] }
        // FNV-1a: `hashValue` differs on every launch.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

extension View {
    /// A list row's hover, like the service tiles': tinted fill, tinted
    /// border, soft glow and a slight lift. Takes no extra room.
    func dashboardRowHover(tint: Color) -> some View {
        modifier(DashboardRowHover(tint: tint))
    }
}

private struct DashboardRowHover: ViewModifier {
    let tint: Color

    @State private var isHovering = false

    private let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                shape
                    .fill(isHovering ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(Color.clear))
                    .shadow(color: isHovering ? tint.opacity(0.35) : .clear, radius: 10, y: 4)
            )
            .overlay(shape.strokeBorder(isHovering ? tint.opacity(0.85) : .clear, lineWidth: 2))
            .contentShape(shape)
            .scaleEffect(isHovering ? 1.015 : 1)
            .padding(.horizontal, -8)
            .padding(.vertical, -5)
            .zIndex(isHovering ? 1 : 0)
            .onHover { isHovering = $0 }
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovering)
    }
}
