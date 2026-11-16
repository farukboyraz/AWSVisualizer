import SwiftUI

/// Strip shown above the content while the selected profile's SSO session
/// is no longer valid - names the sso-session that needs a login and logs
/// into exactly that one (one login revives every profile sharing it).
struct ExpiredProfileBanner: View {
    let profile: AWSProfile

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var isLoggingIn = false
    @State private var isRefreshing = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("The SSO session for profile \"\(profile.name)\" has expired.")
                    .font(.callout.bold())
                Text(error ?? detailText)
                    .font(.caption)
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            Spacer()
            RefreshButton("Re-check", isLoading: isRefreshing, isDisabled: isLoggingIn) {
                Task { await refresh() }
            }
            RunButton("Log in", systemImage: "person.badge.key", isLoading: isLoggingIn, isDisabled: isRefreshing) {
                Task { await logIn() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var detailText: String {
        if let session = profile.ssoSession {
            return "Logging in renews sso-session \"\(session)\" - every profile using it comes back. A browser window opens for approval."
        }
        return "Logging in opens a browser window for approval."
    }

    private func logIn() async {
        isLoggingIn = true
        error = nil
        do {
            try await appState.logIn(profile: profile, using: api)
            if appState.currentProfileInfo?.isValid == false {
                error = "Still not authorized after logging in - check that this account/role is assigned to you in IAM Identity Center."
            }
        } catch {
            self.error = error.friendlyMessage
        }
        isLoggingIn = false
    }

    private func refresh() async {
        isRefreshing = true
        error = nil
        await appState.refreshProfiles(using: api, force: true)
        isRefreshing = false
    }
}
