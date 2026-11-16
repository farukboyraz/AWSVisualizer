import SwiftUI

/// Mirrors a load balancer's console page: Details (with the deletion
/// protection attribute and the full attribute list), Listeners and rules,
/// Target groups with per-target health, and Tags.
struct LoadBalancerDetailView: View {
    let arn: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case listeners = "Listeners and rules"
        case targets = "Target groups"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .details
    @State private var detailState: LoadState<LoadBalancerDetail> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeader(
                        title: detail.loadBalancerName,
                        subtitle: [detail.type, detail.scheme, detail.ipAddressType].compactMap { $0 }.joined(separator: " · "),
                        status: detail.state,
                        tab: $tab
                    )
                    Group {
                        switch tab {
                        case .details:
                            ElbDetailsTab(detail: detail, onUpdated: { detailState = .loaded($0) })
                        case .listeners:
                            ElbListenersTab(arn: arn)
                        case .targets:
                            ElbTargetGroupsTab(arn: arn)
                        case .tags:
                            ResourceTagsEditor(tags: detail.tags, resourceNoun: "load balancer", onAdd: { key, value in
                                detailState = .loaded(try await api.addLoadBalancerTag(profile: appState.currentProfile, region: appState.currentRegion, arn: arn, key: key, value: value))
                            }, onRemove: { key in
                                detailState = .loaded(try await api.removeLoadBalancerTag(profile: appState.currentProfile, region: appState.currentRegion, arn: arn, key: key))
                            })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: arn) {
            await loadDetail()
        }
    }

    private func loadDetail() async {
        do {
            detailState = .loaded(try await api.getLoadBalancerDetail(profile: appState.currentProfile, region: appState.currentRegion, arn: arn))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

private struct ElbDetailsTab: View {
    let detail: LoadBalancerDetail
    var onUpdated: (LoadBalancerDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var isToggling = false
    @State private var error: String?

    var body: some View {
        DetailTabPage {
            DetailSection(title: "DNS name") {
                if let dns = detail.dnsName { CopyableBlock(text: dns) }
                if let zone = detail.canonicalHostedZoneId {
                    DetailField("Hosted zone (for Route53 alias records)", zone)
                }
            }

            DetailSection(title: "Details") {
                DetailField("ARN", detail.loadBalancerArn)
                HStack(spacing: 24) {
                    DetailField("VPC", detail.vpcId ?? "-")
                    DetailField("Created", Formatters.formatISODate(detail.createdTime), monospaced: false)
                }
                DetailField("Availability zones", detail.availabilityZones.joined(separator: "\n"))
                if !detail.securityGroups.isEmpty {
                    DetailField("Security groups", detail.securityGroups.joined(separator: "\n"))
                }
                if let reason = detail.stateReason {
                    DetailField("State reason", reason)
                }
            }

            DetailSection(title: "Deletion protection", spacing: 10) {
                LabeledSwitchBox(title: "Prevent this load balancer from being deleted", isOn: Binding(
                    get: { detail.deletionProtection },
                    set: { newValue in Task { await setDeletionProtection(newValue) } }
                ), onColor: .green)
                .disabled(isToggling)
                .frame(maxWidth: 460)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            DetailSection(title: "Attributes") {
                Text("Read-only - every attribute the load balancer reports.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(detail.attributes) { attribute in
                        GridRow {
                            Text(attribute.key).font(.caption.monospaced())
                            Text(attribute.value.isEmpty ? "-" : attribute.value)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func setDeletionProtection(_ enabled: Bool) async {
        isToggling = true
        error = nil
        do {
            onUpdated(try await api.setLoadBalancerDeletionProtection(profile: appState.currentProfile, region: appState.currentRegion, arn: detail.loadBalancerArn, enabled: enabled))
        } catch {
            self.error = error.friendlyMessage
        }
        isToggling = false
    }
}

private struct ElbListenersTab: View {
    let arn: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[ElbListener]> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No listeners") { listeners in
            DetailTabPage(maxWidth: 900) {
                ForEach(listeners) { listener in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("\(listener.protocol ?? "?"):\(listener.port.map(String.init) ?? "?")")
                                .font(.headline.monospaced())
                            if let policy = listener.sslPolicy {
                                Text(policy).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(listener.rules.count) rule\(listener.rules.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(listener.certificates, id: \.self) { cert in
                            Label(cert, systemImage: "lock.shield")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if listener.rules.isEmpty {
                            ForEach(listener.defaultActions, id: \.self) { action in
                                Label(action, systemImage: "arrow.right")
                                    .font(.caption)
                            }
                        } else {
                            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                                GridRow {
                                    Text("Priority").font(.caption2).foregroundStyle(.tertiary)
                                    Text("Conditions").font(.caption2).foregroundStyle(.tertiary)
                                    Text("Actions").font(.caption2).foregroundStyle(.tertiary)
                                }
                                ForEach(listener.rules) { rule in
                                    GridRow {
                                        Text(rule.isDefault ? "Default" : rule.priority)
                                            .font(.caption.monospacedDigit().bold())
                                        Text(rule.conditions.isEmpty ? "If no other rule applies" : rule.conditions.joined(separator: "\nand "))
                                            .font(.caption)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(rule.actions.joined(separator: "\nthen "))
                                            .font(.caption)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Divider().gridCellColumns(3)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .task(id: arn) { await load() }
    }

    private func load() async {
        state = .loading
        do {
            let listeners = try await api.getLoadBalancerListeners(profile: appState.currentProfile, region: appState.currentRegion, arn: arn)
            state = listeners.isEmpty ? .empty : .loaded(listeners)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct ElbTargetGroupsTab: View {
    let arn: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[ElbTargetGroup]> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No target groups attached") { groups in
            DetailTabPage(maxWidth: 900) {
                HStack {
                    Text("Target health is a live snapshot - refresh to re-check.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    RefreshButton(compactSize: 22, help: "Refresh") { Task { await load() } }
                }
                ForEach(groups) { group in
                    targetGroupCard(group)
                }
            }
        }
        .task(id: arn) { await load() }
    }

    private func targetGroupCard(_ group: ElbTargetGroup) -> some View {
        let healthy = group.targets.filter { $0.state == "healthy" }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.targetGroupName).font(.headline)
                Text("\(group.protocol ?? "?"):\(group.port.map(String.init) ?? "?") · \(group.targetType ?? "-")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(healthy)/\(group.targets.count) healthy")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(group.targets.isEmpty ? .secondary : (healthy == group.targets.count ? Color.green : Color.orange))
            }
            Text("Health check: \(group.healthCheckProtocol ?? "?") \(group.healthCheckPath ?? "") on port \(group.healthCheckPort ?? "?") · every \(group.healthCheckIntervalSeconds.map(String.init) ?? "?")s, timeout \(group.healthCheckTimeoutSeconds.map(String.init) ?? "?")s · healthy after \(group.healthyThresholdCount.map(String.init) ?? "?"), unhealthy after \(group.unhealthyThresholdCount.map(String.init) ?? "?")\(group.matcher.map { " · success codes \($0)" } ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if group.targets.isEmpty {
                Text("No registered targets.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.targets) { target in
                        HStack(spacing: 10) {
                            Text(target.targetId).font(.caption.monospaced()).textSelection(.enabled)
                            if let port = target.port { Text(":\(port)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                            if let az = target.availabilityZone { Text(az).font(.caption2).foregroundStyle(.tertiary) }
                            Spacer()
                            if let description = target.description {
                                Text(description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .help(description)
                            }
                            if let state = target.state { StatusBadge(state) }
                        }
                    }
                }
            }
            Text(group.targetGroupArn)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func load() async {
        state = .loading
        do {
            let groups = try await api.getLoadBalancerTargetGroups(profile: appState.currentProfile, region: appState.currentRegion, arn: arn)
            state = groups.isEmpty ? .empty : .loaded(groups)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
