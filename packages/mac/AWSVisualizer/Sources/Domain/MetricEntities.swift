import Foundation

// CloudWatch graphs (G2). Field names match
// packages/api/src/domain/entities/metrics.ts; the data comes from
// POST /api/cloudwatch/metric-data.

struct MetricDimension: Codable, Hashable {
    let name: String
    let value: String
}

/// One series: a metric with its dimensions and statistic.
struct MetricQuery: Codable, Hashable {
    /// Unique within a request; starts with a lowercase letter (CloudWatch's rule).
    var id: String
    let namespace: String
    let metricName: String
    let dimensions: [MetricDimension]
    /// Average, Sum, Minimum, Maximum, SampleCount or a percentile (p99).
    let stat: String
    var label: String?

    init(id: String, namespace: String, metricName: String, dimensions: [String: String], stat: String, label: String? = nil) {
        self.id = id
        self.namespace = namespace
        self.metricName = metricName
        self.dimensions = dimensions.sorted { $0.key < $1.key }.map { MetricDimension(name: $0.key, value: $0.value) }
        self.stat = stat
        self.label = label
    }

    /// Same metric with another request id (a grid prefixes ids per chart).
    func withId(_ id: String) -> MetricQuery {
        var copy = self
        copy.id = id
        return copy
    }
}

extension MetricChartSpec {
    /// One chart whose series share the dimensions (`(metric, stat, label)`).
    init(_ title: String, unit: String? = nil, namespace: String, dimensions: [String: String], _ metrics: [(String, String, String?)]) {
        self.init(
            title: title,
            unit: unit,
            queries: metrics.enumerated().map { i, m in
                MetricQuery(id: "m\(i)", namespace: namespace, metricName: m.0, dimensions: dimensions, stat: m.1, label: m.2 ?? m.0)
            }
        )
    }
}

/// One graph: a title, a unit and the series drawn in it.
struct MetricChartSpec: Codable, Hashable {
    let title: String
    /// "%", "Bytes", "ms", "Count"... drives value formatting.
    var unit: String?
    let queries: [MetricQuery]
}

/// The console's time ranges.
enum MetricRange: String, Codable, CaseIterable, Identifiable {
    case hour1 = "1h", hours3 = "3h", hours12 = "12h", day1 = "1d", days3 = "3d", week1 = "1w"

    var id: String { rawValue }
}

struct MetricPoint: Decodable, Hashable {
    let t: String
    let v: Double

    var date: Date { MetricPoint.parser.date(from: t) ?? MetricPoint.fallback.date(from: t) ?? .distantPast }

    private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let fallback = ISO8601DateFormatter()
}

struct MetricSeries: Decodable, Hashable {
    let id: String
    let label: String
    let points: [MetricPoint]
}

struct MetricDataResult: Decodable {
    let range: String
    let period: Int
    let series: [MetricSeries]
    let messages: [String]
}
