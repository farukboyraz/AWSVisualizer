import SwiftUI

private let retentionOptions: [Int?] = [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653, nil]

/// Mirrors a log group's page in the CloudWatch Logs console: Streams (list,
/// tap one to see its recent events) and Settings (retention policy,
/// delete). AWS Logs has no partial-update API for a log group itself -
/// retention is the one thing that's actually editable here, matching the
/// console.
struct CloudWatchLogGroupDetailView: View {
    let logGroupName: String
    let retentionInDays: Int?
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    private enum DetailTab: String, CaseIterable {
        case streams = "Log Streams"
        case settings = "Settings"
    }

    @State private var tab: DetailTab = .streams

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(title: logGroupName, tab: $tab)

            Group {
                switch tab {
                case .streams:
                    CloudWatchLogStreamsView(logGroupName: logGroupName)
                case .settings:
                    CloudWatchLogGroupSettingsView(logGroupName: logGroupName, retentionInDays: retentionInDays, onDeleted: onDeleted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(logGroupName)
    }
}

private struct CloudWatchLogStreamsView: View {
    let logGroupName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var streamsState: LoadState<[LogStreamInfo]> = .loading
    @State private var selectedStreamIDs: Set<LogStreamInfo.ID> = []
    @State private var selectedStream: LogStreamInfo?

    var body: some View {
        LoadableContent(streamsState, retry: { Task { await load() } }, emptyMessage: "No log streams") { streams in
            Table(streams, selection: $selectedStreamIDs) {
                TableColumn("Stream") { s in
                    Text(s.logStreamName)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 200, ideal: 380)

                TableColumn("Last Event") { s in
                    Text(Formatters.formatEpochMillis(s.lastEventTimestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .width(min: 130, ideal: 170)

                TableColumn("Stored") { s in
                    Text(Formatters.formatBytes(s.storedBytes))
                        .font(.caption)
                }
                .width(min: 70, ideal: 90)
            }
            .contextMenu(forSelectionType: LogStreamInfo.ID.self) { ids in
                if let id = ids.first, let stream = streams.first(where: { $0.id == id }) {
                    Button("View Events") { selectedStream = stream }
                }
            } primaryAction: { ids in
                if let id = ids.first, let stream = streams.first(where: { $0.id == id }) {
                    selectedStream = stream
                }
            }
        }
        .task { await load() }
        .sheet(item: $selectedStream) { stream in
            CloudWatchLogEventsView(logGroupName: logGroupName, logStreamName: stream.logStreamName)
        }
    }

    private func load() async {
        streamsState = .loading
        do {
            let streams = try await api.getLogGroupStreams(profile: appState.currentProfile, region: appState.currentRegion, logGroupName: logGroupName)
            streamsState = streams.isEmpty ? .empty : .loaded(streams)
        } catch {
            streamsState = .failed(error.friendlyMessage)
        }
    }
}

private struct CloudWatchLogEventsView: View {
    let logGroupName: String
    let logStreamName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var eventsState: LoadState<[LogEventInfo]> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log Events")
                        .font(.title3.bold())
                    Text(logStreamName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                SecondaryButton("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            LoadableContent(eventsState, retry: { Task { await load() } }, emptyMessage: "No events") { events in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Text(Formatters.formatEpochMillis(event.timestamp))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 150, alignment: .leading)
                                Text(event.message ?? "")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 900, maxWidth: .infinity, minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .task {
            await load()
        }
    }

    private func load() async {
        eventsState = .loading
        do {
            let events = try await api.getLogGroupEvents(profile: appState.currentProfile, region: appState.currentRegion, logGroupName: logGroupName, logStreamName: logStreamName)
            eventsState = events.isEmpty ? .empty : .loaded(events)
        } catch {
            eventsState = .failed(error.friendlyMessage)
        }
    }
}

private struct CloudWatchLogGroupSettingsView: View {
    let logGroupName: String
    let retentionInDays: Int?
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var selectedRetention: Int?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saved = false

    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Retention")
                        .font(.headline)
                    Text("How long CloudWatch keeps this log group's events before automatically expiring them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $selectedRetention) {
                        ForEach(retentionOptions, id: \.self) { days in
                            Text(days.map { "\($0) days" } ?? "Never expire").tag(days)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)

                    HStack {
                        if let saveError {
                            Text(saveError).font(.caption).foregroundStyle(.red)
                        }
                        if saved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        SaveButton("Save Retention", isLoading: isSaving, isDisabled: selectedRetention == retentionInDays) {
                            Task { await save() }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Danger zone")
                        .font(.headline)
                        .foregroundStyle(.red)
                    DeleteButton("Delete Log Group", isLoading: isDeleting) {
                        Task { await deleteLogGroup() }
                    }
                    if let deleteError {
                        Text(deleteError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: logGroupName) {
            selectedRetention = retentionInDays
            saved = false
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        saved = false
        do {
            try await api.setLogGroupRetention(profile: appState.currentProfile, region: appState.currentRegion, logGroupName: logGroupName, retentionInDays: selectedRetention)
            saved = true
        } catch {
            saveError = error.friendlyMessage
        }
        isSaving = false
    }

    private func deleteLogGroup() async {
        isDeleting = true
        deleteError = nil
        do {
            try await api.deleteLogGroup(profile: appState.currentProfile, region: appState.currentRegion, logGroupName: logGroupName)
            onDeleted()
        } catch {
            deleteError = error.friendlyMessage
        }
        isDeleting = false
    }
}
