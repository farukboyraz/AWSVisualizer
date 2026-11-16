import SwiftUI

struct StatusBadge: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color ?? StatusBadge.colorForStatus(text)
    }

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private static func colorForStatus(_ status: String) -> Color {
        let lower = status.lowercased()
        if lower.contains("running") || lower.contains("active") || lower.contains("ok") ||
            lower.contains("ready") || lower.contains("available") || lower.contains("enabled") ||
            lower.contains("green") || lower.contains("healthy") {
            return .green
        } else if lower.contains("stopped") || lower.contains("error") || lower.contains("alarm") ||
                    lower.contains("red") || lower.contains("degraded") || lower.contains("severe") {
            return .red
        } else if lower.contains("pending") || lower.contains("updating") || lower.contains("creating") ||
                    lower.contains("yellow") || lower.contains("warn") {
            return .orange
        } else if lower.contains("fatal") {
            return .red
        } else if lower.contains("terminated") || lower.contains("deleted") || lower.contains("grey") {
            return .gray
        }
        return .blue
    }
}
