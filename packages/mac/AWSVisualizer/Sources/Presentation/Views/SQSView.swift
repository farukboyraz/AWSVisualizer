import SwiftUI

struct SQSView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[SqsQueue]> = .loading
    @State private var selectedQueue: SqsQueue?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 280, minWidth: 220, maxWidth: 460, isDetailActive: selectedQueue != nil, onBack: { selectedQueue = nil }, backTitle: "Queues", detailTitle: selectedQueue?.queueName) {
                queueListPanel
            } detail: {
                if let selectedQueue {
                    SqsQueueDetailView(queueUrl: selectedQueue.queueUrl ?? "")
                        .id(selectedQueue.id)
                } else {
                    EmptyStateView(message: "Select a queue")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private var queueListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("SQS Queues")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }) { unfilteredQueues in
                let queues = unfilteredQueues.matching(filter)
                List(queues, selection: Binding(
                    get: { selectedQueue?.id },
                    set: { id in selectedQueue = queues.first { $0.id == id } }
                )) { queue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(queue.queueName ?? "-")
                            .font(.body.bold())
                        HStack(spacing: 10) {
                            Label("\(queue.approximateMessages ?? 0)", systemImage: "envelope")
                            if let inFlight = queue.approximateMessagesNotVisible, inFlight > 0 {
                                Label("\(inFlight)", systemImage: "eye.slash")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(queue.id)
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
        selectedQueue = nil
        do {
            let response = try await api.getSQSQueues(profile: appState.currentProfile, region: appState.currentRegion)
            state = response.loadState()
            // A dashboard card asked for one queue.
            if let link = appState.takeDeepLink(for: "sqs"), case .loaded(let queues) = state {
                selectedQueue = queues.first { $0.queueUrl == link.resource }
            }
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
