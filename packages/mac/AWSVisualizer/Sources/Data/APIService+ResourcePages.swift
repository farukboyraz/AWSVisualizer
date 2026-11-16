import Foundation

/// The shared ResourcePage routes (packages/api/src/presentation/routes/resource-pages.ts).
/// `service` is the catalog id (`elasticache`, `rds-proxy`, ...).
extension APIService {
    private func pagePath(_ service: String, _ suffix: String) -> String {
        "/api/pages/\(service.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? service)/\(suffix)"
    }

    func getPageList(service: String, profile: String, region: String) async throws -> [PageSummary] {
        try await get(pagePath(service, "list"), query: pq(profile, region))
    }

    func getResourcePage(service: String, profile: String, region: String, id: String) async throws -> ResourcePage {
        var q = pq(profile, region)
        q["id"] = id
        return try await get(pagePath(service, "detail"), query: q)
    }

    func runPageAction(service: String, profile: String, region: String, id: String, action: String, params: [String: String] = [:]) async throws -> ResourcePage {
        try await post(pagePath(service, "action"), query: pq(profile, region), body: ["id": id, "action": action, "params": params], timeout: 60)
    }

    /// The service's list-level "New ..." forms (empty when it has none).
    func getPageForms(service: String) async throws -> [PageAction] {
        let res: PageFormsResponse = try await get(pagePath(service, "forms"), query: [:])
        return res.forms
    }

    /// Runs a create form; returns the new row's id when the service knows it.
    func createPageResource(service: String, profile: String, region: String, form: String, params: [String: String]) async throws -> String? {
        let res: PageCreateResult = try await post(pagePath(service, "create"), query: pq(profile, region), body: ["form": form, "params": params], timeout: 60)
        return res.id
    }

    /// Choices for a page form's combo field (`p.<key>` carries the fields it depends on).
    func getPageOptions(service: String, source: String, profile: String, region: String, params: [String: String]) async throws -> [CardOption] {
        var q = pq(profile, region)
        q["source"] = source
        for (k, v) in params where !v.isEmpty { q["p.\(k)"] = v }
        let res: CardOptionsResponse = try await get(pagePath(service, "options"), query: q)
        return res.items
    }

    func addPageTag(service: String, profile: String, region: String, id: String, arn: String, key: String, value: String) async throws -> ResourcePage {
        try await post(pagePath(service, "tags"), query: pq(profile, region), body: ["id": id, "arn": arn, "key": key, "value": value])
    }

    func removePageTag(service: String, profile: String, region: String, id: String, arn: String, key: String) async throws -> ResourcePage {
        try await post(pagePath(service, "tags/remove"), query: pq(profile, region), body: ["id": id, "arn": arn, "key": key])
    }
}
