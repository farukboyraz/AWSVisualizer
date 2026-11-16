import SwiftUI

/// Client-side check matching the backend's `normalizeStartUrl`: an access
/// portal URL ending in /start, /start/ or /start/# (scheme optional).
enum StartUrlValidator {
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:https?://)?([A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9])/start/?(?:#/?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let hostRange = Range(match.range(at: 1), in: trimmed) else { return nil }
        return "https://\(trimmed[hostRange].lowercased())/start"
    }

    static func suggestedName(_ startUrl: String) -> String {
        let host = startUrl.replacingOccurrences(of: "https://", with: "").split(separator: "/").first ?? ""
        return String(host.split(separator: ".").first ?? "aws")
    }
}

/// Access-portal URL + IAM Identity Center region (+ optional display
/// name), used by first-run setup and "Add platform".
struct PlatformSetupForm: View {
    var knownSessions: [KnownSsoSession] = []
    var submitTitle: String = "Continue"
    var onCancel: (() -> Void)?
    let onSubmit: (_ startUrl: String, _ region: String, _ name: String?) async throws -> Void

    @State private var url = ""
    @State private var region = "eu-west-1"
    @State private var name = ""
    @State private var isSubmitting = false
    @State private var error: String?
    @FocusState private var urlFocused: Bool

    private var normalized: String? { StartUrlValidator.normalize(url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AWS access portal URL").font(.caption).foregroundStyle(.secondary)
                TextField("https://your-org.awsapps.com/start/#", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($urlFocused)
                    .onSubmit { submit() }
                if !url.isEmpty && normalized == nil {
                    Text("The URL should end with /start, /start/ or /start/# - e.g. https://your-org.awsapps.com/start/#")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("The address you open to see your AWS accounts (IAM Identity Center).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Identity Center region").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $region) {
                        ForEach(AWSRegion.all) { r in
                            Text("\(r.code) · \(r.name)").tag(r.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name (optional)").font(.caption).foregroundStyle(.secondary)
                    TextField(normalized.map(StartUrlValidator.suggestedName) ?? "my-company", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }

            if !knownSessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Found in ~/.aws/config").font(.caption).foregroundStyle(.secondary)
                    ForEach(knownSessions) { session in
                        Button {
                            url = session.startUrl
                            if let sessionRegion = session.region { region = sessionRegion }
                            name = session.name
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.left.circle")
                                Text(session.name).bold()
                                Text(session.startUrl).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                if let onCancel {
                    SecondaryButton("Cancel") { onCancel() }
                }
                ConfirmButton(submitTitle, isLoading: isSubmitting, isDisabled: normalized == nil || isSubmitting) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { urlFocused = true }
    }

    private func submit() {
        guard let normalized, !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task {
            do {
                try await onSubmit(normalized, region, name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name.trimmingCharacters(in: .whitespaces))
            } catch {
                self.error = error.friendlyMessage
            }
            isSubmitting = false
        }
    }
}

/// One platform row: status dot, name/URL, profile count, Log in.
struct PlatformRow: View {
    let platform: SsoPlatformStatus
    var isLoggingIn = false
    var compact = false
    var onLogin: () -> Void
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(platform.loggedIn ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .help(platform.loggedIn ? "Signed in until \(Formatters.formatISODate(platform.expiresAt))" : "Not signed in")
            VStack(alignment: .leading, spacing: 2) {
                Text(platform.name).font(.body.bold()).lineLimit(1)
                Text(platform.startUrl)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !compact {
                    Text(platform.loggedIn
                         ? "Signed in · \(platform.profileCount) profile\(platform.profileCount == 1 ? "" : "s") · until \(Formatters.formatISODate(platform.expiresAt))"
                         : "Not signed in · \(platform.profileCount) profile\(platform.profileCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            RunButton(platform.loggedIn ? "Re-login" : "Log in", systemImage: "person.badge.key", isLoading: isLoggingIn) {
                onLogin()
            }
            .controlSize(.small)
            if let onRemove {
                DeleteButton(compactSize: 22, help: "Remove platform") { onRemove() }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Platforms list with per-platform login and "Add platform" - shown in
/// Settings and the profile popover so another portal can be added or
/// signed into after the app is already open.
struct PlatformsSection: View {
    var compact = false

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var setup: SetupState?
    @State private var loggingInId: String?
    @State private var showAddSheet = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AWS platforms").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add platform", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            if let setup {
                if setup.platforms.isEmpty {
                    Text("No platforms yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(setup.platforms) { platform in
                    PlatformRow(
                        platform: platform,
                        isLoggingIn: loggingInId == platform.id,
                        compact: compact,
                        onLogin: { Task { await login(platform) } },
                        onRemove: compact || setup.platforms.count < 2 ? nil : { Task { await remove(platform) } }
                    )
                }
                if !setup.configPersisted && !compact {
                    HStack(spacing: 8) {
                        Label("Settings aren't saved - ~/.awsvisualizer doesn't exist, so the portal is asked again on every launch.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SaveButton("Save to ~/.awsvisualizer") {
                            Task { await persist() }
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showAddSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add AWS platform").font(.title3.bold())
                Text("Sign in to another AWS access portal. Its accounts appear next to the ones you already have.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PlatformSetupForm(knownSessions: unusedKnownSessions, submitTitle: "Add and log in", onCancel: { showAddSheet = false }) { url, region, name in
                    let response = try await api.addPlatform(startUrl: url, region: region, name: name)
                    showAddSheet = false
                    await reload()
                    if let added = response.platforms.first(where: { $0.id == response.platformId }) {
                        await login(added)
                    }
                }
            }
            .padding(24)
            .frame(width: 560)
        }
    }

    private var unusedKnownSessions: [KnownSsoSession] {
        guard let setup else { return [] }
        return setup.knownSessions.filter { session in !setup.platforms.contains { $0.startUrl == session.startUrl } }
    }

    private func reload() async {
        do {
            setup = try await api.getSetupState()
        } catch {
            self.error = error.friendlyMessage
        }
    }

    /// `aws sso login --sso-session <id>`: the token lands in
    /// ~/.aws/sso/cache, so terminal `aws --profile ...` calls work too.
    private func login(_ platform: SsoPlatformStatus) async {
        loggingInId = platform.id
        error = nil
        do {
            _ = try await api.login(ssoSession: platform.id)
            await reload()
            await appState.refreshProfiles(using: api, force: true)
            if let environments = try? await api.getAccessibleEnvironments() {
                appState.accessibleEnvironments = environments
            }
        } catch {
            self.error = error.friendlyMessage
        }
        loggingInId = nil
    }

    private func remove(_ platform: SsoPlatformStatus) async {
        do {
            _ = try await api.removePlatform(id: platform.id)
            await reload()
        } catch {
            self.error = error.friendlyMessage
        }
    }

    private func persist() async {
        do {
            try await api.enableConfigPersistence()
            await reload()
        } catch {
            self.error = error.friendlyMessage
        }
    }
}

/// Personal AWS accounts - signed in directly (root or IAM user) instead of
/// through an access portal. Settings › Platforms & Accounts and first-run
/// setup.
struct PersonalAccountsSection: View {
    var onSignedIn: (() async -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: PersonalAccountsState?
    @State private var showAddSheet = false
    @State private var reloggingProfile: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Personal accounts").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add personal account", systemImage: "plus.circle").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            if let state {
                if state.accounts.isEmpty {
                    Text("None yet. Use this for an AWS account you sign in to with an email/password (root) or an IAM user, not through an access portal.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(state.accounts) { account in
                    HStack(spacing: 10) {
                        Image(systemName: account.kind == "login" ? "person.crop.circle.badge.checkmark" : "key")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.profile).font(.body.bold())
                            Text(account.kind == "login" ? "Console sign-in (aws login)" : (account.kind == "keys" ? "IAM access keys" : "credential_process"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let region = account.region {
                            Text(region).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if account.kind == "login" {
                            RunButton("Sign in again", systemImage: "person.badge.key", isLoading: reloggingProfile == account.profile) {
                                Task { await relogin(account) }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showAddSheet) {
            PersonalAccountSheet(awsLoginSupported: state?.awsLoginSupported ?? false, cliVersion: state?.cliVersion) {
                showAddSheet = false
                Task {
                    await reload()
                    await appState.refreshProfiles(using: api, force: true)
                    await onSignedIn?()
                }
            } onCancel: {
                showAddSheet = false
            }
        }
    }

    private func reload() async {
        do {
            state = try await api.getPersonalAccounts()
        } catch {
            self.error = error.friendlyMessage
        }
    }

    private func relogin(_ account: PersonalAccount) async {
        reloggingProfile = account.profile
        error = nil
        do {
            _ = try await api.loginPersonalAccount(profile: account.profile, region: account.region ?? "eu-west-1")
            await appState.refreshProfiles(using: api, force: true)
        } catch {
            self.error = error.friendlyMessage
        }
        reloggingProfile = nil
    }
}

/// "Add personal account": browser sign-in (`aws login`, recommended - no
/// long-term keys, credentials refresh every 15 minutes) or IAM access keys.
struct PersonalAccountSheet: View {
    let awsLoginSupported: Bool
    let cliVersion: String?
    var onAdded: () -> Void
    var onCancel: () -> Void

    @Environment(\.apiService) private var api

    enum Method: String, CaseIterable, Identifiable {
        case browser = "Sign in with browser"
        case keys = "Access keys"
        var id: String { rawValue }
    }

    @State private var method: Method = .browser
    @State private var profile = "personal"
    @State private var region = "eu-west-1"
    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var warning: String?

    private var profileValid: Bool { profile.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add personal AWS account").font(.title3.bold())
            Picker("", selection: $method) {
                ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch method {
                case .browser:
                    Text("Signs in with the same email/password (root user) or IAM user you use for the AWS console. The AWS CLI keeps short-lived credentials and renews them every 15 minutes - no access keys are stored. Works in the terminal too: aws s3 ls --profile \(profile.isEmpty ? "personal" : profile).")
                    if !awsLoginSupported {
                        Label("Needs AWS CLI 2.32 or newer\(cliVersion.map { " (you have \($0))" } ?? ""). Update the AWS CLI or use access keys.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                case .keys:
                    Text("An IAM user's access key, stored in ~/.aws/credentials (readable only by you). AWS recommends browser sign-in over long-term keys where possible.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Profile name").font(.caption).foregroundStyle(.secondary)
                    TextField("personal", text: $profile)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default region").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $region) {
                        ForEach(AWSRegion.all) { Text("\($0.code) · \($0.name)").tag($0.code) }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
            }

            if method == .keys {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Access key ID").font(.caption).foregroundStyle(.secondary)
                    TextField("AKIA...", text: $accessKeyId)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Text("Secret access key").font(.caption).foregroundStyle(.secondary)
                    SecureField("", text: $secretAccessKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if isWorking && method == .browser {
                Label("Finish signing in in your browser...", systemImage: "safari")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                SecondaryButton("Cancel", action: onCancel)
                ConfirmButton(method == .browser ? "Sign in" : "Save", isLoading: isWorking, isDisabled: !canSubmit) {
                    Task { await submit() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var canSubmit: Bool {
        guard profileValid, !isWorking else { return false }
        switch method {
        case .browser: return awsLoginSupported
        case .keys: return !accessKeyId.trimmingCharacters(in: .whitespaces).isEmpty && !secretAccessKey.isEmpty
        }
    }

    private func submit() async {
        isWorking = true
        error = nil
        warning = nil
        do {
            switch method {
            case .browser:
                _ = try await api.loginPersonalAccount(profile: profile, region: region)
                onAdded()
            case .keys:
                let result = try await api.addAccessKeyAccount(profile: profile, accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, region: region)
                secretAccessKey = ""
                if let resultWarning = result.warning {
                    warning = resultWarning
                } else {
                    onAdded()
                }
            }
        } catch {
            self.error = error.friendlyMessage
        }
        isWorking = false
    }
}
