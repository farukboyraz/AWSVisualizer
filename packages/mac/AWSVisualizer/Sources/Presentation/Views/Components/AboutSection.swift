import SwiftUI

/// Settings › General › About: the app's version, the local API's
/// (sidecar) version, the Node.js it runs on and the AWS SDK version the
/// service packages are pinned to. Warns when the app and the API differ
/// (an old sidecar still running, or a half-updated install).
struct AboutSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var sdkVersion: String?

    private var language: AppLanguage { appState.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.aboutTitle).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 28) {
                item(language.aboutApp, "AWS Visualizer \(AppVersion.display)")
                item(language.aboutApi, appState.apiVersion ?? "—")
                item("Node.js", RuntimeManager.shared.selected.map { "v\($0.nodeVersion)" } ?? "—")
                item("AWS SDK", sdkVersion ?? "—")
            }
            if let apiVersion = appState.apiVersion, apiVersion != AppVersion.short {
                Label(language.aboutMismatch(app: AppVersion.short, api: apiVersion), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task { sdkVersion = try? await api.getPackagesStatus().sdkVersion }
    }

    private func item(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.tertiary)
            Text(value).font(.callout.weight(.medium).monospacedDigit()).textSelection(.enabled)
        }
    }
}
