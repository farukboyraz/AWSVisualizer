import SwiftUI

/// Nitro Enclaves have no console of their own: an enclave runs inside an
/// EC2 instance launched with enclave support. This lists those parent
/// instances and opens the regular EC2 instance page for each.
struct NitroEnclavesView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[Ec2Instance]> = .loading
    @State private var selectedId: String?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 320, minWidth: 240, maxWidth: 480, isDetailActive: selectedId != nil, onBack: { selectedId = nil }, backTitle: "Instances", detailTitle: selectedId) {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle("Nitro Enclaves")
                    DetailNote("EC2 instances launched with Nitro Enclaves enabled. Enclaves themselves are managed with nitro-cli on the instance.")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    ScreenFilterField(text: $filter)
                    LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No enclave-enabled instances in this region") { unfilteredInstances in
                        let instances = unfilteredInstances.matching(filter)
                        List(instances, selection: $selectedId) { inst in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(inst.name?.isEmpty == false ? inst.name! : (inst.instanceId ?? "-"))
                                        .font(.body.bold())
                                        .lineLimit(1)
                                    Spacer()
                                    if let state = inst.state { StatusBadge(state) }
                                }
                                Text([inst.instanceId, inst.instanceType, inst.availabilityZone].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 2)
                            .tag(inst.instanceId ?? "")
                        }
                        .listStyle(.sidebar)
                    }
                    PanelActionBar {
                        RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
                    }
                }
            } detail: {
                if let selectedId {
                    EC2InstanceDetailView(instanceId: selectedId) {
                        self.selectedId = nil
                        Task { await loadData() }
                    }
                    .id(selectedId)
                } else {
                    EmptyStateView(message: "Select an instance")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private func loadData() async {
        state = .loading
        do {
            let instances = try await api.getEnclaveInstances(profile: appState.currentProfile, region: appState.currentRegion)
            state = instances.isEmpty ? .empty : .loaded(instances)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
