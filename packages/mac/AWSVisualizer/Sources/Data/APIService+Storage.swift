import Foundation

/// EFS, FSx, EBS, S3 Glacier, Storage Gateway and AWS Backup
/// (routes in packages/api/src/presentation/routes/storage.ts).
extension APIService {
    private func sq(_ profile: String, _ region: String, _ extra: [String: String]) -> [String: String] {
        pq(profile, region).merging(extra) { _, new in new }
    }

    // MARK: EFS

    func getEfsFileSystems(profile: String, region: String) async throws -> [EfsFileSystemSummary] {
        try await get("/api/efs/file-systems", query: pq(profile, region))
    }

    func getEfsFileSystem(profile: String, region: String, id: String) async throws -> EfsFileSystemDetail {
        try await get("/api/efs/file-system", query: sq(profile, region, ["id": id]))
    }

    func getEfsFileSystemExtras(profile: String, region: String, id: String) async throws -> EfsFileSystemExtras {
        try await get("/api/efs/file-system/extras", query: sq(profile, region, ["id": id]))
    }

    func addEfsTag(profile: String, region: String, id: String, key: String, value: String) async throws -> EfsFileSystemDetail {
        try await post("/api/efs/tags", query: pq(profile, region), body: ["id": id, "key": key, "value": value])
    }

    func removeEfsTag(profile: String, region: String, id: String, key: String) async throws -> EfsFileSystemDetail {
        try await post("/api/efs/tags/remove", query: pq(profile, region), body: ["id": id, "key": key])
    }

    // MARK: FSx

    func getFsxFileSystems(profile: String, region: String) async throws -> [FsxFileSystemSummary] {
        try await get("/api/fsx/file-systems", query: pq(profile, region))
    }

    func getFsxFileSystem(profile: String, region: String, id: String) async throws -> FsxFileSystemDetail {
        try await get("/api/fsx/file-system", query: sq(profile, region, ["id": id]))
    }

    func getFsxFileSystemExtras(profile: String, region: String, id: String, type: String) async throws -> FsxFileSystemExtras {
        try await get("/api/fsx/file-system/extras", query: sq(profile, region, ["id": id, "type": type]))
    }

    func addFsxTag(profile: String, region: String, id: String, arn: String, key: String, value: String) async throws -> FsxFileSystemDetail {
        try await post("/api/fsx/tags", query: pq(profile, region), body: ["id": id, "arn": arn, "key": key, "value": value])
    }

    func removeFsxTag(profile: String, region: String, id: String, arn: String, key: String) async throws -> FsxFileSystemDetail {
        try await post("/api/fsx/tags/remove", query: pq(profile, region), body: ["id": id, "arn": arn, "key": key])
    }

    // MARK: EBS

    func getEbsVolumes(profile: String, region: String) async throws -> [EbsVolume] {
        try await get("/api/ebs/volumes", query: pq(profile, region))
    }

    func getEbsSnapshots(profile: String, region: String) async throws -> EbsSnapshotPage {
        try await get("/api/ebs/snapshots", query: pq(profile, region))
    }

    func getEbsVolume(profile: String, region: String, id: String) async throws -> EbsVolumeDetail {
        try await get("/api/ebs/volume", query: sq(profile, region, ["id": id]))
    }

    func createEbsSnapshot(profile: String, region: String, volumeId: String, description: String) async throws -> EbsSnapshot {
        try await post("/api/ebs/volume/snapshot", query: pq(profile, region), body: ["id": volumeId, "description": description])
    }

    /// Works for both volume and snapshot ids.
    func addEbsTag(profile: String, region: String, resourceId: String, key: String, value: String) async throws {
        try await postRaw("/api/ebs/tags", query: pq(profile, region), body: ["id": resourceId, "key": key, "value": value])
    }

    func removeEbsTag(profile: String, region: String, resourceId: String, key: String) async throws {
        try await postRaw("/api/ebs/tags/remove", query: pq(profile, region), body: ["id": resourceId, "key": key])
    }

    // MARK: S3 Glacier

    func getGlacierVaults(profile: String, region: String) async throws -> [GlacierVault] {
        try await get("/api/glacier/vaults", query: pq(profile, region))
    }

    func getGlacierVault(profile: String, region: String, name: String) async throws -> GlacierVaultDetail {
        try await get("/api/glacier/vault", query: sq(profile, region, ["name": name]))
    }

    func getGlacierJobs(profile: String, region: String, name: String) async throws -> [GlacierJob] {
        try await get("/api/glacier/vault/jobs", query: sq(profile, region, ["name": name]))
    }

    func requestGlacierInventory(profile: String, region: String, name: String) async throws -> GlacierJobStarted {
        try await post("/api/glacier/vault/inventory", query: pq(profile, region), body: ["name": name])
    }

    func getGlacierInventory(profile: String, region: String, name: String, jobId: String) async throws -> GlacierInventory {
        try await get("/api/glacier/vault/inventory", query: sq(profile, region, ["name": name, "jobId": jobId]))
    }

    func addGlacierTag(profile: String, region: String, name: String, key: String, value: String) async throws -> GlacierVaultDetail {
        try await post("/api/glacier/tags", query: pq(profile, region), body: ["name": name, "key": key, "value": value])
    }

    func removeGlacierTag(profile: String, region: String, name: String, key: String) async throws -> GlacierVaultDetail {
        try await post("/api/glacier/tags/remove", query: pq(profile, region), body: ["name": name, "key": key])
    }

    // MARK: Storage Gateway

    func getStorageGateways(profile: String, region: String) async throws -> [GatewaySummary] {
        try await get("/api/storagegateway/gateways", query: pq(profile, region))
    }

    func getStorageGateway(profile: String, region: String, arn: String) async throws -> GatewayDetail {
        try await get("/api/storagegateway/gateway", query: sq(profile, region, ["arn": arn]))
    }

    func getStorageGatewayStorage(profile: String, region: String, arn: String) async throws -> GatewayStorage {
        try await get("/api/storagegateway/gateway/storage", query: sq(profile, region, ["arn": arn]))
    }

    func addStorageGatewayTag(profile: String, region: String, arn: String, key: String, value: String) async throws -> GatewayDetail {
        try await post("/api/storagegateway/tags", query: pq(profile, region), body: ["arn": arn, "key": key, "value": value])
    }

    func removeStorageGatewayTag(profile: String, region: String, arn: String, key: String) async throws -> GatewayDetail {
        try await post("/api/storagegateway/tags/remove", query: pq(profile, region), body: ["arn": arn, "key": key])
    }

    // MARK: AWS Backup

    func getBackupOverview(profile: String, region: String) async throws -> BackupOverview {
        try await get("/api/backup/overview", query: pq(profile, region))
    }

    func getBackupPlan(profile: String, region: String, id: String) async throws -> BackupPlanDetail {
        try await get("/api/backup/plan", query: sq(profile, region, ["id": id]))
    }

    func getBackupVault(profile: String, region: String, name: String) async throws -> BackupVaultDetail {
        try await get("/api/backup/vault", query: sq(profile, region, ["name": name]))
    }

    /// `kind`: backup / restore / copy - jobs from the last 30 days.
    func getBackupJobs(profile: String, region: String, kind: String) async throws -> [BackupJobInfo] {
        try await get("/api/backup/jobs", query: sq(profile, region, ["kind": kind]))
    }

    func addBackupTag(profile: String, region: String, arn: String, key: String, value: String) async throws {
        try await postRaw("/api/backup/tags", query: pq(profile, region), body: ["arn": arn, "key": key, "value": value])
    }

    func removeBackupTag(profile: String, region: String, arn: String, key: String) async throws {
        try await postRaw("/api/backup/tags/remove", query: pq(profile, region), body: ["arn": arn, "key": key])
    }
}
