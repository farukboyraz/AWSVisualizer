import SwiftUI

/// One row of the API Gateway list - the console shows REST, HTTP and
/// WebSocket APIs together with a "Protocol" column, even though REST
/// (v1) and HTTP/WebSocket (v2) are separate AWS APIs underneath.
enum ApiGatewayItem: Identifiable, Hashable {
    case rest(RestApi)
    case v2(HttpApi)

    var id: String {
        switch self {
        case .rest(let api): return "rest-\(api.id)"
        case .v2(let api): return "v2-\(api.apiId)"
        }
    }

    var name: String {
        switch self {
        case .rest(let api): return api.name
        case .v2(let api): return api.name
        }
    }

    /// "REST" / "HTTP" / "WebSocket".
    var protocolLabel: String {
        switch self {
        case .rest: return "REST"
        case .v2(let api): return api.protocolType == "WEBSOCKET" ? "WebSocket" : "HTTP"
        }
    }

    var caption: String? {
        switch self {
        case .rest(let api): return api.endpointType.map { "\($0) · \(api.id)" } ?? api.id
        case .v2(let api): return api.apiId
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ApiGatewayView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[ApiGatewayItem]> = .loading
    @State private var selectedId: String?
    /// Set when one of the two lists failed but the other loaded.
    @State private var partialError: String?

    private var selectedItem: ApiGatewayItem? {
        guard case .loaded(let items) = state else { return nil }
        return items.first { $0.id == selectedId }
    }

    var body: some View {
        AuthGuardedView {
            MasterDetailView(initialWidth: 300, minWidth: 220, maxWidth: 480, isDetailActive: selectedItem != nil, onBack: { selectedId = nil }, backTitle: "APIs", detailTitle: selectedItem?.name) {
                apiListPanel
            } detail: {
                switch selectedItem {
                case .rest(let restApi):
                    ApiGatewayDetailView(api: restApi) {
                        selectedId = nil
                        Task { await loadData() }
                    }
                    .id(restApi.id)
                case .v2(let httpApi):
                    HttpApiDetailView(apiId: httpApi.apiId) {
                        selectedId = nil
                        Task { await loadData() }
                    }
                    .id(httpApi.apiId)
                case nil:
                    EmptyStateView(message: "Select an API")
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
    }

    private var apiListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle("API Gateway")
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No APIs in this region") { unfilteredItems in
                let items = unfilteredItems.matching(filter)
                List(selection: $selectedId) {
                    ForEach(["REST", "HTTP", "WebSocket"], id: \.self) { label in
                        let group = items.filter { $0.protocolLabel == label }
                        if !group.isEmpty {
                            Section("\(label) APIs · \(group.count)") {
                                ForEach(group) { item in
                                    row(item).tag(item.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            if let partialError {
                Label(partialError, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            PanelActionBar {
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
            } trailing: {
                if case .loaded(let items) = state {
                    Text("\(items.count) APIs").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ item: ApiGatewayItem) -> some View {
        HStack(spacing: 8) {
            ApiProtocolBadge(label: item.protocolLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let caption = item.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// REST (v1) and HTTP/WebSocket (v2) are fetched in parallel; if only
    /// one fails (e.g. the role lacks apigateway:GET on /apis) the other
    /// still shows, with a warning line.
    private func loadData() async {
        state = .loading
        partialError = nil
        async let restResult = capture { try await api.getRestApis(profile: appState.currentProfile, region: appState.currentRegion) }
        async let v2Result = capture { try await api.getHttpApis(profile: appState.currentProfile, region: appState.currentRegion) }
        let (rest, v2) = await (restResult, v2Result)

        var items: [ApiGatewayItem] = []
        var errors: [String] = []
        switch rest {
        case .success(let apis): items += apis.sorted { $0.name < $1.name }.map(ApiGatewayItem.rest)
        case .failure(let error): errors.append("REST APIs: \(error.friendlyMessage)")
        }
        switch v2 {
        case .success(let apis): items += apis.map(ApiGatewayItem.v2)
        case .failure(let error): errors.append("HTTP/WebSocket APIs: \(error.friendlyMessage)")
        }

        if errors.count == 2 {
            state = .failed(errors.joined(separator: "\n"))
            return
        }
        partialError = errors.first
        state = items.isEmpty ? .empty : .loaded(items)
        if let selectedId, !items.contains(where: { $0.id == selectedId }) {
            self.selectedId = nil
        }
    }
}

/// Small colored "REST" / "HTTP" / "WebSocket" capsule.
struct ApiProtocolBadge: View {
    let label: String

    private var color: Color {
        switch label {
        case "HTTP": return .teal
        case "WebSocket": return .purple
        default: return .orange
        }
    }

    var body: some View {
        Text(label == "WebSocket" ? "WS" : label)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .frame(width: 38)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
            .help("\(label) API")
    }
}

private func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
