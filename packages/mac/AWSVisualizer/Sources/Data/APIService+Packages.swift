import Foundation

// MARK: - Entities

/// One service's npm install inside a job (`/api/packages/jobs/:id`).
struct PackageInstallStep: Codable, Equatable {
    let service: String
    let name: String
    let packages: [String]
    /// pending | running | installed | already | failed
    let status: String
    let command: String
    let output: String
    let error: String?
    let startedAt: String?
    let finishedAt: String?
}

struct PackageInstallJob: Codable, Equatable {
    let id: String
    /// running | finished
    let status: String
    let steps: [PackageInstallStep]
    let installedCount: Int
    let alreadyCount: Int
    let failedCount: Int

    var isRunning: Bool { status == "running" }
}

/// A failed install as recorded in ~/.awsvisualizer (`packages.failures`).
struct PackageFailureRecord: Codable, Equatable {
    let service: String
    let packages: [String]
    let error: String
    let command: String
    let output: String
    let failedAt: String
}

struct PackageVersionState: Codable, Equatable {
    let name: String
    let required: String
    let installed: String?
}

struct ServicePackagesState: Codable, Equatable {
    let name: String
    let installed: Bool
    let packages: [PackageVersionState]
    let command: String
}

struct PackagesStatus: Codable {
    let sdkVersion: String
    let modulesDir: String
    let services: [String: ServicePackagesState]
    let failures: [String: PackageFailureRecord]
}

private struct DefaultServicesResponse: Codable {
    let defaults: [String]
}

private struct CurrentJobResponse: Codable {
    let job: PackageInstallJob?
}

private struct ConflictBody: Codable {
    let jobId: String
}

// MARK: - Calls

extension APIService {
    func getPackagesStatus() async throws -> PackagesStatus {
        try await get("/api/packages/status")
    }

    /// Starts a step-by-step install; if one is already running, returns that job instead.
    func installServicePackages(_ services: [String]) async throws -> PackageInstallJob {
        do {
            return try await post("/api/packages/install", body: ["services": services])
        } catch APIError.httpError(409, let body) {
            guard let data = body.data(using: .utf8), let conflict = try? JSONDecoder().decode(ConflictBody.self, from: data) else { throw APIError.httpError(409, body) }
            return try await getInstallJob(conflict.jobId)
        }
    }

    func getInstallJob(_ id: String) async throws -> PackageInstallJob {
        try await get("/api/packages/jobs/\(id)")
    }

    func getRunningInstallJob() async throws -> PackageInstallJob? {
        let response: CurrentJobResponse = try await get("/api/packages/jobs/current")
        return response.job
    }

    func getUserDefaultServices() async throws -> [String] {
        let response: DefaultServicesResponse = try await get("/api/services/defaults")
        return response.defaults
    }

    func setUserDefaultServices(_ services: [String]) async throws {
        let _: DefaultServicesResponse = try await post("/api/services/defaults", body: ["services": services])
    }
}

// MARK: - Node.js preference (Settings › Node.js & Packages)

struct RuntimePreference: Codable {
    let preferredNodeBin: String?
    let persisted: Bool
}

extension APIService {
    func getRuntimePreference() async throws -> RuntimePreference {
        try await get("/api/runtime/preference")
    }

    /// nil = automatic.
    func setRuntimePreference(_ bin: String?) async throws -> RuntimePreference {
        try await post("/api/runtime/preference", body: ["preferredNodeBin": bin ?? NSNull()])
    }
}
