import SwiftUI

struct CloudFormationView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[CloudFormationStack]> = .loading
    @State private var selectedStack: CloudFormationStack?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 300, minWidth: 220, maxWidth: 480, isDetailActive: selectedStack != nil, onBack: { selectedStack = nil }, backTitle: "Stacks", detailTitle: selectedStack?.stackName) {
                stackListPanel
            } detail: {
                if let selectedStack {
                    CloudFormationStackDetailView(stackName: selectedStack.stackName) {
                        Task { await loadData() }
                    }
                    .id(selectedStack.id)
                } else {
                    EmptyStateView(message: "Select a stack")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private var stackListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("CloudFormation Stacks")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }) { unfilteredStacks in
                let stacks = unfilteredStacks.matching(filter)
                List(stacks, selection: Binding(
                    get: { selectedStack?.id },
                    set: { id in selectedStack = stacks.first { $0.id == id } }
                )) { stack in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stack.stackName)
                            .font(.body.bold())
                        StatusBadge(stack.status)
                    }
                    .padding(.vertical, 2)
                    .tag(stack.id)
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
        do {
            let stacks = try await api.getStacks(profile: appState.currentProfile, region: appState.currentRegion)
            state = stacks.isEmpty ? .empty : .loaded(stacks)
            if let selectedStack, !stacks.contains(where: { $0.id == selectedStack.id }) {
                self.selectedStack = nil
            }
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
