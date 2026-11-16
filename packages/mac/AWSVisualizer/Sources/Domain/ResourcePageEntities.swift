import Foundation

// Shared ResourcePage model (Database and Networking heading services -
// see PAGE_SERVICES in packages/api/src/infrastructure/aws/page-services.ts). Field names match
// packages/api/src/domain/entities/resource-page.ts.

struct PageSummary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let group: String?
    let status: String?
    let info: String?
}

struct PageSection: Codable, Hashable {
    let title: String
    let settings: [StorageSetting]
    let copyable: [StorageSetting]?
    let note: String?
}

struct PageTable: Codable, Hashable {
    let title: String?
    let columns: [String]
    let rows: [[String]]
    let statusColumn: Int?
    let emptyMessage: String?
}

struct PageTab: Codable, Hashable {
    let title: String
    let sections: [PageSection]
    let tables: [PageTable]
    let json: String?
    let text: String?
    /// CloudWatch graphs drawn above the sections (G2).
    let charts: [MetricChartSpec]?
    let emptyMessage: String?
}

/// An action button on a page, or a list-level "New ..." form (G1). With a
/// `form` the app asks for the fields in a sheet and sends them as `params`;
/// the fields use the dashboard card field model and rules.
struct PageAction: Codable, Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let confirmTitle: String
    let confirmMessage: String
    let destructive: Bool
    let form: [CardTemplate.Param]?

    var hasForm: Bool { !(form ?? []).isEmpty }
}

struct PageFormsResponse: Decodable { let forms: [PageAction] }
struct PageCreateResult: Decodable { let id: String? }

struct ResourcePage: Codable {
    let id: String
    let title: String
    let subtitle: String?
    let status: String?
    let arn: String?
    let tabs: [PageTab]
    let tags: [ResourceTag]?
    let actions: [PageAction]
    let errors: [String]
}
