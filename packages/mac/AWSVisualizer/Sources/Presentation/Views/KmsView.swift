import SwiftUI

struct KmsView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[KmsKey]> = .loading
    @State private var selectedKey: KmsKey?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 300, minWidth: 220, maxWidth: 480, isDetailActive: selectedKey != nil, onBack: { selectedKey = nil }, backTitle: "Keys", detailTitle: selectedKey?.keyId) {
                keyListPanel
            } detail: {
                if let selectedKey {
                    KmsKeyDetailView(keyId: selectedKey.keyId)
                        .id(selectedKey.id)
                } else {
                    EmptyStateView(message: "Select a key")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private var keyListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("KMS Keys")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }) { unfilteredKeys in
                let keys = unfilteredKeys.matching(filter)
                List(keys, selection: Binding(
                    get: { selectedKey?.id },
                    set: { id in selectedKey = keys.first { $0.id == id } }
                )) { key in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.keyId)
                            .font(.body.bold().monospaced())
                        Text(key.keyArn)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                    .tag(key.id)
                }
                .listStyle(.sidebar)
            }
            PanelActionBar {
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
            }
        }
    }

    private func loadData() async {
        state = .loading
        selectedKey = nil
        do {
            let keys = try await api.getKmsKeys(profile: appState.currentProfile, region: appState.currentRegion)
            state = keys.isEmpty ? .empty : .loaded(keys)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
