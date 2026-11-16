import Foundation

/// EKS, Fargate and App Runner (routes in packages/api/src/presentation/routes/containers.ts).
extension APIService {
    private func q(_ profile: String, _ region: String, _ extra: [String: String]) -> [String: String] {
        pq(profile, region).merging(extra) { _, new in new }
    }

    // MARK: EKS

    func getEksClusters(profile: String, region: String) async throws -> [EksClusterSummary] {
        try await get("/api/eks/clusters", query: pq(profile, region))
    }

    func getEksCluster(profile: String, region: String, name: String) async throws -> EksClusterDetail {
        try await get("/api/eks/cluster", query: q(profile, region, ["name": name]))
    }

    func getEksCompute(profile: String, region: String, name: String) async throws -> EksCompute {
        try await get("/api/eks/cluster/compute", query: q(profile, region, ["name": name]))
    }

    func getEksAddons(profile: String, region: String, name: String) async throws -> [EksAddon] {
        try await get("/api/eks/cluster/addons", query: q(profile, region, ["name": name]))
    }

    func getEksAccessEntries(profile: String, region: String, name: String) async throws -> [EksAccessEntry] {
        try await get("/api/eks/cluster/access", query: q(profile, region, ["name": name]))
    }

    func getEksUpdates(profile: String, region: String, name: String) async throws -> [EksUpdate] {
        try await get("/api/eks/cluster/updates", query: q(profile, region, ["name": name]))
    }

    func updateEksNodegroupScaling(profile: String, region: String, cluster: String, nodegroup: String, minSize: Int, maxSize: Int, desiredSize: Int) async throws -> EksCompute {
        try await put("/api/eks/nodegroup/scaling", query: pq(profile, region), body: [
            "cluster": cluster, "nodegroup": nodegroup, "minSize": minSize, "maxSize": maxSize, "desiredSize": desiredSize,
        ])
    }

    func addEksTag(profile: String, region: String, arn: String, key: String, value: String) async throws {
        try await postRaw("/api/eks/tags", query: pq(profile, region), body: ["arn": arn, "key": key, "value": value])
    }

    func removeEksTag(profile: String, region: String, arn: String, key: String) async throws {
        try await postRaw("/api/eks/tags/remove", query: pq(profile, region), body: ["arn": arn, "key": key])
    }

    // MARK: Fargate

    func getFargateOverview(profile: String, region: String) async throws -> FargateOverview {
        try await get("/api/fargate/overview", query: pq(profile, region))
    }

    // MARK: App Runner

    func getAppRunnerServices(profile: String, region: String) async throws -> [AppRunnerServiceSummary] {
        try await get("/api/apprunner/services", query: pq(profile, region))
    }

    func getAppRunnerService(profile: String, region: String, arn: String) async throws -> AppRunnerServiceDetail {
        try await get("/api/apprunner/service", query: q(profile, region, ["arn": arn]))
    }

    func getAppRunnerActivity(profile: String, region: String, arn: String) async throws -> AppRunnerActivity {
        try await get("/api/apprunner/service/activity", query: q(profile, region, ["arn": arn]))
    }

    /// `action`: pause / resume / deploy.
    func runAppRunnerAction(profile: String, region: String, arn: String, action: String) async throws -> AppRunnerServiceDetail {
        try await post("/api/apprunner/service/action", query: pq(profile, region), body: ["arn": arn, "action": action])
    }

    func addAppRunnerTag(profile: String, region: String, arn: String, key: String, value: String) async throws -> AppRunnerServiceDetail {
        try await post("/api/apprunner/service/tags", query: pq(profile, region), body: ["arn": arn, "key": key, "value": value])
    }

    func removeAppRunnerTag(profile: String, region: String, arn: String, key: String) async throws -> AppRunnerServiceDetail {
        try await post("/api/apprunner/service/tags/remove", query: pq(profile, region), body: ["arn": arn, "key": key])
    }
}
