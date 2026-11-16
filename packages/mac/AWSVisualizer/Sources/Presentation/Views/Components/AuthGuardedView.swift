import SwiftUI

struct AuthGuardedView<Content: View>: View {
    @Environment(AppState.self) private var appState
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        if appState.isAuthenticated {
            content()
        } else {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Not Authorized")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Please log in to access this resource.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
