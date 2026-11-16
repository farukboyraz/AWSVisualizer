import SwiftUI

/// Mirrors an instance's page in the EC2 console: the "Instance state"
/// actions (Start / Stop / Reboot / Terminate) above the tabs, then the
/// console's tabs - Details (instance summary + instance settings),
/// Security, Networking, Storage, Tags. Built from the shared detail
/// components.
struct EC2InstanceDetailView: View {
    let instanceId: String
    var onTerminated: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case security = "Security"
        case networking = "Networking"
        case storage = "Storage"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .details
    @State private var detailState: LoadState<Ec2InstanceDetail> = .loading
    @State private var pendingAction: String?
    @State private var actionError: String?

    var body: some View {
        LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(
                    title: detail.name.isEmpty ? detail.instanceId : detail.name,
                    subtitle: "\(detail.instanceId) · \(detail.instanceType)",
                    status: detail.state,
                    tab: $tab
                )
                actionBar(detail)

                Group {
                    switch tab {
                    case .details:
                        EC2DetailsTab(detail: detail, onUpdated: { detailState = .loaded($0) })
                    case .security:
                        EC2SecurityTab(detail: detail)
                    case .networking:
                        EC2NetworkingTab(detail: detail)
                    case .storage:
                        EC2StorageTab(detail: detail)
                    case .tags:
                        ResourceTagsEditor(tags: detail.tags, resourceNoun: "instance", onAdd: { key, value in
                            detailState = .loaded(try await api.addEc2Tag(profile: appState.currentProfile, region: appState.currentRegion, instanceId: instanceId, key: key, value: value))
                        }, onRemove: { key in
                            detailState = .loaded(try await api.removeEc2Tag(profile: appState.currentProfile, region: appState.currentRegion, instanceId: instanceId, key: key))
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: instanceId) {
            await loadDetail()
        }
    }

    private func actionBar(_ detail: Ec2InstanceDetail) -> some View {
        let isRunning = detail.state == "running"
        let isStopped = detail.state == "stopped"
        let isTerminal = detail.state == "terminated" || detail.state == "shutting-down"
        return DetailActionBar(
            error: actionError,
            note: detail.disableApiTermination && !isTerminal ? "Termination protection is on - turn it off under Details › Instance settings to terminate." : nil,
            onRefresh: { Task { await loadDetail() } }
        ) {
            ConfirmedActionButton(
                title: "Start",
                systemImage: "play.fill",
                confirmationTitle: "Start \(detail.name.isEmpty ? detail.instanceId : detail.name)?",
                confirmationMessage: "Billing for the instance resumes once it's running. The public IP may change unless it's an Elastic IP.",
                isLoading: pendingAction == "start",
                isDisabled: !isStopped || pendingAction != nil,
                role: nil
            ) { Task { await setState("start") } }
            ConfirmedActionButton(
                title: "Stop",
                systemImage: "stop.fill",
                confirmationTitle: "Stop \(detail.name.isEmpty ? detail.instanceId : detail.name)?",
                confirmationMessage: "Instance store data is lost and the public IP is released (Elastic IPs stay). EBS volumes are kept.",
                isLoading: pendingAction == "stop",
                isDisabled: !isRunning || pendingAction != nil
            ) { Task { await setState("stop") } }
            ConfirmedActionButton(
                title: "Reboot",
                systemImage: "arrow.clockwise",
                confirmationTitle: "Reboot \(detail.name.isEmpty ? detail.instanceId : detail.name)?",
                confirmationMessage: "The instance is unavailable while it restarts. IP addresses and data are kept.",
                isLoading: pendingAction == "reboot",
                isDisabled: !isRunning || pendingAction != nil
            ) { Task { await setState("reboot") } }
            if !isTerminal {
                DeleteButton("Terminate", isLoading: pendingAction == "terminate", isDisabled: detail.disableApiTermination || pendingAction != nil) {
                    Task { await terminate() }
                }
            }
        }
    }

    private func setState(_ action: String) async {
        pendingAction = action
        actionError = nil
        do {
            try await api.setEc2InstanceState(profile: appState.currentProfile, region: appState.currentRegion, instanceId: instanceId, action: action)
            await loadDetail()
        } catch {
            actionError = error.friendlyMessage
        }
        pendingAction = nil
    }

    private func terminate() async {
        pendingAction = "terminate"
        actionError = nil
        do {
            try await api.setEc2InstanceState(profile: appState.currentProfile, region: appState.currentRegion, instanceId: instanceId, action: "terminate")
            onTerminated()
        } catch {
            actionError = error.friendlyMessage
        }
        pendingAction = nil
    }

    private func loadDetail() async {
        do {
            detailState = .loaded(try await api.getEc2InstanceDetail(profile: appState.currentProfile, region: appState.currentRegion, instanceId: instanceId))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

/// "Instance summary" plus the console's Actions › Instance settings
/// (change instance type, detailed monitoring, termination protection).
private struct EC2DetailsTab: View {
    let detail: Ec2InstanceDetail
    var onUpdated: (Ec2InstanceDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var instanceTypeText = ""
    @State private var isSavingType = false
    @State private var typeError: String?
    @State private var typeSaved = false
    @State private var isTogglingMonitoring = false
    @State private var isTogglingProtection = false
    @State private var toggleError: String?

    private var isStopped: Bool { detail.state == "stopped" }
    private var isTerminal: Bool { detail.state == "terminated" || detail.state == "shutting-down" }

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Instance summary", spacing: 12) {
                DetailGrid(items: [
                    DetailItem("Instance ID", detail.instanceId),
                    DetailItem("Instance state", detail.state, monospaced: false),
                    DetailItem("Instance type", detail.instanceType),
                    DetailItem("Public IPv4 address", detail.publicIp),
                    DetailItem("Private IPv4 address", detail.privateIp),
                    DetailItem("Public DNS", detail.publicDnsName),
                    DetailItem("Private DNS", detail.privateDnsName),
                    DetailItem("Platform", detail.platform, monospaced: false),
                    DetailItem("Architecture", detail.architecture),
                    DetailItem("AMI ID", detail.imageId),
                    DetailItem("Launch time", Formatters.formatISODate(detail.launchTime), monospaced: false),
                    DetailItem("Availability Zone", detail.availabilityZone),
                    DetailItem("IAM role", detail.iamInstanceProfileArn.map { $0.split(separator: "/").last.map(String.init) ?? $0 }),
                    DetailItem("Monitoring", detail.monitoringEnabled ? "Detailed (1 min)" : "Basic (5 min)", monospaced: false),
                    DetailItem("Termination protection", detail.disableApiTermination ? "Enabled" : "Disabled", monospaced: false),
                ])
            }

            Divider()

            DetailSection(title: "Instance settings", spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Instance type").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("e.g. t3.micro", text: $instanceTypeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        SaveButton("Change", isLoading: isSavingType, isDisabled: instanceTypeText == detail.instanceType || !isStopped) {
                            Task { await saveInstanceType() }
                        }
                        if typeSaved {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    if !isStopped {
                        Text("The instance type can only be changed while the instance is stopped.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let typeError {
                        Text(typeError).font(.caption).foregroundStyle(.red)
                    }
                }
                Toggle("Detailed monitoring (1-minute CloudWatch metrics, extra cost)", isOn: Binding(
                    get: { detail.monitoringEnabled },
                    set: { newValue in Task { await setMonitoring(newValue) } }
                ))
                .disabled(isTogglingMonitoring || isTerminal)
                Toggle("Termination protection", isOn: Binding(
                    get: { detail.disableApiTermination },
                    set: { newValue in Task { await setProtection(newValue) } }
                ))
                .disabled(isTogglingProtection || isTerminal)
                if let toggleError {
                    Text(toggleError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .task(id: "\(detail.instanceId)-\(detail.instanceType)") {
            instanceTypeText = detail.instanceType
        }
    }

    private func saveInstanceType() async {
        isSavingType = true
        typeError = nil
        typeSaved = false
        do {
            onUpdated(try await api.setEc2InstanceType(profile: appState.currentProfile, region: appState.currentRegion, instanceId: detail.instanceId, instanceType: instanceTypeText.trimmingCharacters(in: .whitespaces)))
            typeSaved = true
        } catch {
            typeError = error.friendlyMessage
        }
        isSavingType = false
    }

    private func setMonitoring(_ enabled: Bool) async {
        isTogglingMonitoring = true
        toggleError = nil
        do {
            onUpdated(try await api.setEc2Monitoring(profile: appState.currentProfile, region: appState.currentRegion, instanceId: detail.instanceId, enabled: enabled))
        } catch {
            toggleError = error.friendlyMessage
        }
        isTogglingMonitoring = false
    }

    private func setProtection(_ enabled: Bool) async {
        isTogglingProtection = true
        toggleError = nil
        do {
            onUpdated(try await api.setEc2TerminationProtection(profile: appState.currentProfile, region: appState.currentRegion, instanceId: detail.instanceId, enabled: enabled))
        } catch {
            toggleError = error.friendlyMessage
        }
        isTogglingProtection = false
    }
}

private struct EC2SecurityTab: View {
    let detail: Ec2InstanceDetail

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Security details", spacing: 12) {
                DetailGrid(items: [
                    DetailItem("IAM role", detail.iamInstanceProfileArn),
                    DetailItem("Key pair", detail.keyName),
                ])
            }
            DetailSection(title: "Security groups", spacing: 6) {
                if detail.securityGroups.isEmpty {
                    Text("No security groups.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(detail.securityGroups) { sg in
                        HStack(spacing: 8) {
                            Image(systemName: "shield.lefthalf.filled").foregroundStyle(.secondary)
                            Text(sg.groupId).font(.caption.monospaced()).textSelection(.enabled)
                            Text(sg.groupName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct EC2NetworkingTab: View {
    let detail: Ec2InstanceDetail

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Networking details", spacing: 12) {
                DetailGrid(items: [
                    DetailItem("Public IPv4 address", detail.publicIp),
                    DetailItem("Private IPv4 address", detail.privateIp),
                    DetailItem("Public DNS", detail.publicDnsName),
                    DetailItem("Private DNS", detail.privateDnsName),
                    DetailItem("VPC ID", detail.vpcId),
                    DetailItem("Subnet ID", detail.subnetId),
                    DetailItem("Availability Zone", detail.availabilityZone),
                    DetailItem("Hostname type", detail.hostname),
                ])
            }
            let interfaces = detail.networkInterfaces ?? []
            DetailSection(title: "Network interfaces (\(interfaces.count))", spacing: 8) {
                if interfaces.isEmpty {
                    Text("No network interfaces.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(interfaces) { eni in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(eni.networkInterfaceId).font(.caption.monospaced().bold()).textSelection(.enabled)
                            DetailGrid(items: [
                                DetailItem("Private IP", eni.privateIp),
                                DetailItem("Public IP", eni.publicIp),
                                DetailItem("Subnet", eni.subnetId),
                                DetailItem("MAC address", eni.macAddress),
                                DetailItem("Status", eni.status, monospaced: false),
                                DetailItem("Description", eni.description, monospaced: false),
                            ], minColumnWidth: 160)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

private struct EC2StorageTab: View {
    let detail: Ec2InstanceDetail

    var body: some View {
        let devices = detail.blockDevices ?? []
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Root device details", spacing: 12) {
                DetailGrid(items: [
                    DetailItem("Root device name", detail.rootDeviceName),
                    DetailItem("Root device type", detail.rootDeviceType),
                    DetailItem("EBS optimization", detail.ebsOptimized.map { $0 ? "Enabled" : "Disabled" }, monospaced: false),
                ])
            }
            DetailSection(title: "Block devices (\(devices.count))", spacing: 8) {
                if devices.isEmpty {
                    Text("No EBS volumes attached.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            ForEach(["Device name", "Volume ID", "Attachment status", "Attach time", "Delete on termination"], id: \.self) {
                                Text($0).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Divider()
                        ForEach(devices) { device in
                            GridRow {
                                Text(device.deviceName).font(.caption.monospaced())
                                Text(device.volumeId ?? "-").font(.caption.monospaced()).textSelection(.enabled)
                                Text(device.status ?? "-").font(.caption)
                                Text(Formatters.formatISODate(device.attachTime)).font(.caption)
                                Text(device.deleteOnTermination ? "Yes" : "No").font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }
}
