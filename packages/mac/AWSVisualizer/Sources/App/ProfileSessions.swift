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
    /// `minimumInterval`: even a forced re-check waits this long after the
    /// last one (sign-in file changes come in bursts).
    @MainActor
    func refreshProfiles(using api: APIService, force: Bool = false, minimumInterval: TimeInterval = 0) async {
        if let last = lastProfileRefresh, Date().timeIntervalSince(last) < (force ? minimumInterval : 30) {
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

    /// Removes the profile from ~/.aws/config (asked for confirmation
    /// before); when it was the one in use, another signed-in profile is picked.
    @MainActor
    func deleteProfile(_ profile: AWSProfile, using api: APIService) async throws {
        try await api.deleteProfile(name: profile.name)
        await refreshProfiles(using: api, force: true)
        if currentProfile == profile.name, let next = profiles.first(where: \.isValid) ?? profiles.first {
            currentProfile = next.name
        }
    }
}
