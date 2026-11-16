import SwiftUI

/// Mirrors a key's page in the KMS console: General configuration, then
/// the console's tabs - Key policy, Cryptographic configuration, Key
/// rotation, Aliases, Tags - with Enable/Disable and Schedule/Cancel key
/// deletion in the action bar ("Key actions"). Built from the shared
/// detail components.
struct KmsKeyDetailView: View {
    let keyId: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case general = "General configuration"
        case policy = "Key policy"
        case crypto = "Cryptographic configuration"
        case rotation = "Key rotation"
        case aliases = "Aliases"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .general
    @State private var detailState: LoadState<KmsKeyDetail> = .loading
    @State private var pendingAction: String?
    @State private var actionError: String?
    @State private var showScheduleDeletion = false
    @State private var deletionDays = 30

    var body: some View {
        LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(
                    title: detail.aliases.first ?? detail.keyId,
                    subtitle: [detail.keyManager == "AWS" ? "AWS managed key" : "Customer managed key", detail.keySpec].compactMap { $0 }.joined(separator: " · "),
                    status: detail.keyState ?? (detail.enabled ? "Enabled" : "Disabled"),
                    tab: $tab
                )
                actionBar(detail)

                Group {
                    switch tab {
                    case .general:
                        KmsGeneralTab(detail: detail)
                    case .policy:
                        JsonPolicyEditor(
                            title: "Key policy",
                            warning: "A mistake here can lock everyone out of the key - including you. Keep a statement that grants the account root access.",
                            reloadKey: keyId,
                            load: { try await api.getKmsKeyPolicy(profile: appState.currentProfile, region: appState.currentRegion, keyId: keyId) },
                            save: { text in try await api.updateKmsKeyPolicy(profile: appState.currentProfile, region: appState.currentRegion, keyId: keyId, policy: text) }
                        )
                    case .crypto:
                        KmsCryptoTab(detail: detail)
                    case .rotation:
                        KmsRotationTab(detail: detail, onUpdated: { detailState = .loaded($0) })
                    case .aliases:
                        KmsAliasesView(detail: detail, onUpdated: { detailState = .loaded($0) })
                    case .tags:
                        ResourceTagsEditor(tags: detail.tags, resourceNoun: "key", onAdd: { key, value in
                            detailState = .loaded(try await api.addKmsTag(profile: appState.currentProfile, region: appState.currentRegion, keyId: keyId, key: key, value: value))
                        }, onRemove: { key in
                            detailState = .loaded(try await api.removeKmsTag(profile: appState.currentProfile, region: appState.currentRegion, keyId: keyId, key: key))
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: keyId) {
            await loadDetail()
        }
    }

    @ViewBuilder
    private func actionBar(_ detail: KmsKeyDetail) -> some View {
        let isPendingDeletion = detail.keyState == "PendingDeletion"
        let isAwsManaged = detail.keyManager == "AWS"
        DetailActionBar(
            error: actionError,
            note: isAwsManaged ? "AWS managed keys can't be disabled, deleted or edited." : (isPendingDeletion ? "Scheduled for deletion on \(Formatters.formatISODate(detail.deletionDate)). The key can't be used until the deletion is cancelled." : nil),
            onRefresh: { Task { await loadDetail() } }
        ) {
            if detail.enabled {
                ConfirmedActionButton(
                    title: "Disable",
                    systemImage: "pause.circle",
                    confirmationTitle: "Disable this key?",
                    confirmationMessage: "Anything that encrypts or decrypts with this key fails until it's enabled again.",
                    isLoading: pendingAction == "disable",
                    isDisabled: isAwsManaged || pendingAction != nil
                ) { Task { await run("disable") { try await api.setKmsKeyEnabled(profile: appState.currentProfile, region: appState.currentRegion, keyId: keyId, enabled: false) } } }
            } else if !isPendingDeletion {
                ConfirmedActionButton(
                    title: "Enable",
                    systemImage: "play.circle",
                    confirmationTitle: "Enable this key?",
                    confirmationMessage: "The key can be used for cryptographic operations again.",
                    isLoading: pendingAction == "enable",
                    isDisabled: isAwsManaged || pendingAction != nil,
                    role: nil
                ) { Task { await run("enable") { try await api.setKmsKeyEnabled(profile: appState.currentProfile, region: appState.currentRegion, keyId: keyId, enabled: true) } } }
            }
            if isPendingDeletion {
                ConfirmedActionButton(
                    title: "Cancel key deletion",
                    systemImage: "arrow.uturn.backward",
                    confirmationTitle: "Cancel key deletion?",
                    confirmationMessage: "The key stays Disabled afterwards - enable it to use it again.",
                    isLoading: pendingAction == "cancel",
                    isDisabled: pendingAction != nil,
                    role: nil
                ) { Task { await run("cancel") { try await api.cancelKmsKeyDeletion(profile: appState.currentProfile, region: appState.currentRegion, keyId: keyId) } } }
            } else {
                AppButton("Schedule key deletion", kind: .delete, systemImage: "calendar.badge.minus", isLoading: pendingAction == "schedule", isDisabled: isAwsManaged || pendingAction != nil) {
                    showScheduleDeletion = true
                }
                .popover(isPresented: $showScheduleDeletion, arrowEdge: .bottom) {
                    scheduleDeletionPopover
                }
            }
        }
    }

    /// The console asks for a 7-30 day waiting period before deletion.
    private var scheduleDeletionPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schedule key deletion").font(.headline)
            Text("After the waiting period the key and all data encrypted under it become permanently unrecoverable. The key can't be used during the waiting period, and the deletion can be cancelled until then.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Stepper("Waiting period: \(deletionDays) days", value: $deletionDays, in: 7...30)
            HStack {
                Spacer()
                SecondaryButton("Cancel") { showScheduleDeletion = false }
                // The popover itself is the confirmation step.
                AppButton("Schedule deletion", kind: .delete) {
                    showScheduleDeletion = false
                    let days = deletionDays
                    Task { await run("schedule") { try await api.scheduleKmsKeyDeletion(profile: appState.currentProfile, region: appState.currentRegion, keyId: keyId, pendingWindowInDays: days) } }
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func run(_ action: String, _ call: () async throws -> KmsKeyDetail) async {
        pendingAction = action
        actionError = nil
        do {
            detailState = .loaded(try await call())
        } catch {
            actionError = error.friendlyMessage
        }
        pendingAction = nil
    }

    private func loadDetail() async {
        do {
            detailState = .loaded(try await api.getKmsKeyDetail(profile: appState.currentProfile, region: appState.currentRegion, keyId: keyId))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

private struct KmsGeneralTab: View {
    let detail: KmsKeyDetail

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "General configuration", spacing: 12) {
                DetailGrid(items: [
                    DetailItem("Alias", detail.aliases.first),
                    DetailItem("Status", detail.keyState, monospaced: false),
                    DetailItem("ARN", detail.keyArn),
                    DetailItem("Key ID", detail.keyId),
                    DetailItem("Description", detail.description?.isEmpty == false ? detail.description : nil, monospaced: false),
                    DetailItem("Creation date", Formatters.formatISODate(detail.creationDate), monospaced: false),
                    DetailItem("Regionality", detail.multiRegion == true ? "Multi-Region" : "Single Region", monospaced: false),
                    DetailItem("Key manager", detail.keyManager == "AWS" ? "AWS managed" : "Customer managed", monospaced: false),
                ] + (detail.deletionDate != nil ? [
                    DetailItem("Deletion date", Formatters.formatISODate(detail.deletionDate), monospaced: false),
                    DetailItem("Waiting period", detail.pendingDeletionWindowInDays.map { "\($0) days" }, monospaced: false),
                ] : []))
            }
        }
    }
}

private struct KmsCryptoTab: View {
    let detail: KmsKeyDetail

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Cryptographic configuration", spacing: 12) {
                DetailGrid(items: [
                    DetailItem("Key type", (detail.keySpec ?? "").hasPrefix("SYMMETRIC") ? "Symmetric" : ((detail.keySpec ?? "").hasPrefix("HMAC") ? "HMAC" : "Asymmetric"), monospaced: false),
                    DetailItem("Key spec", detail.keySpec),
                    DetailItem("Key usage", detail.keyUsage.map(Self.usageName), monospaced: false),
                    DetailItem("Origin", detail.origin.map(Self.originName), monospaced: false),
                ])
            }
            let algorithms: [(String, [String])] = [
                ("Encryption algorithms", detail.encryptionAlgorithms ?? []),
                ("Signing algorithms", detail.signingAlgorithms ?? []),
                ("MAC algorithms", detail.macAlgorithms ?? []),
            ].filter { !$0.1.isEmpty }
            ForEach(algorithms, id: \.0) { title, values in
                DetailSection(title: title, spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Text(value).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
    }

    static func usageName(_ raw: String) -> String {
        switch raw {
        case "ENCRYPT_DECRYPT": return "Encrypt and decrypt"
        case "SIGN_VERIFY": return "Sign and verify"
        case "GENERATE_VERIFY_MAC": return "Generate and verify MAC"
        case "KEY_AGREEMENT": return "Key agreement"
        default: return raw
        }
    }

    static func originName(_ raw: String) -> String {
        switch raw {
        case "AWS_KMS": return "AWS KMS"
        case "EXTERNAL": return "External (imported key material)"
        case "AWS_CLOUDHSM": return "AWS CloudHSM key store"
        case "EXTERNAL_KEY_STORE": return "External key store"
        default: return raw
        }
    }
}

/// Automatic yearly-by-default rotation of symmetric keys, with the
/// rotation period (90-2560 days) the console lets you pick.
private struct KmsRotationTab: View {
    let detail: KmsKeyDetail
    var onUpdated: (KmsKeyDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var periodText = "365"
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        DetailTabPage {
            DetailSection(title: "Automatic key rotation", spacing: 12) {
                if !detail.rotationSupported {
                    Text("Automatic rotation isn't available for this key - asymmetric, HMAC, imported and custom key store keys don't support it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    DetailGrid(items: [
                        DetailItem("Status", detail.rotationEnabled == true ? "Enabled" : "Disabled", monospaced: false),
                        DetailItem("Rotation period", detail.rotationPeriodInDays.map { "\($0) days" }, monospaced: false),
                        DetailItem("Next rotation", detail.nextRotationDate.map { Formatters.formatISODate($0) }, monospaced: false),
                    ])
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rotation period (days, 90-2560)").font(.caption).foregroundStyle(.secondary)
                        TextField("365", text: $periodText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                    HStack(spacing: 8) {
                        if detail.rotationEnabled == true {
                            SaveButton("Update period", isLoading: isSaving, isDisabled: !isPeriodValid || Int(periodText) == detail.rotationPeriodInDays || detail.keyManager == "AWS") {
                                Task { await set(true) }
                            }
                            ConfirmedActionButton(
                                title: "Disable rotation",
                                confirmationTitle: "Disable automatic rotation?",
                                confirmationMessage: "Existing key material is kept; no new material is generated.",
                                isLoading: isSaving,
                                isDisabled: isSaving || detail.keyManager == "AWS"
                            ) { Task { await set(false) } }
                        } else {
                            ConfirmedActionButton(
                                title: "Enable rotation",
                                confirmationTitle: "Enable automatic rotation every \(periodText) days?",
                                confirmationMessage: "AWS KMS generates new key material on that schedule. Old material is kept so existing ciphertext still decrypts.",
                                isLoading: isSaving,
                                isDisabled: isSaving || !isPeriodValid || !detail.enabled,
                                role: nil
                            ) { Task { await set(true) } }
                        }
                    }
                    if !detail.enabled {
                        Text("Enable the key to change its rotation.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .task(id: "\(detail.keyId)-\(detail.rotationPeriodInDays ?? 0)") {
            periodText = "\(detail.rotationPeriodInDays ?? 365)"
        }
    }

    private var isPeriodValid: Bool {
        guard let days = Int(periodText) else { return false }
        return (90...2560).contains(days)
    }

    private func set(_ enabled: Bool) async {
        isSaving = true
        error = nil
        do {
            onUpdated(try await api.setKmsKeyRotation(profile: appState.currentProfile, region: appState.currentRegion, keyId: detail.keyId, enabled: enabled, rotationPeriodInDays: enabled ? Int(periodText) : nil))
        } catch {
            self.error = error.friendlyMessage
        }
        isSaving = false
    }
}

private struct KmsAliasesView: View {
    let detail: KmsKeyDetail
    var onUpdated: (KmsKeyDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var newAlias = ""
    @State private var isAdding = false
    @State private var removingAlias: String?
    @State private var error: String?

    var body: some View {
        DetailTabPage {
            DetailSection(title: "Aliases", spacing: 12) {

                if detail.aliases.isEmpty {
                    Text("No aliases for this key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(detail.aliases, id: \.self) { alias in
                            HStack {
                                Text(alias)
                                    .font(.caption.monospaced())
                                Spacer()
                                DeleteButton(compactSize: 20, isLoading: removingAlias == alias, isDisabled: removingAlias != nil, help: "Remove Alias") {
                                    Task { await remove(alias) }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("alias/my-key-alias", text: $newAlias)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                    NewButton("Add Alias", isLoading: isAdding, isDisabled: newAlias.trimmingCharacters(in: .whitespaces).isEmpty) {
                        Task { await add() }
                    }
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func add() async {
        let alias = newAlias.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty else { return }
        isAdding = true
        error = nil
        do {
            let updated = try await api.addKmsAlias(profile: appState.currentProfile, region: appState.currentRegion, keyId: detail.keyId, aliasName: alias)
            onUpdated(updated)
            newAlias = ""
        } catch {
            self.error = error.friendlyMessage
        }
        isAdding = false
    }

    private func remove(_ alias: String) async {
        removingAlias = alias
        error = nil
        do {
            let updated = try await api.removeKmsAlias(profile: appState.currentProfile, region: appState.currentRegion, keyId: detail.keyId, aliasName: alias)
            onUpdated(updated)
        } catch {
            self.error = error.friendlyMessage
        }
        removingAlias = nil
    }
}
