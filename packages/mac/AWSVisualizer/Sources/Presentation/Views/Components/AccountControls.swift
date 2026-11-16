import SwiftUI

struct AccountInfoSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Account")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(appState.callerIdentity?.account ?? "Unknown")
                .font(.body.bold())
            if let arn = appState.callerIdentity?.arn {
                Text(arn)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct ProfilePicker: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var isRefreshing = false

    var body: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        isRefreshing = true
                        await appState.refreshProfiles(using: api, force: true)
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Re-check which profiles are signed in")
            }
            Picker("Profile", selection: $state.currentProfile) {
                ForEach(appState.profiles) { p in
                    Text(p.pickerLabel).tag(p.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            let expired = appState.profiles.filter { !$0.isValid }
            if !expired.isEmpty {
                Text("\(expired.count) profile\(expired.count == 1 ? "" : "s") need\(expired.count == 1 ? "s" : "") a fresh SSO login.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct RegionPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: 8) {
            Text("Region")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Region", selection: $state.currentRegion) {
                ForEach(AWSRegion.all) { region in
                    Text("\(region.name) (\(region.code))").tag(region.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}

struct LanguagePicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: 8) {
            Text("Language")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Language", selection: $state.language) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.rawValue).tag(lang)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}

struct AppearancePicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: 8) {
            Text("Appearance")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Appearance", selection: $state.appearance) {
                ForEach(AppAppearance.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }
}
