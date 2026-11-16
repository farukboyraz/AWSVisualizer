import SwiftUI

struct RDSView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[RdsInstance]> = .loading
    @State private var selectedInstance: RdsInstance?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 300, minWidth: 220, maxWidth: 480, isDetailActive: selectedInstance != nil, onBack: { selectedInstance = nil }, backTitle: "DB Instances", detailTitle: selectedInstance?.dbInstanceIdentifier) {
                instanceListPanel
            } detail: {
                if let selectedInstance, let id = selectedInstance.dbInstanceIdentifier {
                    RdsInstanceDetailView(dbInstanceId: id)
                        .id(id)
                } else {
                    EmptyStateView(message: "Select a database")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private var instanceListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("RDS Databases")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }) { unfilteredInstances in
                let instances = unfilteredInstances.matching(filter)
                List(instances, selection: Binding(
                    get: { selectedInstance?.id },
                    set: { id in selectedInstance = instances.first { $0.id == id } }
                )) { instance in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(instance.dbInstanceIdentifier ?? "-")
                                .font(.body.bold())
                                .lineLimit(1)
                            Spacer()
                            if let status = instance.dbInstanceStatus {
                                StatusBadge(status)
                            }
                        }
                        Text("\(instance.engine ?? "-") \(instance.engineVersion ?? "") · \(instance.dbInstanceClass ?? "-")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 10) {
                            if let az = instance.availabilityZone { Label(az, systemImage: "mappin") }
                            if instance.multiAZ == true { Label("Multi-AZ", systemImage: "square.on.square") }
                            if let storage = instance.allocatedStorage { Label("\(storage) GB", systemImage: "internaldrive") }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .tag(instance.id)
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
        selectedInstance = nil
        do {
            let response = try await api.getRDSInstances(profile: appState.currentProfile, region: appState.currentRegion)
            state = response.loadState()
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
