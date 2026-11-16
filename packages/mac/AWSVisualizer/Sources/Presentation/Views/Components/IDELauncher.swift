import SwiftUI
import AppKit

/// One entry in `IDERegistry` - a code editor/IDE this app knows how to
/// launch. `bundleIdentifier` is the only thing that has to be correct
/// (name/icon are just display); an inaccurate or absent app for a given ID
/// fails soft - `NSWorkspace` returns `nil` and `IDERegistry.installed()`
/// simply leaves it out, never a crash.
struct IDEDescriptor: Identifiable, Hashable, Codable {
    var id: String { bundleIdentifier }
    let name: String
    let bundleIdentifier: String
    let systemImage: String
}

/// Every code editor/IDE this app can hand a folder to, and the lookup that
/// turns a bundle identifier into an actually-installed app. Resolution
/// goes through Launch Services (`NSWorkspace.shared.urlForApplication
/// (withBundleIdentifier:)`) rather than guessing file paths - unlike
/// `KiroCliLocator`'s CLI-binary lookup (which has to check known install
/// locations because `kiro-cli` isn't a `.app` GUI at all), every entry
/// here *is* a normal macOS app, so Launch Services already knows exactly
/// where it lives regardless of whether it's in `/Applications`, `~/
/// Applications`, or somewhere else entirely.
enum IDERegistry {
    /// Curated, not exhaustive - the common general-purpose and JetBrains
    /// editors people actually browse a Lambda deployment package with.
    /// Xcode is included because it opens arbitrary folders as a workspace
    /// too, even though it's not most people's first choice for a Node.js/
    /// Python function.
    static let all: [IDEDescriptor] = [
        IDEDescriptor(name: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode", systemImage: "chevron.left.forwardslash.chevron.right"),
        IDEDescriptor(name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92", systemImage: "cursorarrow.rays"),
        IDEDescriptor(name: "Zed", bundleIdentifier: "dev.zed.Zed", systemImage: "bolt"),
        IDEDescriptor(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", systemImage: "hammer"),
        IDEDescriptor(name: "Sublime Text", bundleIdentifier: "com.sublimetext.4", systemImage: "doc.text"),
        IDEDescriptor(name: "WebStorm", bundleIdentifier: "com.jetbrains.WebStorm", systemImage: "curlybraces"),
        IDEDescriptor(name: "PyCharm", bundleIdentifier: "com.jetbrains.pycharm", systemImage: "curlybraces"),
        IDEDescriptor(name: "IntelliJ IDEA", bundleIdentifier: "com.jetbrains.intellij", systemImage: "curlybraces"),
        IDEDescriptor(name: "Android Studio", bundleIdentifier: "com.google.android.studio", systemImage: "curlybraces"),
        IDEDescriptor(name: "BBEdit", bundleIdentifier: "com.barebones.bbedit", systemImage: "doc.text"),
        IDEDescriptor(name: "TextMate", bundleIdentifier: "com.macromates.TextMate", systemImage: "doc.text"),
    ]

    static func resolvedURL(for ide: IDEDescriptor) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ide.bundleIdentifier)
    }

    /// `all`, filtered down to whatever's actually installed on this Mac -
    /// what `OpenInIDEControl`'s combobox offers. Recomputed on demand
    /// (not cached) since it's just a handful of Launch Services lookups.
    static func installed() -> [IDEDescriptor] {
        all.filter { resolvedURL(for: $0) != nil }
    }
}

/// Reusable "pick an IDE, then open a folder in it" control - a combobox of
/// every *installed* IDE from `IDERegistry` (defaulting to the app's
/// Settings-configured default IDE, falling back to the first installed one
/// if that default isn't present) plus an Open button.
///
/// The folder itself is never a stored property here - opening it is
/// entirely the caller's job via `action`, since callers often can't hand
/// over a `URL` up front (Lambda's Code tab has to export a temp copy of
/// the deployment package over the network *before* there's a folder to
/// open at all). This component only owns "which IDE" and "did the user
/// press Open," not what opening means.
struct OpenInIDEControl: View {
    var action: (IDEDescriptor) async -> Void
    var help: String = "Open in the selected IDE"

    @Environment(AppState.self) private var appState
    @State private var manualSelection: IDEDescriptor?
    @State private var isOpening = false

    private var installed: [IDEDescriptor] { IDERegistry.installed() }

    private var preferredIDE: IDEDescriptor? {
        installed.first { $0.bundleIdentifier == appState.defaultIDEBundleIdentifier } ?? installed.first
    }

    private var selection: Binding<IDEDescriptor?> {
        Binding(
            get: { manualSelection ?? preferredIDE },
            set: { manualSelection = $0 }
        )
    }

    var body: some View {
        if installed.isEmpty {
            HStack(spacing: 6) {
                Text("No supported IDE found")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Get VS Code") {
                    NSWorkspace.shared.open(URL(string: "https://code.visualstudio.com/download")!)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
            }
        } else {
            HStack(spacing: 6) {
                Picker("", selection: selection) {
                    ForEach(installed) { ide in
                        Text(ide.name).tag(Optional(ide))
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                OpenButton(isLoading: isOpening, help: help) {
                    guard let ide = selection.wrappedValue else { return }
                    isOpening = true
                    Task {
                        await action(ide)
                        isOpening = false
                    }
                }
            }
        }
    }
}
