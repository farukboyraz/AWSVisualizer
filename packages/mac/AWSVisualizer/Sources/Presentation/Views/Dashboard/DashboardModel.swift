import SwiftUI

/// Everything the dashboard shows, computed once from the service counts and
/// the cost summary. `DashboardContent` only renders this - no environment,
/// no API - so it can also be drawn with sample data (`placeholder`, snapshot).
struct DashboardModel {
    struct Service: Identifiable {
        let entry: AWSServiceCatalogEntry
        /// nil = the count failed (no permission, service not in the region…) - or isn't here yet.
        let count: Int?
        /// The count is still on its way.
        var isLoading = false
        var id: String { entry.id }
        var needsInstall: Bool { entry.needsPackageInstall }
    }

    struct Category: Identifiable {
        let name: String
        let color: Color
        let services: [Service]
        var id: String { name }
        var resources: Int { services.reduce(0) { $0 + ($1.count ?? 0) } }
    }

    struct Cost {
        let total: Double
        let currency: String
        let start: String?
        let end: String?
        let services: [(name: String, amount: Double)]
        /// Per day, or per month when `monthly`.
        let daily: [(date: Date, amount: Double)]
        var monthly = false
        var view: DashboardPrefs.CostView = .month
        /// Services of each point, largest first (tooltip "Details").
        var breakdown: [Date: [(name: String, amount: Double)]] = [:]

        func services(on date: Date) -> [(name: String, amount: Double)] { breakdown[date] ?? [] }

        /// One service's amount per point (spend-by-service "Details").
        func series(of service: String) -> [(date: Date, amount: Double)] {
            daily.map { point in (point.date, services(on: point.date).first { $0.name == service }?.amount ?? 0) }
        }

        /// Straight-line month-end estimate - only for the running month, by day.
        var monthEndEstimate: Double? {
            guard !monthly, daily.count >= 3, let first = daily.first?.date, let last = daily.last?.date else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            guard calendar.component(.day, from: first) == 1,
                  calendar.isDate(last, equalTo: Date(), toGranularity: .month) || calendar.isDate(last.addingTimeInterval(86_400), equalTo: Date(), toGranularity: .month),
                  let range = calendar.range(of: .day, in: .month, for: last),
                  daily.count < range.count else { return nil }
            return total / Double(daily.count) * Double(range.count)
        }

        /// Average per point (day or month).
        var dailyAverage: Double { daily.isEmpty ? 0 : total / Double(daily.count) }
    }

    enum CostState {
        /// Every cost widget is off - nothing was requested.
        case hidden
        case loading
        case loaded(Cost)
        /// Cost Explorer is denied for this role.
        case denied
        case failed(String)

        var cost: Cost? { if case .loaded(let c) = self { return c } else { return nil } }
    }

    let services: [Service]
    let costState: CostState
    let updatedAt: Date

    var cost: Cost? { costState.cost }

    var categories: [Category] {
        var order: [String] = []
        var grouped: [String: [Service]] = [:]
        for service in services {
            if grouped[service.entry.category] == nil { order.append(service.entry.category) }
            grouped[service.entry.category, default: []].append(service)
        }
        return order.map { name in
            Category(name: name, color: AWSServiceCatalogEntry.categoryTint(name), services: grouped[name] ?? [])
        }
    }

    var totalResources: Int { services.reduce(0) { $0 + ($1.count ?? 0) } }
    var activeServices: Int { services.filter { ($0.count ?? 0) > 0 }.count }
    /// Services whose count couldn't be read, or whose packages aren't installed.
    var attention: [Service] { services.filter { $0.count == nil || $0.needsInstall } }
    var topServices: [Service] {
        Array(services.filter { ($0.count ?? 0) > 0 }.sorted { ($0.count ?? 0) > ($1.count ?? 0) }.prefix(6))
    }
    var maxCount: Int { services.compactMap(\.count).max() ?? 0 }
}

extension DashboardModel {
    init(entries: [AWSServiceCatalogEntry], counts: [String: Int?], loading: Set<String> = [], costState: CostState, updatedAt: Date = Date()) {
        services = entries.map { Service(entry: $0, count: counts[$0.id] ?? nil, isLoading: loading.contains($0.id)) }
        self.costState = costState
        self.updatedAt = updatedAt
    }

    /// Same services and time, another cost state (the cost view switched).
    func with(costState: CostState) -> DashboardModel {
        DashboardModel(services: services, costState: costState, updatedAt: updatedAt)
    }
}

extension DashboardModel.Cost {
    init(_ summary: CostSummary) {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = TimeZone(identifier: "UTC")
        self.init(
            total: Double(summary.totalCost ?? "") ?? 0,
            currency: summary.currency ?? "USD",
            start: summary.period?.start,
            end: summary.period?.end,
            services: (summary.services ?? []).map { ($0.serviceName ?? "Unknown", Double($0.amount ?? "") ?? 0) },
            daily: (summary.daily ?? []).compactMap { day in parser.date(from: day.date).map { ($0, Double(day.amount) ?? 0) } },
            monthly: summary.granularity == "monthly",
            view: summary.view.flatMap(DashboardPrefs.CostView.init(rawValue:)) ?? .month,
            breakdown: Dictionary(uniqueKeysWithValues: (summary.breakdown ?? [:]).compactMap { key, services in
                parser.date(from: key).map { ($0, services.map { ($0.serviceName ?? "Unknown", Double($0.amount ?? "") ?? 0) }) }
            })
        )
    }
}

extension DashboardModel {

    /// Sample data: the shimmering layout while loading, and the snapshot.
    static func sample(entries: [AWSServiceCatalogEntry]) -> DashboardModel {
        var counts: [String: Int?] = [:]
        for (index, entry) in entries.enumerated() { counts[entry.id] = index % 7 == 5 ? nil : (index * 37 % 23) + (index % 3 == 0 ? 0 : 2) }
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let days = (1...18).reversed().map { offset -> CostDay in
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
            return CostDay(date: f.string(from: date), amount: String(format: "%.2f", 38 + sin(Double(offset) / 2.2) * 9 + Double(offset % 4) * 2))
        }
        let total = days.compactMap { Double($0.amount) }.reduce(0, +)
        let shares: [(String, Double)] = [("Amazon Elastic Compute Cloud - Compute", 0.34), ("Amazon Relational Database Service", 0.22), ("Amazon Simple Storage Service", 0.12), ("AWS Lambda", 0.08), ("Amazon CloudFront", 0.07), ("Amazon DynamoDB", 0.05), ("Amazon CloudWatch", 0.04)]
        let summary = CostSummary(
            totalCost: String(format: "%.2f", total),
            currency: "USD",
            period: CostPeriod(start: days.first?.date, end: days.last?.date),
            services: shares.map { CostByService(serviceName: $0.0, amount: String(format: "%.2f", total * $0.1)) },
            daily: days,
            breakdown: Dictionary(uniqueKeysWithValues: days.map { day in
                (day.date, shares.map { CostByService(serviceName: $0.0, amount: String(format: "%.2f", (Double(day.amount) ?? 0) * $0.1)) })
            })
        )
        return DashboardModel(entries: entries, counts: counts, costState: .loaded(Cost(summary)))
    }
}
