import SwiftUI
import AppKit

/// Settings › About: versions, privacy, what the app has and hasn't got,
/// and where its files are - each feature can open its Settings page.
struct AboutPage: View {
    var onOpenPage: (SettingsPage) -> Void
    var onShowRawConfig: () -> Void

    @Environment(AppState.self) private var appState

    private var language: AppLanguage { appState.language }

    /// The repo the app was built from (the README lives there).
    private var repoRoot: URL? { SidecarManager.resolveApiDirectory()?.deletingLastPathComponent().deletingLastPathComponent() }
    private var settingsFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".awsvisualizer") }
    private var packagesFolder: URL { RuntimeManager.appSupportDirectory.appendingPathComponent("modules") }
    private var apiLog: URL { FileManager.default.temporaryDirectory.appendingPathComponent("awsvisualizer-api.log") }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            AboutSection()
            Divider()
            privacy
            Divider()
            features
            Divider()
            notYet
            Divider()
            places
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AWSBrandMark(size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text("AWS Visualizer").font(.title2.bold())
                Text("v\(AppVersion.display)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Text(language.aboutTagline).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(language.aboutPrivacyTitle, systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(Color(hex: "#16A34A"))
            ForEach(language.aboutPrivacyPoints, id: \.self) { point in
                Label { Text(point).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    .font(.callout)
            }
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language.aboutHasTitle).font(.headline)
            ForEach(language.aboutFeatures, id: \.title) { feature in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: feature.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title).font(.callout.weight(.semibold))
                        Text(feature.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let page = feature.page {
                        OpenButton(compactSize: 22, help: "\(language.aboutOpen): \(page.title)") { onOpenPage(page) }
                    }
                }
            }
        }
    }

    private var notYet: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.aboutHasNotTitle).font(.headline)
            ForEach(language.aboutHasNot, id: \.self) { item in
                Label { Text(item).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                    .font(.callout)
            }
        }
    }

    private var places: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language.aboutPlacesTitle).font(.headline)
            place(language.aboutSettingsFile, settingsFile) {
                SecondaryButton(language.aboutViewRaw, compactSize: 22, action: onShowRawConfig)
            }
            place(language.aboutPackagesFolder, packagesFolder) { EmptyView() }
            place(language.aboutApiLog, apiLog) { EmptyView() }
            if let repoRoot {
                place(language.aboutReadme, repoRoot.appendingPathComponent(language == .tr ? "README.tr.md" : "README.md")) { EmptyView() }
            }
            if let url = AppVersion.repositoryURL {
                HStack {
                    Text(language.aboutProjectPage).font(.callout)
                    Spacer()
                    Link(url.absoluteString, destination: url).font(.callout)
                }
            }
        }
    }

    /// A file / folder: its path, open it, show it in Finder.
    private func place<Extra: View>(_ title: String, _ url: URL, @ViewBuilder extra: () -> Extra) -> some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") + (exists ? "" : " - \(language.aboutNotFound)"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            extra()
            OpenButton(compactSize: 22, isDisabled: !exists, help: language.aboutOpen) { NSWorkspace.shared.open(url) }
            RevealButton(compactSize: 22, isDisabled: !exists, help: language.aboutShowInFinder) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
