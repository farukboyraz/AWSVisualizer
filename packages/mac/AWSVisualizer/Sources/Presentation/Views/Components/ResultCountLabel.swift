import SwiftUI

/// "123 matches ⓘ" for the Items bottom bars: just the count on the bar,
/// with the details (how many items were read to find them, from where,
/// whether more is left) in the info icon's tooltip - so a narrow bar
/// doesn't push its buttons ("PartiQL", "Run"…) into "…" truncation.
struct ResultCountLabel: View {
    let count: Int
    var singular = "match"
    var plural = "matches"
    let detail: String

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count) \(count == 1 ? singular : plural)")
                .foregroundStyle(.secondary)
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .monospacedDigit()
        .fixedSize()
        .contentShape(Rectangle())
        .help(detail)
    }
}
