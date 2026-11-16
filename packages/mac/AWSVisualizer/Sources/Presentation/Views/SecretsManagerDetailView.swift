import SwiftUI
import AppKit

private let recoveryWindowOptions = Array(7...30)

/// Mirrors a secret's page in the Secrets Manager console: General
/// (description, rotation status, value reveal, delete/restore), Tags, and
/// Versions (staging labels). `GetSecretValue` is only ever called when the
/// user explicitly clicks "Reveal" - never automatically while loading this
/// page, matching the console's own "hidden until you ask" behavior.
struct SecretsManagerDetailView: View {
    let secretName: String
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    private enum DetailTab: String, CaseIterable {
        case general = "General"
        case policy = "Policy"
        case tags = "Tags"
        case versions = "Versions"
    }

    @State private var tab: DetailTab = .general
    @State private var detailState: LoadState<SecretsManagerSecretDetail> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeader(title: detail.name, status: detail.deletedDate != nil ? "Scheduled for deletion" : nil, tab: $tab)

                    Group {
                        switch tab {
                        case .general:
                            SecretsManagerGeneralView(detail: detail, onUpdated: { detailState = .loaded($0) }, onDeleted: onDeleted)
                        case .policy:
                            SecretsManagerPolicyView(secretName: detail.name)
                        case .tags:
                            ResourceTagsEditor(tags: detail.tags, resourceNoun: "secret", onAdd: { key, value in
                                detailState = .loaded(try await api.addSecretTag(profile: appState.currentProfile, region: appState.currentRegion, name: detail.name, key: key, value: value))
                            }, onRemove: { key in
                                detailState = .loaded(try await api.removeSecretTag(profile: appState.currentProfile, region: appState.currentRegion, name: detail.name, key: key))
                            })
                        case .versions:
                            SecretsManagerVersionsView(versionStages: detail.versionStages)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: secretName) {
            await loadDetail()
        }
    }

    private func loadDetail() async {
        detailState = .loading
        do {
            let detail = try await api.getSecretDetail(profile: appState.currentProfile, region: appState.currentRegion, name: secretName)
            detailState = .loaded(detail)
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

private struct SecretsManagerGeneralView: View {
    let detail: SecretsManagerSecretDetail
    var onUpdated: (SecretsManagerSecretDetail) -> Void
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var descriptionText = ""
    @State private var isSavingDescription = false
    @State private var descriptionError: String?
    @State private var descriptionSaved = false

    @State private var recoveryWindow = 30
    @State private var isDeleting = false
    @State private var deleteError: String?

    @State private var isRestoring = false
    @State private var restoreError: String?

    @State private var revealedValue: SecretsManagerSecretValue?
    @State private var isRevealing = false
    @State private var revealError: String?
    @State private var copied = false

    @State private var rotationLambdaARN = ""
    @State private var rotationDays = 30
    @State private var isUpdatingRotation = false
    @State private var isRotatingNow = false
    @State private var isCancelingRotation = false
    @State private var rotationError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let deletedDate = detail.deletedDate {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This secret is scheduled for deletion on \(Formatters.formatDate(deletedDate)).")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        ConfirmButton("Restore Secret", isLoading: isRestoring) {
                            Task { await restore() }
                        }
                        if let restoreError {
                            Text(restoreError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                SettingsFieldRow(label: "Description", isSaving: isSavingDescription, error: descriptionError, saved: descriptionSaved, save: {
                    Task { await saveDescription() }
                }) {
                    TextField("Description", text: $descriptionText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Secret value")
                        .font(.headline)

                    if let revealedValue {
                        if let secretString = revealedValue.secretString {
                            SecretValuePanel(
                                secretString: secretString,
                                save: { newValue in
                                    let stored = try await api.putSecretValue(profile: appState.currentProfile, region: appState.currentRegion, name: detail.name, secretString: newValue)
                                    self.revealedValue = stored
                                    return stored.secretString ?? newValue
                                },
                                onHide: { self.revealedValue = nil; copied = false }
                            )
                            .id(revealedValue.versionId)
                        } else if let secretBinary = revealedValue.secretBinary {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Binary secret (base64-encoded)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(secretBinary)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(3)
                                SecondaryButton("Hide", systemImage: "eye.slash") { self.revealedValue = nil }
                            }
                        } else {
                            Text("This secret has no value set.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        RevealButton("Reveal Secret Value", isLoading: isRevealing) {
                            Task { await revealValue() }
                        }
                    }
                    if let revealError {
                        Text(revealError).font(.caption).foregroundStyle(.red)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Rotation")
                        .font(.headline)
                    DetailField("Automatic rotation", detail.rotationEnabled == true ? "Enabled" : "Disabled")
                    if let lambdaArn = detail.rotationLambdaArn { DetailField("Rotation Lambda", lambdaArn) }
                    if let lastRotated = detail.lastRotatedDate { DetailField("Last rotated", Formatters.formatDate(lastRotated)) }
                    if let nextRotation = detail.nextRotationDate { DetailField("Next rotation", Formatters.formatDate(nextRotation)) }

                    if detail.rotationEnabled == true {
                        HStack(spacing: 12) {
                            ConfirmButton("Rotate Now", isLoading: isRotatingNow, isDisabled: isCancelingRotation) {
                                Task { await rotateNow() }
                            }

                            WarningButton("Cancel Rotation", systemImage: "xmark.circle", isLoading: isCancelingRotation, isDisabled: isRotatingNow) {
                                Task { await cancelRotation() }
                            }
                        }
                    } else {
                        Text("Rotates against an existing Lambda function's ARN - creating a new rotation function itself isn't supported here, do that from the AWS console or CLI first.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        HStack(spacing: 8) {
                            TextField("Rotation Lambda ARN", text: $rotationLambdaARN)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 280)
                            Stepper("Every \(rotationDays) days", value: $rotationDays, in: 1...365)
                                .frame(width: 180)
                        }
                        ConfirmButton("Enable Rotation", isLoading: isUpdatingRotation, isDisabled: rotationLambdaARN.trimmingCharacters(in: .whitespaces).isEmpty) {
                            Task { await enableRotation() }
                        }
                    }
                    if let rotationError {
                        Text(rotationError).font(.caption).foregroundStyle(.red)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Details")
                        .font(.headline)
                    DetailField("ARN", detail.arn)
                    if let kmsKeyId = detail.kmsKeyId { DetailField("KMS key", kmsKeyId) }
                    if let created = detail.createdDate { DetailField("Created", Formatters.formatDate(created)) }
                    if let changed = detail.lastChangedDate { DetailField("Last changed", Formatters.formatDate(changed)) }
                    if let accessed = detail.lastAccessedDate { DetailField("Last accessed", Formatters.formatDate(accessed)) }
                }

                if detail.deletedDate == nil {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Danger zone")
                            .font(.headline)
                            .foregroundStyle(.red)

                        HStack(spacing: 8) {
                            Text("Recovery window")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $recoveryWindow) {
                                ForEach(recoveryWindowOptions, id: \.self) { days in
                                    Text("\(days) days").tag(days)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                        }

                        DeleteButton("Delete Secret", isLoading: isDeleting) {
                            Task { await delete() }
                        }
                        Text("Secrets Manager keeps the secret recoverable for the chosen window before permanently deleting it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let deleteError {
                            Text(deleteError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: detail.name) {
            descriptionText = detail.description ?? ""
            descriptionSaved = false
            revealedValue = nil
            revealError = nil
            copied = false
        }
    }


    private func saveDescription() async {
        isSavingDescription = true
        descriptionError = nil
        descriptionSaved = false
        do {
            let updated = try await api.updateSecretDescription(profile: appState.currentProfile, region: appState.currentRegion, name: detail.name, description: descriptionText)
            onUpdated(updated)
            descriptionSaved = true
        } catch {
            descriptionError = error.friendlyMessage
        }
        isSavingDescription = false
    }

    private func delete() async {
        isDeleting = true
        deleteError = nil
        do {
            try await api.deleteSecret(profile: appState.currentProfile, region: appState.currentRegion, name: detail.name, recoveryWindowInDays: recoveryWindow)
            onDeleted()
        } catch {
            deleteError = error.friendlyMessage
        }
        isDeleting = false
    }

    private func restore() async {
        isRestoring = true
        restoreError = nil
        do {
            let updated = try await api.restoreSecret(profile: appState.currentProfile, region: appState.currentRegion, name: detail.name)
            onUpdated(updated)
        } catch {
            restoreError = error.friendlyMessage
        }
        isRestoring = false
    }

    private func revealValue() async {
        isRevealing = true
        revealError = nil
        do {
            revealedValue = try await api.getSecretValue(profile: appState.currentProfile, region: appState.currentRegion, name: detail.name)
        } catch {
            revealError = error.friendlyMessage
        }
        isRevealing = false
    }

    private func enableRotation() async {
        let arn = rotationLambdaARN.trimmingCharacters(in: .whitespaces)
        guard !arn.isEmpty else { return }
        isUpdatingRotation = true
        rotationError = nil
        do {
            let updated = try await api.updateSecretRotation(profile: appState.currentProfile, region: appState.currentRegion, name: detail.name, rotationLambdaARN: arn, automaticallyAfterDays: rotationDays)
            onUpdated(updated)
        } catch {
            rotationError = error.friendlyMessage
        }
        isUpdatingRotation = false
    }

    private func rotateNow() async {
        isRotatingNow = true
        rotationError = nil
        do {
            let updated = try await api.rotateSecretNow(profile: appState.currentProfile, region: appState.currentRegion, name: detail.name)
            onUpdated(updated)
        } catch {
            rotationError = error.friendlyMessage
        }
        isRotatingNow = false
    }

    private func cancelRotation() async {
        isCancelingRotation = true
        rotationError = nil
        do {
            let updated = try await api.cancelSecretRotation(profile: appState.currentProfile, region: appState.currentRegion, name: detail.name)
            onUpdated(updated)
        } catch {
            rotationError = error.friendlyMessage
        }
        isCancelingRotation = false
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
    }
}

/// Resource-based policy on the secret itself - most secrets have none at
/// all until one is explicitly attached. Same "raw JSON, save button,
/// careful-mistake warning" pattern as `KmsKeyDetailView`'s Policy tab.
private struct SecretsManagerPolicyView: View {
    let secretName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var policyState: LoadState<SecretsManagerResourcePolicy> = .loading
    @State private var policyText = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saved = false
    @State private var isDeleting = false

    var body: some View {
        ScrollView {
            LoadableContent(policyState, retry: { Task { await load() } }) { policy in
                VStack(alignment: .leading, spacing: 10) {
                    Text("Resource policy")
                        .font(.headline)
                    Text("Controls which principals can access this secret directly, separate from IAM policies on those principals. A mistake here can lock out access - double-check before saving.")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    if policy.policy == nil, policyText.isEmpty {
                        Text("No resource policy attached to this secret.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextEditor(text: $policyText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))

                    HStack {
                        if let saveError {
                            Text(saveError).font(.caption).foregroundStyle(.red)
                        }
                        if saved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        if policy.policy != nil {
                            DeleteButton("Delete Policy", isLoading: isDeleting, isDisabled: isSaving) {
                                Task { await deletePolicy() }
                            }
                        }
                        SaveButton("Save Policy", isLoading: isSaving, isDisabled: isDeleting || policyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            Task { await save() }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: secretName) {
            await load()
        }
    }

    private func load() async {
        policyState = .loading
        do {
            let policy = try await api.getSecretResourcePolicy(profile: appState.currentProfile, region: appState.currentRegion, name: secretName)
            policyText = policy.policy ?? ""
            policyState = .loaded(policy)
        } catch {
            policyState = .failed(error.friendlyMessage)
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        saved = false
        do {
            let policy = try await api.putSecretResourcePolicy(profile: appState.currentProfile, region: appState.currentRegion, name: secretName, policy: policyText)
            policyState = .loaded(policy)
            saved = true
        } catch {
            saveError = error.friendlyMessage
        }
        isSaving = false
    }

    private func deletePolicy() async {
        isDeleting = true
        saveError = nil
        do {
            try await api.deleteSecretResourcePolicy(profile: appState.currentProfile, region: appState.currentRegion, name: secretName)
            policyText = ""
            policyState = .loaded(SecretsManagerResourcePolicy(policy: nil))
        } catch {
            saveError = error.friendlyMessage
        }
        isDeleting = false
    }
}

private struct SecretsManagerVersionsView: View {
    let versionStages: [SecretsManagerVersionStage]

    var body: some View {
        if versionStages.isEmpty {
            EmptyStateView(message: "No version history")
        } else {
            Table(versionStages) {
                TableColumn("Version ID") { v in
                    Text(v.versionId)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 200, ideal: 320)

                TableColumn("Staging Labels") { v in
                    HStack(spacing: 4) {
                        ForEach(v.stages, id: \.self) { stage in
                            Text(stage)
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }
                .width(min: 160, ideal: 260)
            }
        }
    }
}
