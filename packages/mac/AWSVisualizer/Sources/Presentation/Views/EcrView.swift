import SwiftUI

struct EcrView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[EcrRepository]> = .loading
    @State private var selected: EcrRepository?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 280, minWidth: 220, maxWidth: 460, isDetailActive: selected != nil, onBack: { selected = nil }, backTitle: "Repositories", detailTitle: selected?.repositoryName) {
                listPanel
            } detail: {
                if let selected {
                    EcrRepositoryDetailView(repositoryName: selected.repositoryName)
                        .id(selected.id)
                } else {
                    EmptyStateView(message: "Select a repository")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("ECR Repositories")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }) { unfilteredRepositories in
                let repositories = unfilteredRepositories.matching(filter)
                List(repositories, selection: Binding(
                    get: { selected?.id },
                    set: { id in selected = repositories.first { $0.id == id } }
                )) { repo in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(repo.repositoryName)
                                .font(.body.bold())
                                .lineLimit(1)
                            Spacer()
                            if repo.imageTagMutability == "IMMUTABLE" {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .help("Tag immutability enabled")
                            }
                        }
                        Text("Created \(Formatters.formatISODate(repo.createdAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(repo.id)
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
        selected = nil
        do {
            let repositories = try await api.getEcrRepositories(profile: appState.currentProfile, region: appState.currentRegion)
            state = repositories.isEmpty ? .empty : .loaded(repositories)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
