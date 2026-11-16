import SwiftUI

/// Wavelength Zones and Local Zones are EC2 zones that have to be opted in
/// per zone group (EC2 console › Settings › Zones). One screen serves
/// both: zone groups on the left (opted in first), group page on the right.
struct EdgeZonesView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    let kind: EdgeZoneKind

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[EdgeZone]> = .loading
    @State private var selectedGroup: String?
    @State private var showAll = false

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 320, minWidth: 240, maxWidth: 500, isDetailActive: selectedGroup != nil, onBack: { selectedGroup = nil }, backTitle: "Zone groups", detailTitle: selectedGroup) {
                listPanel
            } detail: {
                if let selectedGroup {
                    EdgeZoneGroupDetailView(kind: kind, groupName: selectedGroup, onChanged: { Task { await loadData() } })
                        .id(selectedGroup)
                } else {
                    EmptyStateView(message: "Select a zone group")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)-\(kind.rawValue)") {
                await loadData()
            }
        }
    }

    private struct ZoneGroup: Identifiable {
        var id: String { name }
        let name: String
        let zones: [EdgeZone]
        var optedIn: Bool { zones.contains { $0.isOptedIn } }
    }

    private func groups(_ zones: [EdgeZone]) -> [ZoneGroup] {
        Dictionary(grouping: zones, by: \.groupName)
            .map { ZoneGroup(name: $0.key, zones: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(kind.title)
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No \(kind.title) in \(appState.currentRegion)") { unfilteredZones in
                let zones = unfilteredZones.matching(filter)
                let all = groups(zones)
                let optedIn = all.filter(\.optedIn)
                let others = all.filter { !$0.optedIn }
                List(selection: $selectedGroup) {
                    Section("Opted in · \(optedIn.count)") {
                        if optedIn.isEmpty {
                            Text("None yet - pick a group below to opt in.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(optedIn) { row($0).tag($0.name) }
                    }
                    Section {
                        if showAll {
                            ForEach(others) { row($0).tag($0.name) }
                        }
                    } header: {
                        HStack {
                            Text("Available · \(others.count)")
                            Spacer()
                            Button(showAll ? "Hide" : "Show") { showAll.toggle() }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            PanelActionBar {
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
            }
        }
    }

    private func row(_ group: ZoneGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.name).font(.body.bold().monospaced()).lineLimit(1)
            Text(group.zones.map(\.zoneName).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private func loadData() async {
        if case .loaded = state {} else { state = .loading }
        do {
            let zones = try await api.getEdgeZones(profile: appState.currentProfile, region: appState.currentRegion, kind: kind)
            state = zones.isEmpty ? .empty : .loaded(zones)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

struct EdgeZoneGroupDetailView: View {
    let kind: EdgeZoneKind
    let groupName: String
    let onChanged: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case zones = "Zones"
        case subnets = "Subnets"
        case carrierGateways = "Carrier gateways"
    }

    @State private var tab: DetailTab = .zones
    @State private var state: LoadState<EdgeZoneGroupDetail> = .loading
    @State private var isSaving = false
    @State private var actionError: String?

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { detail in
            let optedIn = detail.zones.contains { $0.isOptedIn }
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(
                    title: groupName,
                    subtitle: "\(kind.singular) group · parent \(detail.zones.first?.parentZoneName ?? appState.currentRegion)",
                    status: optedIn ? "Opted in" : "Not opted in",
                    tab: $tab
                )
                DetailActionBar(
                    error: actionError,
                    note: optedIn ? nil : "Opting in is free; you pay for what you launch there. Subnets in the zone can then be created from the VPC console.",
                    onRefresh: { Task { await load() } }
                ) {
                    ConfirmedActionButton(
                        title: optedIn ? "Opt out" : "Opt in",
                        systemImage: optedIn ? "minus.circle" : "plus.circle",
                        confirmationTitle: "\(optedIn ? "Opt out of" : "Opt in to") \(groupName)?",
                        confirmationMessage: optedIn
                            ? "AWS only allows opting out when nothing runs in the zone group - delete its subnets and resources first. Some zones can only be opted out through AWS Support."
                            : "All zones in this group become available to this account in \(appState.currentRegion).",
                        isLoading: isSaving,
                        isDisabled: isSaving,
                        role: optedIn ? .destructive : nil
                    ) { Task { await setOptIn(!optedIn) } }
                }
                SwiftUI.Group {
                    switch tab {
                    case .zones:
                        Table(detail.zones) {
                            TableColumn("Zone name") { z in Text(z.zoneName).font(.caption.monospaced().bold()) }
                            TableColumn("Zone ID") { z in Text(z.zoneId ?? "-").font(.caption.monospaced()) }
                            TableColumn("Network border group") { z in Text(z.networkBorderGroup ?? "-").font(.caption.monospaced()) }
                            TableColumn("Parent zone") { z in Text(z.parentZoneName ?? "-").font(.caption.monospaced()) }
                            TableColumn("Opt-in") { z in StatusBadge(z.optInStatus ?? "-") }
                            TableColumn("State") { z in StatusBadge(z.state ?? "-") }
                        }
                    case .subnets:
                        if detail.subnets.isEmpty {
                            EmptyStateView(message: optedIn ? "No subnets in these zones yet" : "Opt in first to create subnets here")
                        } else {
                            Table(detail.subnets) {
                                TableColumn("Subnet") { s in
                                    VStack(alignment: .leading) {
                                        Text(s.subnetId).font(.caption.monospaced())
                                        if let name = s.name { Text(name).font(.caption2).foregroundStyle(.secondary) }
                                    }
                                }
                                TableColumn("VPC") { s in Text(s.vpcId ?? "-").font(.caption.monospaced()) }
                                TableColumn("CIDR") { s in Text(s.cidrBlock ?? "-").font(.caption.monospaced()) }
                                TableColumn("Zone") { s in Text(s.availabilityZone ?? "-").font(.caption.monospaced()) }
                                TableColumn("Free IPs") { s in Text(s.availableIpAddressCount.map(String.init) ?? "-").font(.caption.monospaced()) }
                            }
                        }
                    case .carrierGateways:
                        if kind != .wavelength {
                            EmptyStateView(message: "Carrier gateways are only used with Wavelength Zones")
                        } else if detail.carrierGateways.isEmpty {
                            EmptyStateView(message: "No carrier gateways in this region")
                        } else {
                            Table(detail.carrierGateways) {
                                TableColumn("Carrier gateway") { g in Text(g.carrierGatewayId).font(.caption.monospaced()) }
                                TableColumn("Name") { g in Text(g.name ?? "-").font(.caption) }
                                TableColumn("VPC") { g in Text(g.vpcId ?? "-").font(.caption.monospaced()) }
                                TableColumn("State") { g in StatusBadge(g.state ?? "-") }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: groupName) { await load() }
    }

    private func setOptIn(_ optedIn: Bool) async {
        isSaving = true
        actionError = nil
        do {
            state = .loaded(try await api.setEdgeZoneGroupOptIn(profile: appState.currentProfile, region: appState.currentRegion, kind: kind, group: groupName, optedIn: optedIn))
            onChanged()
        } catch {
            actionError = error.friendlyMessage
        }
        isSaving = false
    }

    private func load() async {
        do {
            state = .loaded(try await api.getEdgeZoneGroup(profile: appState.currentProfile, region: appState.currentRegion, kind: kind, group: groupName))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
