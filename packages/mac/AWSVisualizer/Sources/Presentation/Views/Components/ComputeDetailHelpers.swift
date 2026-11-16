import SwiftUI

// Small pieces the newer Compute detail views share on top of
// ResourceDetailComponents.

/// Wrapped capsules for a short list of values (AZs, instance types,
/// labels) - "-" when empty.
struct ValueChips: View {
    let values: [String]
    var monospaced: Bool = true

    var body: some View {
        if values.isEmpty {
            Text("-").font(.caption).foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 6, rowSpacing: 6) {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(monospaced ? .caption.monospaced() : .caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// Labeled `ValueChips` - a list-valued field next to `DetailGrid` fields.
struct DetailChipsField: View {
    let label: String
    let values: [String]
    var monospaced: Bool = true

    init(_ label: String, _ values: [String], monospaced: Bool = true) {
        self.label = label
        self.values = values
        self.monospaced = monospaced
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            ValueChips(values: values, monospaced: monospaced)
        }
    }
}

/// Caption-sized note under a section ("Read-only in AWS Visualizer").
struct DetailNote: View {
    let text: String
    var systemImage: String = "info.circle"

    init(_ text: String, systemImage: String = "info.circle") {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum ComputeFormat {
    /// "arn:...:targetgroup/web/abc" -> "web"; "arn:...:role/x" -> "x".
    static func arnResourceName(_ arn: String) -> String {
        let tail = arn.split(separator: ":").last.map(String.init) ?? arn
        let parts = tail.split(separator: "/").map(String.init)
        if parts.count >= 2, tail.hasPrefix("targetgroup/") { return parts[1] }
        return parts.last ?? tail
    }

    static func seconds(_ value: Int?) -> String {
        guard let value else { return "-" }
        if value >= 86400, value % 86400 == 0 { return "\(value / 86400) days" }
        if value >= 3600, value % 3600 == 0 { return "\(value / 3600) h" }
        if value >= 60, value % 60 == 0 { return "\(value / 60) min" }
        return "\(value) s"
    }

    static func bool(_ value: Bool?) -> String {
        guard let value else { return "-" }
        return value ? "Yes" : "No"
    }

    static func int(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }
}

/// Opens a URL string from AWS (README, homepage, source code) when valid.
struct ExternalLinkButton: View {
    let title: String
    let urlString: String?

    var body: some View {
        if let urlString, let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label(title, systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.link)
            .font(.caption)
            .help(urlString)
        }
    }
}
