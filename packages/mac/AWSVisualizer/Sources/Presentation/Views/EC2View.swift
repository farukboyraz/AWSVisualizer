import SwiftUI

private let ec2StateOrder = ["running", "pending", "stopping", "stopped", "shutting-down", "terminated"]

struct EC2View: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[Ec2Instance]> = .loading
    @State private var selectedInstanceId: String?
    @State private var showLaunchSheet = false
    @State private var collapsedStates: Set<String> = []

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 320, minWidth: 260, maxWidth: 480, isDetailActive: selectedInstanceId != nil, onBack: { selectedInstanceId = nil }, backTitle: "Instances", detailTitle: selectedInstanceId) {
                instanceListPanel
            } detail: {
                if let selectedInstanceId {
                    EC2InstanceDetailView(instanceId: selectedInstanceId) {
                        self.selectedInstanceId = nil
                        Task { await loadData() }
                    }
                    .id(selectedInstanceId)
                } else {
                    EmptyStateView(message: "Select an instance")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
        .sheet(isPresented: $showLaunchSheet) {
            LaunchInstanceSheet {
                showLaunchSheet = false
                Task { await loadData() }
            }
        }
    }

    private var instanceListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No instances") { unfilteredInstances in
                let instances = unfilteredInstances.matching(filter)
                List {
                    ForEach(groupedInstances(instances), id: \.state) { group in
                        stateGroup(group.state, group.instances)
                    }
                }
                .listStyle(.plain)
            }
            header
        }
    }

    /// Bottom action bar of the instance list.
    private var header: some View {
        PanelActionBar {
            ScreenTitle("EC2 Instances")
            NewButton("Launch Instance") {
                showLaunchSheet = true
            }
            RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
        } trailing: {
            if case .loaded(let instances) = state {
                Text("\(instances.count) instances")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A collapsible group of instances sharing one state - same tap-to-
    /// toggle folder pattern as the branch/log-group trees (`PathTree.swift`),
    /// just grouped by state instead of by "/" path since EC2 instances
    /// don't have hierarchical names.
    private func stateGroup(_ stateName: String, _ instances: [Ec2Instance]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    if collapsedStates.contains(stateName) {
                        collapsedStates.remove(stateName)
                    } else {
                        collapsedStates.insert(stateName)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsedStates.contains(stateName) ? "chevron.right" : "chevron.down")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: stateIconName(stateName))
                        .font(.caption)
                        .foregroundStyle(stateColor(stateName))
                    Text("\(stateName.uppercased()) · \(instances.count)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsedStates.contains(stateName) {
                ForEach(instances) { instance in
                    instanceRow(instance)
                        .padding(.leading, 16)
                }
            }
        }
    }

    private func instanceRow(_ instance: Ec2Instance) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text((instance.name?.isEmpty == false ? instance.name : instance.instanceId) ?? "-")
                    .font(.body.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(instance.instanceType ?? "-") · \(instance.instanceId ?? "-")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(instance.instanceId == selectedInstanceId ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedInstanceId = instance.instanceId
        }
    }

    private func stateColor(_ stateName: String) -> Color {
        switch stateName {
        case "running": return .green
        case "stopped": return .secondary
        case "terminated": return .red
        case "pending", "stopping", "shutting-down": return .orange
        default: return .secondary
        }
    }

    private func stateIconName(_ stateName: String) -> String {
        switch stateName {
        case "running": return "play.circle.fill"
        case "stopped": return "stop.circle.fill"
        case "terminated": return "xmark.circle.fill"
        default: return "clock.fill"
        }
    }

    private func groupedInstances(_ instances: [Ec2Instance]) -> [(state: String, instances: [Ec2Instance])] {
        let grouped = Dictionary(grouping: instances, by: { $0.state ?? "unknown" })
        let orderedKeys = ec2StateOrder.filter { grouped[$0] != nil } + grouped.keys.filter { !ec2StateOrder.contains($0) }.sorted()
        return orderedKeys.map { (state: $0, instances: grouped[$0] ?? []) }
    }

    private func loadData() async {
        state = .loading
        do {
            let response = try await api.getEC2Instances(profile: appState.currentProfile, region: appState.currentRegion)
            state = response.loadState()
            if let selectedInstanceId, case .loaded(let instances) = state, !instances.contains(where: { $0.instanceId == selectedInstanceId }) {
                self.selectedInstanceId = nil
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// A minimal, power-user "Launch Instance" - AMI ID and instance type typed
/// by hand (no AMI browser), key pair picked from what's already in the
/// account, security group/subnet as optional plain IDs. AWS's own launch
/// wizard has a lot more (storage config, user data, multiple ENIs, etc.)
/// that's out of scope here.
private struct LaunchInstanceSheet: View {
    var onLaunched: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var imageId = ""
    @State private var instanceType = "t3.micro"
    @State private var keyPairsState: LoadState<[Ec2KeyPair]> = .loading
    @State private var selectedKeyName = ""
    @State private var securityGroupIdsText = ""
    @State private var subnetId = ""
    @State private var isLaunching = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Launch Instance")
                    .font(.title2.bold())
                Spacer()
                SecondaryButton("Cancel") { dismiss() }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Name (optional)") {
                        TextField("my-instance", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    field("AMI ID") {
                        TextField("ami-0123456789abcdef0", text: $imageId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    field("Instance Type") {
                        TextField("t3.micro", text: $instanceType)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    field("Key Pair (optional)") {
                        if case .loaded(let keyPairs) = keyPairsState, !keyPairs.isEmpty {
                            Picker("", selection: $selectedKeyName) {
                                Text("None").tag("")
                                ForEach(keyPairs) { kp in
                                    Text(kp.keyName).tag(kp.keyName)
                                }
                            }
                            .labelsHidden()
                        } else {
                            Text("No key pairs found in this account/region.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    field("Security Group IDs (optional, comma-separated)") {
                        TextField("sg-0123456789abcdef0", text: $securityGroupIdsText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    field("Subnet ID (optional)") {
                        TextField("subnet-0123456789abcdef0", text: $subnetId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                NewButton("Launch Instance", isLoading: isLaunching, isDisabled: !isFormValid) {
                    Task { await launch() }
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 520)
        .task {
            await loadKeyPairs()
        }
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
        !imageId.trimmingCharacters(in: .whitespaces).isEmpty && !instanceType.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadKeyPairs() async {
        keyPairsState = .loading
        do {
            let keyPairs = try await api.getEc2KeyPairs(profile: appState.currentProfile, region: appState.currentRegion)
            keyPairsState = keyPairs.isEmpty ? .empty : .loaded(keyPairs)
        } catch {
            keyPairsState = .failed(error.friendlyMessage)
        }
    }

    private func launch() async {
        isLaunching = true
        errorMessage = nil
        let securityGroupIds = securityGroupIdsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            _ = try await api.launchEc2Instance(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                imageId: imageId.trimmingCharacters(in: .whitespaces),
                instanceType: instanceType.trimmingCharacters(in: .whitespaces),
                keyName: selectedKeyName.isEmpty ? nil : selectedKeyName,
                securityGroupIds: securityGroupIds.isEmpty ? nil : securityGroupIds,
                subnetId: subnetId.trimmingCharacters(in: .whitespaces).isEmpty ? nil : subnetId,
                name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
            )
            onLaunched()
        } catch {
            errorMessage = error.friendlyMessage
        }
        isLaunching = false
    }
}
