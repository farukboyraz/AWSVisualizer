import SwiftUI

struct ServiceComingSoonView: View {
    let entry: AWSServiceCatalogEntry?

    var body: some View {
        VStack(spacing: 12) {
            if let entry {
                Image(systemName: entry.icon)
                    .font(.system(size: 40))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(entry.tint)
            }
            Text(entry?.name ?? "Service")
                .font(.title3.bold())
            Text("Not implemented yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
