import SwiftUI

struct CloudWatchView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedTab = 0

    var body: some View {
        AuthGuardedView {
            VStack(alignment: .leading, spacing: 0) {
                TabBar(tabs: [0, 1], selection: $selectedTab, title: { $0 == 0 ? "Alarms" : "Log Groups" }, icon: { $0 == 0 ? "bell" : "doc.text" })
                    .padding(.vertical, 8)

                if selectedTab == 0 {
                    CloudWatchAlarmsPane()
                } else {
                    CloudWatchLogGroupsPane()
                }
            }
            .screenTitle("CloudWatch")
        }
    }

}

private struct CloudWatchAlarmsPane: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[CloudWatchAlarm]> = .loading
    @State private var selectedAlarm: CloudWatchAlarm?

    var body: some View {
        MasterDetailView(initialWidth: 340, minWidth: 260, maxWidth: 520, isDetailActive: selectedAlarm != nil, onBack: { selectedAlarm = nil }, backTitle: "Alarms", detailTitle: selectedAlarm?.alarmName) {
            listPanel
        } detail: {
            if let selectedAlarm, let name = selectedAlarm.alarmName {
                CloudWatchAlarmDetailView(alarmName: name) {
                    Task { await loadData() }
                }
                .id(name)
            } else {
                EmptyStateView(message: "Select an alarm")
            }
        }
        .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
            await loadData()
        }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }) { unfilteredAlarms in
                let alarms = unfilteredAlarms.matching(filter)
                List(alarms, selection: Binding(
                    get: { selectedAlarm?.id },
                    set: { id in selectedAlarm = alarms.first { $0.id == id } }
                )) { alarm in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(alarm.alarmName ?? "-")
                            .font(.body.bold())
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let state = alarm.stateValue {
                                StatusBadge(state)
                            }
                            Text(alarm.metricName ?? "-")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(alarm.id)
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
            let response = try await api.getCloudWatchAlarms(profile: appState.currentProfile, region: appState.currentRegion)
            state = response.loadState()
            if let selectedAlarm, case .loaded(let alarms) = state, !alarms.contains(where: { $0.id == selectedAlarm.id }) {
                self.selectedAlarm = nil
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private struct CloudWatchLogGroupsPane: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[LogGroup]> = .loading
    @State private var selectedLogGroup: LogGroup?

    var body: some View {
        MasterDetailView(initialWidth: 340, minWidth: 260, maxWidth: 520, isDetailActive: selectedLogGroup != nil, onBack: { selectedLogGroup = nil }, backTitle: "Log Groups", detailTitle: selectedLogGroup?.logGroupName) {
            listPanel
        } detail: {
            if let selectedLogGroup, let name = selectedLogGroup.logGroupName {
                CloudWatchLogGroupDetailView(logGroupName: name, retentionInDays: selectedLogGroup.retentionInDays) {
                    Task { await loadData() }
                }
                .id(name)
            } else {
                EmptyStateView(message: "Select a log group")
            }
        }
        .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
            await loadData()
        }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No log groups") { unfilteredLogGroups in
                let logGroups = unfilteredLogGroups.matching(filter)
                List {
                    PathTreeView(nodes: buildPathTree(logGroups, path: { $0.logGroupName ?? "" })) { logGroup in
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text(leafName(logGroup.logGroupName ?? ""))
                                .font(.body)
                                .lineLimit(1)
                            Spacer()
                            Text(Formatters.formatBytes(logGroup.storedBytes))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(selectedLogGroup?.id == logGroup.id ? Color.accentColor.opacity(0.15) : Color.clear)
                        .onTapGesture {
                            selectedLogGroup = logGroup
                        }
                    }
                }
                .listStyle(.plain)
            }
            PanelActionBar {
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
            }
        }
    }

    private func leafName(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    private func loadData() async {
        state = .loading
        do {
            let response = try await api.getLogGroups(profile: appState.currentProfile, region: appState.currentRegion)
            state = response.loadState()
            if let selectedLogGroup, case .loaded(let logGroups) = state, !logGroups.contains(where: { $0.id == selectedLogGroup.id }) {
                self.selectedLogGroup = nil
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
