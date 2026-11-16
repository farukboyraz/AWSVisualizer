import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.screen {
            case .boot:
                BootView()
            case .main:
                MainView()
            }
        }
        .animation(.easeInOut, value: appState.screen)
    }
}
