import SwiftUI

struct ElasticLoadBalancingView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[LoadBalancer]> = .loading
    @State private var selected: LoadBalancer?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 300, minWidth: 220, maxWidth: 480, isDetailActive: selected != nil, onBack: { selected = nil }, backTitle: "Load Balancers", detailTitle: selected?.loadBalancerName) {
                listPanel
            } detail: {
                if let selected {
                    LoadBalancerDetailView(arn: selected.loadBalancerArn)
                        .id(selected.id)
                } else {
                    EmptyStateView(message: "Select a load balancer")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Load Balancers")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }) { unfilteredLoadBalancers in
                let loadBalancers = unfilteredLoadBalancers.matching(filter)
                List(loadBalancers, selection: Binding(
                    get: { selected?.id },
                    set: { id in selected = loadBalancers.first { $0.id == id } }
                )) { lb in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(lb.loadBalancerName)
                                .font(.body.bold())
                                .lineLimit(1)
                            Spacer()
                            if let state = lb.state { StatusBadge(state) }
                        }
                        Text([lb.type, lb.scheme].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let dns = lb.dnsName {
                            Text(dns)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(lb.id)
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
            let loadBalancers = try await api.getLoadBalancers(profile: appState.currentProfile, region: appState.currentRegion)
            state = loadBalancers.isEmpty ? .empty : .loaded(loadBalancers)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
