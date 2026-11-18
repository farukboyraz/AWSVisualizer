import SwiftUI

/// Settings › Platforms › Profiles: every profile in ~/.aws/config with its
/// sign-in state (and until when), Log in for an expired one, and Delete -
/// which asks Yes / No first and removes the profile from ~/.aws/config.
struct ProfilesSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var isRefreshing = false
    @State private var busy: String?
    @State private var error: String?

    private var language: AppLanguage { appState.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.profilesTitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
                RefreshButton(compactSize: 22, isLoading: isRefreshing, help: language.profilesRecheck) {
                    Task {
                        isRefreshing = true
                        await appState.refreshProfiles(using: api, force: true)
                        isRefreshing = false
                    }
                }
            }
            Text(language.profilesHint).font(.caption).foregroundStyle(.tertiary)
            if appState.profiles.isEmpty {
                Text(language.profilesEmpty).font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(appState.profiles.enumerated()), id: \.element.id) { index, profile in
                        row(profile)
                        if index < appState.profiles.count - 1 { Divider() }
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func row(_ profile: AWSProfile) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(profile.isValid ? (profile.isUnverified ? Color.secondary : Color.green) : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.body.bold())
                    if profile.name == appState.currentProfile {
                        Text(language.profilesCurrent)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(status(profile))
                    .font(.caption)
                    .foregroundStyle(profile.isValid ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer()
            if !profile.isValid {
                RunButton(language.profilesLogIn, systemImage: "person.badge.key", isLoading: busy == profile.name, isDisabled: busy != nil) {
                    Task { await logIn(profile) }
                }
            }
            DeleteButton(compactSize: 24, isDisabled: busy != nil, help: language.profilesDelete, confirmationMessage: language.profilesDeleteMessage(profile.name)) {
                Task { await delete(profile) }
            }
        }
        .padding(.vertical, 6)
    }

    private func status(_ profile: AWSProfile) -> String {
        guard profile.isValid else { return language.profilesExpired }
        if profile.isUnverified { return language.profilesUnverified }
        guard let expiresAt = profile.expiresAt else { return language.profilesSignedIn }
        let f = DateFormatter()
        f.locale = language.locale
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(expiresAt) ? "HHmm" : "dMMMHHmm")
        return language.profilesSignedInUntil(f.string(from: expiresAt))
    }

    private func logIn(_ profile: AWSProfile) async {
        busy = profile.name
        error = nil
        do { try await appState.logIn(profile: profile, using: api) } catch { self.error = error.friendlyMessage }
        busy = nil
    }

    private func delete(_ profile: AWSProfile) async {
        busy = profile.name
        error = nil
        do { try await appState.deleteProfile(profile, using: api) } catch { self.error = error.friendlyMessage }
        busy = nil
    }
}
