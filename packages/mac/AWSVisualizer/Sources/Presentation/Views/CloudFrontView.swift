import SwiftUI

struct CloudFrontView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[CloudFrontDistribution]> = .loading
    @State private var selectedDistribution: CloudFrontDistribution?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 340, minWidth: 260, maxWidth: 520, isDetailActive: selectedDistribution != nil, onBack: { selectedDistribution = nil }, backTitle: "Distributions", detailTitle: selectedDistribution?.domainName ?? selectedDistribution?.distributionId) {
                distributionListPanel
            } detail: {
                if let selectedDistribution, let id = selectedDistribution.distributionId {
                    CloudFrontDistributionDetailView(distributionId: id) {
                        Task { await loadData() }
                    }
                    .id(id)
                } else {
                    EmptyStateView(message: "Select a distribution")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private var distributionListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("CloudFront Distributions")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }) { unfilteredDistributions in
                let distributions = unfilteredDistributions.matching(filter)
                List(distributions, selection: Binding(
                    get: { selectedDistribution?.id },
                    set: { id in selectedDistribution = distributions.first { $0.id == id } }
                )) { distribution in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(distribution.domainName ?? "-")
                            .font(.body.bold())
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let status = distribution.status {
                                StatusBadge(status)
                            }
                            Text(distribution.enabled == true ? "Enabled" : "Disabled")
                                .font(.caption2)
                                .foregroundStyle(distribution.enabled == true ? .green : .secondary)
                        }
                        Text(distribution.distributionId ?? "-")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .tag(distribution.id)
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
            let response = try await api.getCloudFrontDistributions(profile: appState.currentProfile, region: appState.currentRegion)
            state = response.loadState()
            if let selectedDistribution, case .loaded(let distributions) = state, !distributions.contains(where: { $0.id == selectedDistribution.id }) {
                self.selectedDistribution = nil
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
