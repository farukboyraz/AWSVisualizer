import SwiftUI

struct SecretsManagerView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[SecretsManagerSecret]> = .loading
    @State private var selectedSecret: SecretsManagerSecret?
    @State private var showNewSecret = false

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 320, minWidth: 240, maxWidth: 500, isDetailActive: selectedSecret != nil, onBack: { selectedSecret = nil }, backTitle: "Secrets", detailTitle: selectedSecret?.name) {
                secretListPanel
            } detail: {
                if let selectedSecret {
                    SecretsManagerDetailView(secretName: selectedSecret.name) {
                        Task { await loadData() }
                    }
                    .id(selectedSecret.id)
                } else {
                    EmptyStateView(message: "Select a secret")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
        .sheet(isPresented: $showNewSecret) {
            NewSecretSheet { created in
                showNewSecret = false
                Task {
                    await loadData()
                    if case .loaded(let secrets) = state {
                        selectedSecret = secrets.first { $0.name == created }
                    }
                }
            }
        }
    }

    private var secretListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Secrets Manager")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }) { unfilteredSecrets in
                let secrets = unfilteredSecrets.matching(filter)
                List(secrets, selection: Binding(
                    get: { selectedSecret?.id },
                    set: { id in selectedSecret = secrets.first { $0.id == id } }
                )) { secret in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(secret.name)
                            .font(.body.bold())
                            .lineLimit(1)
                        if let description = secret.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(secret.id)
                }
                .listStyle(.sidebar)
            }
            PanelActionBar {
                NewButton(compactSize: 22, help: "New Secret") { showNewSecret = true }
                RefreshButton(compactSize: 22, help: "Refresh") { Task { await loadData() } }
            }
        }
    }

    private func loadData() async {
        state = .loading
        do {
            let secrets = try await api.getSecrets(profile: appState.currentProfile, region: appState.currentRegion)
            state = secrets.isEmpty ? .empty : .loaded(secrets)
            if let selectedSecret, case .loaded(let secrets) = state, !secrets.contains(where: { $0.id == selectedSecret.id }) {
                self.selectedSecret = nil
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private struct NewSecretSheet: View {
    /// Called with the new secret's name once creation succeeds, so the
    /// caller can select it straight away.
    var onCreated: (String) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var secretValue = ""
    @State private var kmsKeyId = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New Secret")
                    .font(.title2.bold())
                Spacer()
                SecondaryButton("Cancel") { dismiss() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Secret Name").font(.caption).foregroundStyle(.secondary)
                TextField("my-app/db-password", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Description (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("What this secret is for", text: $description)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Secret value").font(.caption).foregroundStyle(.secondary)
                // Same Key/value ⇄ Plaintext tabs as the console's "Store a new secret".
                SecretValueEditor(initialText: "", originalFormat: .jsonObject, embedded: true, onChange: { value in
                    secretValue = value ?? ""
                })
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("KMS Key ID (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("Defaults to aws/secretsmanager", text: $kmsKeyId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                NewButton("Create Secret", isLoading: isCreating, isDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty || secretValue.isEmpty) {
                    Task { await create() }
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        do {
            let detail = try await api.createSecret(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                name: name.trimmingCharacters(in: .whitespaces),
                description: description,
                secretString: secretValue,
                kmsKeyId: kmsKeyId,
                tags: []
            )
            onCreated(detail.name)
        } catch {
            errorMessage = error.friendlyMessage
        }
        isCreating = false
    }
}
