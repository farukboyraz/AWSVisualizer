import SwiftUI

private let ebHealthOrder = ["Green", "Yellow", "Red", "Grey"]

struct EnvironmentsView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[EBEnvironment]> = .loading
    @State private var selectedEnvironmentName: String?
    @State private var showCloneSheet = false
    @State private var collapsedHealths: Set<String> = []

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 320, minWidth: 260, maxWidth: 480, isDetailActive: selectedEnvironmentName != nil, onBack: { selectedEnvironmentName = nil }, backTitle: "Environments", detailTitle: selectedEnvironmentName) {
                environmentListPanel
            } detail: {
                if let selectedEnvironmentName {
                    EBEnvironmentDetailView(environmentName: selectedEnvironmentName) {
                        self.selectedEnvironmentName = nil
                        Task { await loadEnvironments() }
                    }
                    .id(selectedEnvironmentName)
                } else {
                    EmptyStateView(message: "Select an environment")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadEnvironments()
            }
        }
        .sheet(isPresented: $showCloneSheet) {
            if case .loaded(let environments) = state {
                CloneEnvironmentSheet(environments: environments) {
                    showCloneSheet = false
                    Task { await loadEnvironments() }
                }
            }
        }
    }

    private var environmentListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadEnvironments() } }, emptyMessage: "No environments") { unfilteredEnvironments in
                let environments = unfilteredEnvironments.matching(filter)
                List {
                    ForEach(groupedEnvironments(environments), id: \.health) { group in
                        healthGroup(group.health, group.environments)
                    }
                }
                .listStyle(.plain)
            }
            header
        }
    }

    /// Bottom action bar of the environment list.
    private var header: some View {
        PanelActionBar {
            ScreenTitle("Elastic Beanstalk Environments")
            if case .loaded(let environments) = state, !environments.isEmpty {
                CloneButton("Clone Environment", systemImage: "plus") {
                    showCloneSheet = true
                }
            }
            RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadEnvironments() } }
        }
    }

    /// A collapsible group of environments sharing one health status - same
    /// tap-to-toggle folder pattern used for EC2's state groups and the
    /// branch/log-group trees (`PathTree.swift`), grouped by health instead.
    private func healthGroup(_ health: String, _ environments: [EBEnvironment]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    if collapsedHealths.contains(health) {
                        collapsedHealths.remove(health)
                    } else {
                        collapsedHealths.insert(health)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsedHealths.contains(health) ? "chevron.right" : "chevron.down")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Circle()
                        .fill(healthColor(health))
                        .frame(width: 8, height: 8)
                    Text("\(health.uppercased()) · \(environments.count)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsedHealths.contains(health) {
                ForEach(environments) { env in
                    environmentRow(env)
                        .padding(.leading, 16)
                }
            }
        }
    }

    private func environmentRow(_ env: EBEnvironment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "leaf")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(env.environmentName ?? "-")
                    .font(.body.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(env.applicationName ?? "-") · \(env.status ?? "-")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(env.environmentName == selectedEnvironmentName ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedEnvironmentName = env.environmentName
        }
    }

    private func healthColor(_ health: String) -> Color {
        switch health {
        case "Green": return .green
        case "Yellow": return .yellow
        case "Red": return .red
        default: return .secondary
        }
    }

    private func groupedEnvironments(_ environments: [EBEnvironment]) -> [(health: String, environments: [EBEnvironment])] {
        let grouped = Dictionary(grouping: environments, by: { $0.health ?? "Grey" })
        let orderedKeys = ebHealthOrder.filter { grouped[$0] != nil } + grouped.keys.filter { !ebHealthOrder.contains($0) }.sorted()
        return orderedKeys.map { (health: $0, environments: grouped[$0] ?? []) }
    }

    private func loadEnvironments() async {
        state = .loading
        do {
            let environments = try await api.getEnvironments(profile: appState.currentProfile, region: appState.currentRegion)
            state = environments.isEmpty ? .empty : .loaded(environments)
            if let selectedEnvironmentName, case .loaded(let environments) = state, !environments.contains(where: { $0.environmentName == selectedEnvironmentName }) {
                self.selectedEnvironmentName = nil
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Approximates the console's "Clone Environment" action: reuses the
/// source's platform, app version and tier - not a byte-for-byte config
/// clone (see `cloneEnvironment` in the backend for why).
private struct CloneEnvironmentSheet: View {
    let environments: [EBEnvironment]
    var onCloned: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var sourceEnvironmentName: String
    @State private var newEnvironmentName = ""
    @State private var cnamePrefix = ""
    @State private var isCloning = false
    @State private var errorMessage: String?

    init(environments: [EBEnvironment], onCloned: @escaping () -> Void) {
        self.environments = environments
        self.onCloned = onCloned
        self._sourceEnvironmentName = State(initialValue: environments.first?.environmentName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Clone Environment")
                    .font(.title2.bold())
                Spacer()
                SecondaryButton("Cancel") { dismiss() }
            }

            field("Source Environment") {
                Picker("", selection: $sourceEnvironmentName) {
                    ForEach(environments) { env in
                        Text(env.environmentName ?? "-").tag(env.environmentName ?? "")
                    }
                }
                .labelsHidden()
            }
            field("New Environment Name") {
                TextField("my-env-clone", text: $newEnvironmentName)
                    .textFieldStyle(.roundedBorder)
            }
            field("CNAME Prefix (optional)") {
                TextField("Auto-generated if left blank", text: $cnamePrefix)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                CloneButton("Clone Environment", isLoading: isCloning, isDisabled: !isFormValid) {
                    Task { await clone() }
                }
            }
        }
        .padding(24)
        .frame(width: 420, height: 320)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var isFormValid: Bool {
        !sourceEnvironmentName.isEmpty && !newEnvironmentName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func clone() async {
        isCloning = true
        errorMessage = nil
        do {
            _ = try await api.cloneEbEnvironment(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                sourceEnvironmentName: sourceEnvironmentName,
                newEnvironmentName: newEnvironmentName.trimmingCharacters(in: .whitespaces),
                cnamePrefix: cnamePrefix.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cnamePrefix
            )
            onCloned()
        } catch {
            errorMessage = error.friendlyMessage
        }
        isCloning = false
    }
}
