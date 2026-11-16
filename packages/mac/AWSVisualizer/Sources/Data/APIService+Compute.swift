import Foundation

/// Calls for the Compute services beyond EC2 / Lambda / Elastic Beanstalk
/// (routes in packages/api/src/presentation/routes/compute.ts).
extension APIService {
    private func pq(_ profile: String, _ region: String, _ extra: [String: String]) -> [String: String] {
        pq(profile, region).merging(extra) { _, new in new }
    }

    // MARK: EC2 Auto Scaling

    func getAutoScalingGroups(profile: String, region: String) async throws -> [AsgSummary] {
        try await get("/api/autoscaling/groups", query: pq(profile, region))
    }

    func getAutoScalingGroup(profile: String, region: String, name: String) async throws -> AsgDetail {
        try await get("/api/autoscaling/group", query: pq(profile, region, ["name": name]))
    }

    func getAutoScalingGroupScaling(profile: String, region: String, name: String) async throws -> AsgScaling {
        try await get("/api/autoscaling/group/scaling", query: pq(profile, region, ["name": name]))
    }

    func getAutoScalingGroupActivity(profile: String, region: String, name: String) async throws -> AsgActivityPage {
        try await get("/api/autoscaling/group/activity", query: pq(profile, region, ["name": name]))
    }

    func updateAutoScalingCapacity(profile: String, region: String, name: String, minSize: Int, maxSize: Int, desiredCapacity: Int) async throws -> AsgDetail {
        try await put("/api/autoscaling/group/capacity", query: pq(profile, region), body: [
            "name": name, "minSize": minSize, "maxSize": maxSize, "desiredCapacity": desiredCapacity,
        ])
    }

    func setAutoScalingInstanceProtection(profile: String, region: String, name: String, instanceIds: [String], protected: Bool) async throws -> AsgDetail {
        try await put("/api/autoscaling/group/protection", query: pq(profile, region), body: [
            "name": name, "instanceIds": instanceIds, "protectedFromScaleIn": protected,
        ])
    }

    func addAutoScalingTag(profile: String, region: String, name: String, key: String, value: String) async throws -> AsgDetail {
        try await post("/api/autoscaling/group/tags", query: pq(profile, region), body: ["name": name, "key": key, "value": value])
    }

    func removeAutoScalingTag(profile: String, region: String, name: String, key: String) async throws -> AsgDetail {
        try await post("/api/autoscaling/group/tags/remove", query: pq(profile, region), body: ["name": name, "key": key])
    }

    // MARK: Batch

    func getBatchOverview(profile: String, region: String) async throws -> BatchOverview {
        try await get("/api/batch/overview", query: pq(profile, region))
    }

    func getBatchJobQueue(profile: String, region: String, name: String) async throws -> BatchJobQueue {
        try await get("/api/batch/job-queue", query: pq(profile, region, ["name": name]))
    }

    func getBatchComputeEnvironment(profile: String, region: String, name: String) async throws -> BatchComputeEnvironment {
        try await get("/api/batch/compute-environment", query: pq(profile, region, ["name": name]))
    }

    func getBatchJobDefinition(profile: String, region: String, arn: String) async throws -> BatchJobDefinition {
        try await get("/api/batch/job-definition", query: pq(profile, region, ["arn": arn]))
    }

    func getBatchJobs(profile: String, region: String, queue: String, status: String) async throws -> [BatchJobSummary] {
        try await get("/api/batch/jobs", query: pq(profile, region, ["queue": queue, "status": status]))
    }

    func getBatchJob(profile: String, region: String, jobId: String) async throws -> BatchJobDetail {
        try await get("/api/batch/job", query: pq(profile, region, ["jobId": jobId]))
    }

    func setBatchJobQueueEnabled(profile: String, region: String, name: String, enabled: Bool) async throws -> BatchJobQueue {
        try await put("/api/batch/job-queue/state", query: pq(profile, region), body: ["name": name, "enabled": enabled])
    }

    func setBatchComputeEnvironmentEnabled(profile: String, region: String, name: String, enabled: Bool) async throws -> BatchComputeEnvironment {
        try await put("/api/batch/compute-environment/state", query: pq(profile, region), body: ["name": name, "enabled": enabled])
    }

    func terminateBatchJob(profile: String, region: String, jobId: String, reason: String) async throws -> BatchJobDetail {
        try await post("/api/batch/job/terminate", query: pq(profile, region), body: ["jobId": jobId, "reason": reason])
    }

    func addBatchTag(profile: String, region: String, arn: String, key: String, value: String) async throws {
        try await postRaw("/api/batch/tags", query: pq(profile, region), body: ["arn": arn, "key": key, "value": value])
    }

    func removeBatchTag(profile: String, region: String, arn: String, key: String) async throws {
        try await postRaw("/api/batch/tags/remove", query: pq(profile, region), body: ["arn": arn, "key": key])
    }

    // MARK: Lightsail

    func getLightsailInstances(profile: String, region: String) async throws -> [LightsailInstance] {
        try await get("/api/lightsail/instances", query: pq(profile, region))
    }

    func getLightsailInstance(profile: String, region: String, name: String) async throws -> LightsailInstanceDetail {
        try await get("/api/lightsail/instance", query: pq(profile, region, ["name": name]))
    }

    func getLightsailDatabases(profile: String, region: String) async throws -> [LightsailDatabase] {
        try await get("/api/lightsail/databases", query: pq(profile, region))
    }

    func getLightsailContainerServices(profile: String, region: String) async throws -> [LightsailContainerService] {
        try await get("/api/lightsail/container-services", query: pq(profile, region))
    }

    /// `action`: start / stop / reboot.
    func runLightsailInstanceAction(profile: String, region: String, name: String, action: String) async throws -> LightsailInstanceDetail {
        try await post("/api/lightsail/instance/action", query: pq(profile, region), body: ["name": name, "action": action])
    }

    func addLightsailTag(profile: String, region: String, resourceName: String, key: String, value: String) async throws {
        try await postRaw("/api/lightsail/tags", query: pq(profile, region), body: ["resourceName": resourceName, "key": key, "value": value])
    }

    func removeLightsailTag(profile: String, region: String, resourceName: String, key: String) async throws {
        try await postRaw("/api/lightsail/tags/remove", query: pq(profile, region), body: ["resourceName": resourceName, "key": key])
    }

    // MARK: Serverless Application Repository

    func getSarApplications(profile: String, region: String) async throws -> [SarApplication] {
        try await get("/api/serverlessrepo/applications", query: pq(profile, region))
    }

    func getSarApplication(profile: String, region: String, applicationId: String) async throws -> SarApplicationDetail {
        try await get("/api/serverlessrepo/application", query: pq(profile, region, ["id": applicationId]))
    }

    // MARK: Outposts

    func getOutposts(profile: String, region: String) async throws -> [Outpost] {
        try await get("/api/outposts", query: pq(profile, region))
    }

    func getOutpost(profile: String, region: String, outpostId: String) async throws -> OutpostDetail {
        try await get("/api/outposts/outpost", query: pq(profile, region, ["id": outpostId]))
    }

    // MARK: Wavelength / Local Zones

    func getEdgeZones(profile: String, region: String, kind: EdgeZoneKind) async throws -> [EdgeZone] {
        try await get("/api/edge-zones", query: pq(profile, region, ["type": kind.rawValue]))
    }

    func getEdgeZoneGroup(profile: String, region: String, kind: EdgeZoneKind, group: String) async throws -> EdgeZoneGroupDetail {
        try await get("/api/edge-zones/group", query: pq(profile, region, ["type": kind.rawValue, "group": group]))
    }

    func setEdgeZoneGroupOptIn(profile: String, region: String, kind: EdgeZoneKind, group: String, optedIn: Bool) async throws -> EdgeZoneGroupDetail {
        try await put("/api/edge-zones/group/opt-in", query: pq(profile, region), body: ["type": kind.rawValue, "group": group, "optedIn": optedIn])
    }

    // MARK: Nitro Enclaves

    func getEnclaveInstances(profile: String, region: String) async throws -> [Ec2Instance] {
        try await get("/api/nitro-enclaves/instances", query: pq(profile, region))
    }
}

/// Elastic Beanstalk environment drill-down (routes in environments.ts).
extension APIService {
    private func envQuery(_ profile: String, _ region: String, _ environmentName: String) -> [String: String] {
        var q = pq(profile, region)
        q["environmentName"] = environmentName
        return q
    }

    func getEbEnvironmentHealth(profile: String, region: String, environmentName: String) async throws -> EbEnvironmentHealth {
        try await get("/api/eb/environment/health", query: envQuery(profile, region, environmentName))
    }

    func getEbEnvironmentResources(profile: String, region: String, environmentName: String) async throws -> EbEnvironmentResources {
        try await get("/api/eb/environment/resources", query: envQuery(profile, region, environmentName))
    }

    func getEbEnvironmentConfiguration(profile: String, region: String, environmentName: String) async throws -> EbConfiguration {
        try await get("/api/eb/environment/configuration", query: envQuery(profile, region, environmentName))
    }

    func getEbApplicationVersions(profile: String, region: String, applicationName: String) async throws -> [EbApplicationVersion] {
        var q = pq(profile, region)
        q["applicationName"] = applicationName
        return try await get("/api/eb/application/versions", query: q)
    }

    func deployEbApplicationVersion(profile: String, region: String, environmentName: String, versionLabel: String) async throws -> EbEnvironmentDetail {
        try await post("/api/eb/environment/deploy", query: pq(profile, region), body: ["environmentName": environmentName, "versionLabel": versionLabel])
    }

    /// Waits for the instances to upload (up to ~70 s server-side).
    func fetchEbEnvironmentLogs(profile: String, region: String, environmentName: String, infoType: String) async throws -> [EbLogEntry] {
        try await post("/api/eb/environment/logs", query: pq(profile, region), body: ["environmentName": environmentName, "infoType": infoType], timeout: 120)
    }

    func getEbManagedUpdates(profile: String, region: String, environmentName: String) async throws -> EbManagedUpdates {
        try await get("/api/eb/environment/managed-updates", query: envQuery(profile, region, environmentName))
    }

    func applyEbManagedAction(profile: String, region: String, environmentName: String, actionId: String) async throws -> EbManagedUpdates {
        try await post("/api/eb/environment/managed-updates/apply", query: pq(profile, region), body: ["environmentName": environmentName, "actionId": actionId])
    }
}
