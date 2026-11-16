import SwiftUI

struct AccessibleEnvironmentsSection: View {
    let environments: [AccessibleEnvironment]
    var allowsEditing: Bool = true

    var body: some View {
        if !environments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Environments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(environments.enumerated()), id: \.element.id) { index, environment in
                        AccessibleEnvironmentRow(environment: environment, allowsEditing: allowsEditing)
                        if index < environments.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct AccessibleEnvironmentRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    let environment: AccessibleEnvironment
    var allowsEditing: Bool

    @State private var isEditing = false
    @State private var profileName = ""
    @State private var region = "eu-west-1"
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(environment.accountName)
                        .font(.body.bold())
                    Text("\(environment.roleName) · \(environment.accountId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusView
            }

            if isEditing {
                editingForm
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var statusView: some View {
        if let profileName = environment.configuredProfileName {
            Label(profileName, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if allowsEditing {
            Group {
                if isEditing {
                    SecondaryButton("Cancel") { isEditing = false }
                } else {
                    NewButton("Set Profile") { beginEditing() }
                }
            }
        } else {
            Text("Not Set Profile")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var editingForm: some View {
        HStack(spacing: 8) {
            TextField("Profile name", text: $profileName)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            Picker("Region", selection: $region) {
                ForEach(AWSRegion.all) { r in
                    Text(r.code).tag(r.code)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            SaveButton("Save", isLoading: isSaving) {
                Task { await save() }
            }
            .disabled(isSaving || profileName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func beginEditing() {
        profileName = suggestedProfileName
        region = environment.ssoRegion
        errorMessage = nil
        isEditing = true
    }

    private var suggestedProfileName: String {
        let base = environment.accountName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let role = environment.roleName.lowercased()
        return "\(base)-\(role)"
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        do {
            try await api.createProfile(
                name: profileName.trimmingCharacters(in: .whitespaces),
                ssoSessionName: environment.ssoSessionName,
                accountId: environment.accountId,
                roleName: environment.roleName,
                region: region
            )
            isEditing = false
            await refreshAfterProfileCreated()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func refreshAfterProfileCreated() async {
        if let environments = try? await api.getAccessibleEnvironments() {
            appState.accessibleEnvironments = environments
        }
        await appState.refreshProfiles(using: api, force: true)
    }
}
