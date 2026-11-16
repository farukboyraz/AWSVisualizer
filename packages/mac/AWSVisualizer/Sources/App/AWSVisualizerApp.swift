import SwiftUI

@main
struct AWSVisualizerApp: App {
    @State private var appState = AppState()
    private let apiService = APIService()

    init() {
        DashboardSnapshot.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(\.apiService, apiService)
                .environment(\.codeTheme, appState.codeTheme.theme)
                .environment(\.wordWrap, appState.wordWrap)
                .environment(\.layoutMode, appState.layoutMode)
                .environment(\.fileIconTheme, appState.fileIconTheme)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(appState.appearance.colorScheme)
                .navigationTitle("AWS Manager")
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1400, height: 900)
        .commands {
            // View → Word Wrap: one switch for every text / code viewer, so
            // the viewers don't each spend room on their own toggle.
            CommandGroup(after: .toolbar) {
                Toggle("Word Wrap", isOn: Binding(get: { appState.wordWrap }, set: { appState.wordWrap = $0 }))
                    .keyboardShortcut("z", modifiers: .option)
            }
        }
    }
}

// MARK: - Environment Key for APIService

private struct APIServiceKey: EnvironmentKey {
    static let defaultValue: APIService = APIService()
}

extension EnvironmentValues {
    var apiService: APIService {
        get { self[APIServiceKey.self] }
        set { self[APIServiceKey.self] = newValue }
    }
}
