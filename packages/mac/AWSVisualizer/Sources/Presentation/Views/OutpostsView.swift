import SwiftUI

/// AWS Outposts - racks/servers installed on premises. Read-only: ordering
/// and site changes go through AWS.
struct OutpostsView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[Outpost]> = .loading
    @State private var selectedId: String?

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 300, minWidth: 220, maxWidth: 480, isDetailActive: selectedId != nil, onBack: { selectedId = nil }, backTitle: "Outposts", detailTitle: selectedId) {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle("Outposts")
                    ScreenFilterField(text: $filter)
                    LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No Outposts in this region") { unfilteredOutposts in
                        let outposts = unfilteredOutposts.matching(filter)
                        List(outposts, selection: $selectedId) { o in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(o.name).font(.body.bold()).lineLimit(1)
                                    Spacer()
                                    if let status = o.lifeCycleStatus { StatusBadge(status) }
                                }
                                Text([o.outpostId, o.supportedHardwareType, o.availabilityZone].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 2)
                            .tag(o.outpostId)
                        }
                        .listStyle(.sidebar)
                    }
                    PanelActionBar {
                        RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
                    }
                }
            } detail: {
                if let selectedId {
                    OutpostDetailView(outpostId: selectedId).id(selectedId)
                } else {
                    EmptyStateView(message: "Select an Outpost")
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
            let outposts = try await api.getOutposts(profile: appState.currentProfile, region: appState.currentRegion)
            state = outposts.isEmpty ? .empty : .loaded(outposts)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

struct OutpostDetailView: View {
    let outpostId: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case details = "Details"
        case instanceTypes = "Instance types"
        case assets = "Assets"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .details
    @State private var state: LoadState<OutpostDetail> = .loading

    var body: some View {
        LoadableContent(state, retry: { Task { await load() } }) { o in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(title: o.name, subtitle: o.outpostId, status: o.lifeCycleStatus, tab: $tab)
                Group {
                    switch tab {
                    case .details:
                        DetailTabPage {
                            if let description = o.description, !description.isEmpty {
                                Text(description).font(.body)
                            }
                            DetailGrid(items: [
                                DetailItem("Outpost ID", o.outpostId),
                                DetailItem("Life cycle status", o.lifeCycleStatus),
                                DetailItem("Hardware type", o.supportedHardwareType),
                                DetailItem("Availability Zone", o.availabilityZone),
                                DetailItem("Owner account", o.ownerId),
                                DetailItem("Site", o.siteName ?? o.siteId),
                            ])
                            if let siteDescription = o.siteDescription, !siteDescription.isEmpty {
                                DetailField("Site description", siteDescription, monospaced: false)
                            }
                            DetailSection(title: "ARN") { CopyableBlock(text: o.outpostArn) }
                        }
                    case .instanceTypes:
                        DetailTabPage {
                            DetailNote("EC2 instance types this Outpost's capacity supports.")
                            ValueChips(values: o.instanceTypes)
                        }
                    case .assets:
                        if let error = o.assetsError {
                            ErrorStateView(message: error)
                        } else if o.assets.isEmpty {
                            EmptyStateView(message: "No assets")
                        } else {
                            Table(o.assets) {
                                TableColumn("Asset ID") { a in Text(a.assetId).font(.caption.monospaced()) }
                                TableColumn("Type") { a in Text(a.assetType ?? "-").font(.caption) }
                                TableColumn("Rack") { a in Text(a.rackId ?? "-").font(.caption.monospaced()) }
                                TableColumn("Host") { a in Text(a.hostId ?? "-").font(.caption.monospaced()) }
                                TableColumn("State") { a in StatusBadge(a.state ?? "-") }
                            }
                        }
                    case .tags:
                        DetailTabPage {
                            if o.tags.isEmpty { Text("No tags.").font(.caption).foregroundStyle(.secondary) }
                            ForEach(o.tags) { tag in DetailField(tag.key, tag.value) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: outpostId) { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await api.getOutpost(profile: appState.currentProfile, region: appState.currentRegion, outpostId: outpostId))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}
