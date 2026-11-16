import SwiftUI

/// Orange warning lines for the parts of a screen that failed while the
/// rest loaded (missing IAM permission for one call, etc.).
struct PartialErrorsView: View {
    let errors: [String]

    var body: some View {
        if !errors.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(errors, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// A resource policy tab: formatted JSON, or a note when none is set.
struct PolicyDocumentView: View {
    let policy: String?
    var emptyMessage: String = "No policy is attached."

    var body: some View {
        if let policy, !policy.isEmpty {
            StructuredContentView(text: policy, kind: .json)
        } else {
            EmptyStateView(message: emptyMessage)
        }
    }
}

enum StorageFormat {
    static func gib(_ value: Int?) -> String {
        value.map { "\($0) GiB" } ?? "-"
    }

    static func bytes(_ value: Int?) -> String {
        Formatters.formatBytes(value)
    }
}
