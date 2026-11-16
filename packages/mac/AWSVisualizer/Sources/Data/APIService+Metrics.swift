import Foundation

/// CloudWatch graphs (G2): POST /api/cloudwatch/metric-data
/// (packages/api/src/infrastructure/aws/cloudwatch-metrics.ts).
extension APIService {
    /// Every series of a chart grid in one request (at most 20; ids unique).
    func getMetricData(profile: String, region: String, range: MetricRange, queries: [MetricQuery]) async throws -> MetricDataResult {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queries))
        return try await post("/api/cloudwatch/metric-data", query: pq(profile, region), body: ["range": range.rawValue, "queries": encoded], timeout: 45)
    }
}
