import SwiftUI

struct SnsView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[SnsTopic]> = .loading
    @State private var selectedTopic: SnsTopic?
    @State private var showCreate = false

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 300, minWidth: 220, maxWidth: 480, isDetailActive: selectedTopic != nil, onBack: { selectedTopic = nil }, backTitle: "Topics", detailTitle: selectedTopic?.name) {
                topicListPanel
            } detail: {
                if let selectedTopic {
                    SnsTopicDetailView(topicArn: selectedTopic.topicArn, onDeleted: {
                        self.selectedTopic = nil
                        Task { await loadData() }
                    })
                    .id(selectedTopic.id)
                } else {
                    EmptyStateView(message: "Select a topic")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
            .sheet(isPresented: $showCreate) {
                SnsCreateTopicSheet { created in
                    Task {
                        await loadData()
                        selectedTopic = created
                    }
                }
            }
        }
    }

    private var topicListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("SNS Topics")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }) { unfilteredTopics in
                let topics = unfilteredTopics.matching(filter)
                List(topics, selection: Binding(
                    get: { selectedTopic?.id },
                    set: { id in selectedTopic = topics.first { $0.id == id } }
                )) { topic in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(topic.name)
                                .font(.body.bold())
                                .lineLimit(1)
                            if topic.name.hasSuffix(".fifo") {
                                StatusBadge("FIFO", color: .purple)
                            }
                        }
                        Text(topic.topicArn)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                    .tag(topic.id)
                }
                .listStyle(.sidebar)
            }
            PanelActionBar {
                NewButton(compactSize: 24, help: "Create Topic") { showCreate = true }
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
            }
        }
    }

    private func loadData() async {
        state = .loading
        selectedTopic = nil
        do {
            let topics = try await api.getTopics(profile: appState.currentProfile, region: appState.currentRegion)
            state = topics.isEmpty ? .empty : .loaded(topics)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct SnsCreateTopicSheet: View {
    var onCreated: (SnsTopic) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var displayName = ""
    @State private var fifo = false
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create topic").font(.title3.bold())

            Picker("Type", selection: $fifo) {
                Text("Standard").tag(false)
                Text("FIFO").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            Text(fifo
                 ? "Strict ordering and exactly-once delivery; only SQS FIFO queues can subscribe. \".fifo\" is appended to the name."
                 : "Best-effort ordering, at-least-once delivery; supports every subscription protocol.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Display name (optional - used as the SMS sender name)", text: $displayName)
                .textFieldStyle(.roundedBorder)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                SecondaryButton("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                NewButton("Create Topic", isLoading: isCreating, isDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await create() }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func create() async {
        isCreating = true
        error = nil
        do {
            let topic = try await api.createSnsTopic(profile: appState.currentProfile, region: appState.currentRegion, name: name.trimmingCharacters(in: .whitespaces), fifo: fifo, displayName: displayName)
            onCreated(topic)
            dismiss()
        } catch {
            self.error = error.friendlyMessage
        }
        isCreating = false
    }
}
