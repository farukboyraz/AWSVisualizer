import Foundation

/// Dashboard cards (packages/api/src/presentation/routes/dashboard.ts).
extension APIService {
    func getCardTemplates(service: String) async throws -> [CardTemplate] {
        let response: CardTemplatesResponse = try await get("/api/dashboard/card-templates", query: ["service": service])
        return response.templates
    }

    /// A dropdown's choices; every current param goes along as `p.<key>` (the source picks what it needs).
    func getCardOptions(service: String, source: String, profile: String, region: String, params: [String: String]) async throws -> [CardOption] {
        var query = ["service": service, "source": source, "profile": profile, "region": region]
        for (key, value) in params { query["p.\(key)"] = value }
        let response: CardOptionsResponse = try await get("/api/dashboard/card-options", query: query)
        return response.items
    }

    func getCardPreview(service: String, template: String, profile: String, region: String, params: [String: String]) async throws -> CardPreview {
        try await post("/api/dashboard/card-preview", body: ["service": service, "template": template, "profile": profile, "region": region, "params": params])
    }

    /// Runs a saved action card. `confirm` is always sent - the app only calls this after the user confirmed.
    /// `profile` / `region` are used by "all profiles" cards (the sidecar ignores them otherwise).
    func runCard(id: String, params: [String: String], profile: String, region: String) async throws -> DashboardCached<CardActionResult> {
        struct Entry: Decodable { let fetchedAt: String; let data: CardActionResult }
        let entry: Entry = try await post("/api/dashboard/cards/\(Self.pathID(id))/run", query: ["profile": profile, "region": region], body: ["confirm": true, "params": params])
        return DashboardCached(fetchedAt: Self.isoDate(entry.fetchedAt) ?? Date(), data: entry.data)
    }

    /// Where clicking a saved card goes (no AWS call).
    func getCardLink(id: String) async throws -> CardLinkTarget {
        try await post("/api/dashboard/cards/\(Self.pathID(id))/link")
    }

    static func pathID(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id }
}
