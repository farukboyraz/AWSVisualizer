import SwiftUI

struct Route53View: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[HostedZone]> = .loading
    @State private var selectedZone: HostedZone?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 300, minWidth: 220, maxWidth: 480, isDetailActive: selectedZone != nil, onBack: { selectedZone = nil }, backTitle: "Hosted Zones", detailTitle: selectedZone?.name) {
                zoneListPanel
            } detail: {
                if let selectedZone, let zoneId = selectedZone.hostedZoneId {
                    Route53ZoneDetailView(zoneId: zoneId)
                        .id(zoneId)
                } else {
                    EmptyStateView(message: "Select a hosted zone")
                }
            }
            // Route53 is global - only the profile matters.
            .task(id: appState.currentProfile) {
                await loadData()
            }
        }
    }

    private var zoneListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("Route 53 Hosted Zones")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }) { unfilteredZones in
                let zones = unfilteredZones.matching(filter)
                List(zones, selection: Binding(
                    get: { selectedZone?.id },
                    set: { id in selectedZone = zones.first { $0.id == id } }
                )) { zone in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(zone.name ?? "-")
                                .font(.body.bold())
                                .lineLimit(1)
                            Spacer()
                            if let isPrivate = zone.privateZone {
                                StatusBadge(isPrivate ? "Private" : "Public", color: isPrivate ? .orange : .blue)
                            }
                        }
                        HStack(spacing: 10) {
                            Label("\(zone.recordSetCount ?? 0) records", systemImage: "list.bullet")
                            if let comment = zone.comment, !comment.isEmpty {
                                Text(comment).lineLimit(1)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(zone.id)
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
        selectedZone = nil
        do {
            let response = try await api.getHostedZones(profile: appState.currentProfile, region: appState.currentRegion)
            state = response.loadState()
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
