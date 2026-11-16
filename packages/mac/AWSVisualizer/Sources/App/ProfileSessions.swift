import Foundation

extension Notification.Name {
    /// Posted (on the main queue) whenever any API call comes back 401/403 -
    /// lets the UI re-check which profiles are still signed in.
    static let awsRequestNotAuthorized = Notification.Name("awsRequestNotAuthorized")
}

/// Keeps `AppState.profiles` in step with the real SSO state. The list used
/// to be built once at boot from the profiles that were valid *at that
/// moment* - a profile whose sso-session had lapsed vanished and never came
/// back until the app restarted, even after logging in again.
extension AppState {
    /// Re-runs `check-profiles`. Automatic callers pass `force: false` and
    /// are debounced, so focus changes or a burst of failing requests don't
    /// each fire a round of STS calls.
    @MainActor
    func refreshProfiles(using api: APIService, force: Bool = false) async {
        if !force, let last = lastProfileRefresh, Date().timeIntervalSince(last) < 30 {
            return
        }
        lastProfileRefresh = Date()
        guard let result = try? await api.checkProfiles() else { return }
        applyProfileCheck(result.profiles)
    }

    /// Logs in the sso-session the given profile uses (opens the browser,
    /// same as `aws sso login --sso-session <name>`), then refreshes the
    /// list - one login revives every profile sharing that session.
    @MainActor
    func logIn(profile: AWSProfile, using api: APIService) async throws {
        _ = try await api.login(profile: profile.name)
        await refreshProfiles(using: api, force: true)
    }
}
