import Foundation

final class APIService: APIServiceProtocol {
    private let baseURL = SidecarAuth.baseURL
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        // Every request proves it comes from this app (see SidecarAuth).
        config.httpAdditionalHeaders = [SidecarAuth.header: SidecarAuth.token]
        self.session = URLSession(configuration: config)
    }

    // MARK: - Private Helpers

    private func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(string: "\(baseURL)\(path)")!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    private func url(_ path: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(string: "\(baseURL)\(path)")!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url!
    }

    /// Shared success/failure check for every request below - also the one
    /// place that reports a 401/403 to `SessionExpiryMonitor`, so every
    /// call site gets that for free instead of each having to remember it.
    private func validate(_ response: URLResponse, data: Data) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let error = APIError.httpError(httpResponse.statusCode, body)
            if error.isNotAuthorized {
                await SessionExpiryMonitor.shared.reportNotAuthorized()
            }
            throw error
        }
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let request = URLRequest(url: url(path, query: query))
        let (data, response) = try await session.data(for: request)
        try await validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem]) async throws -> T {
        let request = URLRequest(url: url(path, queryItems: queryItems))
        let (data, response) = try await session.data(for: request)
        try await validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// `timeout` for calls that wait on the user (browser sign-in).
    func post<T: Decodable>(_ path: String, query: [String: String] = [:], body: [String: Any] = [:], timeout: TimeInterval? = nil) async throws -> T {
        var request = URLRequest(url: url(path, query: query))
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !body.isEmpty {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try await validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func put<T: Decodable>(_ path: String, query: [String: String] = [:], body: [String: Any] = [:]) async throws -> T {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !body.isEmpty {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try await validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func postRaw(_ path: String, query: [String: String] = [:], body: [String: Any] = [:]) async throws {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !body.isEmpty {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try await validate(response, data: data)
    }

    func putRaw(_ path: String, query: [String: String] = [:], body: [String: Any] = [:]) async throws {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !body.isEmpty {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try await validate(response, data: data)
    }

    func pq(_ profile: String, _ region: String) -> [String: String] {
        ["profile": profile, "region": region]
    }

    // MARK: - Status & Auth

    func getStatus() async throws -> SSOStatus {
        try await get("/api/aws-status")
    }

    func login(ssoSession: String? = nil) async throws -> LoginResponse {
        try await post("/api/sso-login", body: ssoSession != nil ? ["ssoSession": ssoSession!] : [:], timeout: 300)
    }

    /// Logs in whichever sso-session the named profile uses.
    func login(profile: String) async throws -> LoginResponse {
        try await post("/api/sso-login", body: ["profile": profile], timeout: 300)
    }

    func logout() async throws {
        try await postRaw("/api/sso-logout")
    }

    func checkProfiles() async throws -> ProfileCheckResponse {
        try await get("/api/check-profiles")
    }

    func getCallerIdentity(profile: String, region: String) async throws -> CallerIdentity {
        try await get("/api/caller-identity", query: pq(profile, region))
    }

    func getAccessibleEnvironments() async throws -> [AccessibleEnvironment] {
        let list: AccessibleEnvironmentList = try await get("/api/accessible-environments")
        return list.environments
    }

    func createProfile(name: String, ssoSessionName: String, accountId: String, roleName: String, region: String) async throws {
        try await postRaw("/api/profiles", body: [
            "name": name,
            "ssoSessionName": ssoSessionName,
            "accountId": accountId,
            "roleName": roleName,
            "region": region,
        ])
    }

    // MARK: - Service Catalog

    func getServiceCatalog() async throws -> [AWSServiceCatalogEntry] {
        let response: ServiceCatalogResponse = try await get("/api/services/catalog")
        return response.services
    }

    func getSelectedServices() async throws -> [String] {
        let response: SelectedServicesResponse = try await get("/api/services/selected")
        return response.selected
    }

    func setSelectedServices(_ services: [String]) async throws {
        try await postRaw("/api/services/selected", body: ["services": services])
    }

    func getFavoriteServices() async throws -> [String] {
        let response: FavoriteServicesResponse = try await get("/api/services/favorites")
        return response.favorites
    }

    func setFavoriteServices(_ services: [String]) async throws {
        try await postRaw("/api/services/favorites", body: ["services": services])
    }

    /// `source: "dashboard"` lets the sidecar drop services the dashboard settings exclude.
    func getServiceCounts(profile: String, region: String, services: [String], source: String? = nil) async throws -> [String: Int?] {
        var q = pq(profile, region)
        q["services"] = services.joined(separator: ",")
        if let source { q["source"] = source }
        let response: ServiceCountsResponse = try await get("/api/services/counts", query: q)
        return response.counts
    }

    // MARK: - Cost

    /// `month` is `YYYY-MM` (view .month); `fresh` skips the sidecar's 30-minute cache.
    func getCost(profile: String, view: DashboardPrefs.CostView = .month, months: Int = 6, month: String? = nil, fresh: Bool = false) async throws -> AuthResponse<CostSummary> {
        var q = ["profile": profile, "view": view.rawValue, "months": "\(months)"]
        if let month { q["month"] = month }
        if fresh { q["fresh"] = "1" }
        return try await get("/api/cost", query: q)
    }

    /// Saved dashboard answers (never calls AWS). `decode` maps a key to its type.
    func getDashboardCache(keys: [String]) async throws -> [String: (fetchedAt: Date, data: Data)] {
        guard !keys.isEmpty else { return [:] }
        var request = URLRequest(url: url("/api/dashboard/cache", query: ["keys": keys.joined(separator: ",")]))
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try await validate(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [String: [String: Any]] else { return [:] }
        var result: [String: (fetchedAt: Date, data: Data)] = [:]
        for (key, entry) in entries {
            guard let stamp = entry["fetchedAt"] as? String, let date = Self.isoDate(stamp), let payload = entry["data"],
                  let bytes = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]) else { continue }
            result[key] = (date, bytes)
        }
        return result
    }

    /// Runs one saved metric card on AWS and saves the answer. `profile` / `region`: for "all profiles" cards.
    func getDashboardCardValue(id: String, profile: String, region: String) async throws -> DashboardCached<DashboardCardValue> {
        struct Entry: Decodable { let fetchedAt: String; let data: DashboardCardValue }
        let entry: Entry = try await post("/api/dashboard/cards/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/value", query: ["profile": profile, "region": region])
        return DashboardCached(fetchedAt: Self.isoDate(entry.fetchedAt) ?? Date(), data: entry.data)
    }

    static func isoDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    func updateDashboardPrefs(_ prefs: DashboardPrefs) async throws -> AppConfig {
        try await put("/api/config/dashboard", body: prefs.asJSON)
    }

    // MARK: - Elastic Beanstalk

    func getEnvironments(profile: String, region: String) async throws -> [EBEnvironment] {
        try await get("/api/environments", query: pq(profile, region))
    }

    func getEvents(profile: String, region: String, environment: String) async throws -> [EbEvent] {
        var q = pq(profile, region)
        q["environment"] = environment
        return try await get("/api/events", query: q)
    }

    func getEbEnvironmentDetail(profile: String, region: String, environmentName: String) async throws -> EbEnvironmentDetail {
        var q = pq(profile, region)
        q["environmentName"] = environmentName
        return try await get("/api/eb/environment", query: q)
    }

    func restartEbAppServer(profile: String, region: String, environmentName: String) async throws {
        try await postRaw("/api/eb/environment/restart", query: pq(profile, region), body: ["environmentName": environmentName])
    }

    func rebuildEbEnvironment(profile: String, region: String, environmentName: String) async throws {
        try await postRaw("/api/eb/environment/rebuild", query: pq(profile, region), body: ["environmentName": environmentName])
    }

    func terminateEbEnvironment(profile: String, region: String, environmentName: String) async throws {
        try await postRaw("/api/eb/environment/terminate", query: pq(profile, region), body: ["environmentName": environmentName])
    }

    func swapEbEnvironmentCnames(profile: String, region: String, sourceEnvironmentName: String, destinationEnvironmentName: String) async throws {
        try await postRaw("/api/eb/environment/swap-cname", query: pq(profile, region), body: ["sourceEnvironmentName": sourceEnvironmentName, "destinationEnvironmentName": destinationEnvironmentName])
    }

    func setEbEnvironmentVariable(profile: String, region: String, environmentName: String, key: String, value: String) async throws -> EbEnvironmentDetail {
        try await put("/api/eb/environment/variable", query: pq(profile, region), body: ["environmentName": environmentName, "key": key, "value": value])
    }

    func removeEbEnvironmentVariable(profile: String, region: String, environmentName: String, key: String) async throws -> EbEnvironmentDetail {
        try await post("/api/eb/environment/variable/remove", query: pq(profile, region), body: ["environmentName": environmentName, "key": key])
    }

    func addEbEnvironmentTag(profile: String, region: String, environmentName: String, environmentArn: String, key: String, value: String) async throws -> EbEnvironmentDetail {
        try await post("/api/eb/environment/tags", query: pq(profile, region), body: ["environmentName": environmentName, "environmentArn": environmentArn, "key": key, "value": value])
    }

    func removeEbEnvironmentTag(profile: String, region: String, environmentName: String, environmentArn: String, key: String) async throws -> EbEnvironmentDetail {
        try await post("/api/eb/environment/tags/remove", query: pq(profile, region), body: ["environmentName": environmentName, "environmentArn": environmentArn, "key": key])
    }

    func cloneEbEnvironment(profile: String, region: String, sourceEnvironmentName: String, newEnvironmentName: String, cnamePrefix: String?) async throws -> EbEnvironmentDetail {
        var body: [String: Any] = ["sourceEnvironmentName": sourceEnvironmentName, "newEnvironmentName": newEnvironmentName]
        if let cnamePrefix, !cnamePrefix.isEmpty { body["cnamePrefix"] = cnamePrefix }
        return try await post("/api/eb/environments/clone", query: pq(profile, region), body: body)
    }

    // MARK: - Lambda

    func getLambdaFunctions(profile: String, region: String) async throws -> AuthResponse<[LambdaFunction]> {
        try await get("/api/lambda/functions", query: pq(profile, region))
    }

    func getLambdaFunctionDetail(profile: String, region: String, functionName: String) async throws -> LambdaFunctionDetail {
        var q = pq(profile, region)
        q["functionName"] = functionName
        return try await get("/api/lambda/function", query: q)
    }

    func exportLambdaCodeToLocalDirectory(profile: String, region: String, functionName: String) async throws -> String {
        let response: LocalPathResponse = try await post("/api/lambda/function/code/export", query: pq(profile, region), body: ["functionName": functionName])
        return response.path
    }

    func getLambdaCodeEntries(profile: String, region: String, functionName: String) async throws -> [ZipEntry] {
        var q = pq(profile, region)
        q["functionName"] = functionName
        return try await get("/api/lambda/function/code/entries", query: q)
    }

    func getLambdaCodeEntryContent(profile: String, region: String, functionName: String, path: String) async throws -> ZipEntryContent {
        var q = pq(profile, region)
        q["functionName"] = functionName
        q["path"] = path
        return try await get("/api/lambda/function/code/entry", query: q)
    }

    func getLambdaMetrics(profile: String, region: String, functionName: String) async throws -> LambdaMetricsSummary {
        var q = pq(profile, region)
        q["functionName"] = functionName
        return try await get("/api/lambda/function/metrics", query: q)
    }

    func updateLambdaFunctionConfig(profile: String, region: String, functionName: String, memorySize: Int?, timeout: Int?, description: String?) async throws -> LambdaFunctionDetail {
        var body: [String: Any] = ["functionName": functionName]
        if let memorySize { body["memorySize"] = memorySize }
        if let timeout { body["timeout"] = timeout }
        if let description { body["description"] = description }
        return try await put("/api/lambda/function/config", query: pq(profile, region), body: body)
    }

    func updateLambdaEnvironmentVariables(profile: String, region: String, functionName: String, variables: [String: String]) async throws -> LambdaFunctionDetail {
        try await put("/api/lambda/function/environment", query: pq(profile, region), body: ["functionName": functionName, "variables": variables])
    }

    func invokeLambdaFunction(profile: String, region: String, functionName: String, payload: String) async throws -> LambdaInvokeResult {
        try await post("/api/lambda/function/invoke", query: pq(profile, region), body: ["functionName": functionName, "payload": payload])
    }

    func getLambdaVersions(profile: String, region: String, functionName: String) async throws -> [LambdaVersion] {
        var q = pq(profile, region)
        q["functionName"] = functionName
        return try await get("/api/lambda/function/versions", query: q)
    }

    func publishLambdaVersion(profile: String, region: String, functionName: String, description: String?) async throws -> LambdaVersion {
        var body: [String: Any] = ["functionName": functionName]
        if let description { body["description"] = description }
        return try await post("/api/lambda/function/versions", query: pq(profile, region), body: body)
    }

    func getLambdaAliases(profile: String, region: String, functionName: String) async throws -> [LambdaAlias] {
        var q = pq(profile, region)
        q["functionName"] = functionName
        return try await get("/api/lambda/function/aliases", query: q)
    }

    func createLambdaAlias(profile: String, region: String, functionName: String, name: String, functionVersion: String, description: String?) async throws -> [LambdaAlias] {
        var body: [String: Any] = ["functionName": functionName, "name": name, "functionVersion": functionVersion]
        if let description { body["description"] = description }
        return try await post("/api/lambda/function/aliases", query: pq(profile, region), body: body)
    }

    func updateLambdaAlias(profile: String, region: String, functionName: String, name: String, functionVersion: String, description: String?) async throws -> [LambdaAlias] {
        var body: [String: Any] = ["functionName": functionName, "name": name, "functionVersion": functionVersion]
        if let description { body["description"] = description }
        return try await put("/api/lambda/function/aliases", query: pq(profile, region), body: body)
    }

    func deleteLambdaAlias(profile: String, region: String, functionName: String, name: String) async throws -> [LambdaAlias] {
        try await post("/api/lambda/function/aliases/delete", query: pq(profile, region), body: ["functionName": functionName, "name": name])
    }

    func getLambdaTriggers(profile: String, region: String, functionName: String) async throws -> [LambdaEventSourceMapping] {
        var q = pq(profile, region)
        q["functionName"] = functionName
        return try await get("/api/lambda/function/triggers", query: q)
    }

    func createLambdaTrigger(profile: String, region: String, functionName: String, eventSourceArn: String, batchSize: Int?, startingPosition: String?) async throws -> [LambdaEventSourceMapping] {
        var body: [String: Any] = ["functionName": functionName, "eventSourceArn": eventSourceArn]
        if let batchSize { body["batchSize"] = batchSize }
        if let startingPosition { body["startingPosition"] = startingPosition }
        return try await post("/api/lambda/function/triggers", query: pq(profile, region), body: body)
    }

    func setLambdaTriggerEnabled(profile: String, region: String, functionName: String, uuid: String, enabled: Bool) async throws -> [LambdaEventSourceMapping] {
        try await put("/api/lambda/function/triggers", query: pq(profile, region), body: ["functionName": functionName, "uuid": uuid, "enabled": enabled])
    }

    func deleteLambdaTrigger(profile: String, region: String, functionName: String, uuid: String) async throws -> [LambdaEventSourceMapping] {
        try await post("/api/lambda/function/triggers/delete", query: pq(profile, region), body: ["functionName": functionName, "uuid": uuid])
    }

    func setLambdaConcurrency(profile: String, region: String, functionName: String, reservedConcurrentExecutions: Int) async throws -> LambdaFunctionDetail {
        try await put("/api/lambda/function/concurrency", query: pq(profile, region), body: ["functionName": functionName, "reservedConcurrentExecutions": reservedConcurrentExecutions])
    }

    func removeLambdaConcurrency(profile: String, region: String, functionName: String) async throws -> LambdaFunctionDetail {
        try await post("/api/lambda/function/concurrency/delete", query: pq(profile, region), body: ["functionName": functionName])
    }

    func addLambdaTag(profile: String, region: String, functionArn: String, functionName: String, key: String, value: String) async throws -> LambdaFunctionDetail {
        try await post("/api/lambda/function/tags", query: pq(profile, region), body: ["functionArn": functionArn, "functionName": functionName, "key": key, "value": value])
    }

    func removeLambdaTag(profile: String, region: String, functionArn: String, functionName: String, key: String) async throws -> LambdaFunctionDetail {
        try await post("/api/lambda/function/tags/remove", query: pq(profile, region), body: ["functionArn": functionArn, "functionName": functionName, "key": key])
    }

    func deleteLambdaFunction(profile: String, region: String, functionName: String) async throws {
        let _: OkResponse = try await post("/api/lambda/function/delete", query: pq(profile, region), body: ["functionName": functionName])
    }

    func createLambdaFunction(profile: String, region: String, functionName: String, runtime: String, handler: String, role: String, code: String, memorySize: Int?, timeout: Int?, description: String?) async throws -> LambdaFunctionDetail {
        var body: [String: Any] = ["functionName": functionName, "runtime": runtime, "handler": handler, "role": role, "code": code]
        if let memorySize { body["memorySize"] = memorySize }
        if let timeout { body["timeout"] = timeout }
        if let description { body["description"] = description }
        return try await post("/api/lambda/function/create", query: pq(profile, region), body: body)
    }

    // MARK: - EC2

    func getEC2Instances(profile: String, region: String) async throws -> AuthResponse<[Ec2Instance]> {
        try await get("/api/ec2/instances", query: pq(profile, region))
    }

    func getEc2InstanceDetail(profile: String, region: String, instanceId: String) async throws -> Ec2InstanceDetail {
        var q = pq(profile, region)
        q["instanceId"] = instanceId
        return try await get("/api/ec2/instance", query: q)
    }

    func setEc2InstanceState(profile: String, region: String, instanceId: String, action: String) async throws {
        try await postRaw("/api/ec2/instance/state", query: pq(profile, region), body: ["instanceId": instanceId, "action": action])
    }

    func setEc2InstanceType(profile: String, region: String, instanceId: String, instanceType: String) async throws -> Ec2InstanceDetail {
        try await put("/api/ec2/instance/type", query: pq(profile, region), body: ["instanceId": instanceId, "instanceType": instanceType])
    }

    func setEc2TerminationProtection(profile: String, region: String, instanceId: String, enabled: Bool) async throws -> Ec2InstanceDetail {
        try await put("/api/ec2/instance/termination-protection", query: pq(profile, region), body: ["instanceId": instanceId, "enabled": enabled])
    }

    func setEc2Monitoring(profile: String, region: String, instanceId: String, enabled: Bool) async throws -> Ec2InstanceDetail {
        try await put("/api/ec2/instance/monitoring", query: pq(profile, region), body: ["instanceId": instanceId, "enabled": enabled])
    }

    func addEc2Tag(profile: String, region: String, instanceId: String, key: String, value: String) async throws -> Ec2InstanceDetail {
        try await post("/api/ec2/instance/tags", query: pq(profile, region), body: ["instanceId": instanceId, "key": key, "value": value])
    }

    func removeEc2Tag(profile: String, region: String, instanceId: String, key: String) async throws -> Ec2InstanceDetail {
        try await post("/api/ec2/instance/tags/remove", query: pq(profile, region), body: ["instanceId": instanceId, "key": key])
    }

    func getEc2KeyPairs(profile: String, region: String) async throws -> [Ec2KeyPair] {
        try await get("/api/ec2/key-pairs", query: pq(profile, region))
    }

    func launchEc2Instance(profile: String, region: String, imageId: String, instanceType: String, keyName: String?, securityGroupIds: [String]?, subnetId: String?, name: String?) async throws -> Ec2InstanceDetail {
        var body: [String: Any] = ["imageId": imageId, "instanceType": instanceType]
        if let keyName, !keyName.isEmpty { body["keyName"] = keyName }
        if let securityGroupIds, !securityGroupIds.isEmpty { body["securityGroupIds"] = securityGroupIds }
        if let subnetId, !subnetId.isEmpty { body["subnetId"] = subnetId }
        if let name, !name.isEmpty { body["name"] = name }
        return try await post("/api/ec2/instances/launch", query: pq(profile, region), body: body)
    }

    // MARK: - ECS

    func getECSClusters(profile: String, region: String) async throws -> AuthResponse<[EcsCluster]> {
        try await get("/api/ecs/clusters", query: pq(profile, region))
    }

    func getECSServices(profile: String, region: String, cluster: String) async throws -> [EcsServiceSummary] {
        var q = pq(profile, region)
        q["cluster"] = cluster
        return try await get("/api/ecs/services", query: q)
    }

    func getECSServiceDetail(profile: String, region: String, cluster: String, service: String) async throws -> EcsServiceDetail {
        var q = pq(profile, region)
        q["cluster"] = cluster
        q["service"] = service
        return try await get("/api/ecs/service", query: q)
    }

    func getECSServiceTasks(profile: String, region: String, cluster: String, service: String, stopped: Bool) async throws -> [EcsTask] {
        var q = pq(profile, region)
        q["cluster"] = cluster
        q["service"] = service
        q["desiredStatus"] = stopped ? "STOPPED" : "RUNNING"
        return try await get("/api/ecs/service/tasks", query: q)
    }

    func getECSTaskDefinition(profile: String, region: String, taskDefinition: String) async throws -> EcsTaskDefinitionSummary {
        var q = pq(profile, region)
        q["taskDefinition"] = taskDefinition
        return try await get("/api/ecs/task-definition", query: q)
    }

    func setECSDesiredCount(profile: String, region: String, cluster: String, service: String, desiredCount: Int) async throws -> EcsServiceDetail {
        try await put("/api/ecs/service/desired-count", query: pq(profile, region), body: ["cluster": cluster, "service": service, "desiredCount": desiredCount])
    }

    func forceECSDeployment(profile: String, region: String, cluster: String, service: String) async throws -> EcsServiceDetail {
        try await post("/api/ecs/service/force-deployment", query: pq(profile, region), body: ["cluster": cluster, "service": service])
    }

    func stopECSTask(profile: String, region: String, cluster: String, task: String) async throws {
        try await postRaw("/api/ecs/task/stop", query: pq(profile, region), body: ["cluster": cluster, "task": task])
    }

    func addECSServiceTag(profile: String, region: String, cluster: String, service: String, serviceArn: String, key: String, value: String) async throws -> EcsServiceDetail {
        try await post("/api/ecs/service/tags", query: pq(profile, region), body: ["cluster": cluster, "service": service, "serviceArn": serviceArn, "key": key, "value": value])
    }

    func removeECSServiceTag(profile: String, region: String, cluster: String, service: String, serviceArn: String, key: String) async throws -> EcsServiceDetail {
        try await post("/api/ecs/service/tags/remove", query: pq(profile, region), body: ["cluster": cluster, "service": service, "serviceArn": serviceArn, "key": key])
    }

    // MARK: - RDS

    func getRDSInstances(profile: String, region: String) async throws -> AuthResponse<[RdsInstance]> {
        try await get("/api/rds/instances", query: pq(profile, region))
    }

    private func rdsQuery(_ profile: String, _ region: String, _ id: String) -> [String: String] {
        var q = pq(profile, region)
        q["id"] = id
        return q
    }

    func getRDSInstanceDetail(profile: String, region: String, id: String) async throws -> RdsInstanceDetail {
        try await get("/api/rds/instance", query: rdsQuery(profile, region, id))
    }

    func getRDSEvents(profile: String, region: String, id: String) async throws -> [RdsEvent] {
        try await get("/api/rds/instance/events", query: rdsQuery(profile, region, id))
    }

    func getRDSLogFiles(profile: String, region: String, id: String) async throws -> [RdsLogFile] {
        try await get("/api/rds/instance/logs", query: rdsQuery(profile, region, id))
    }

    func getRDSLogTail(profile: String, region: String, id: String, file: String) async throws -> RdsLogContent {
        var q = rdsQuery(profile, region, id)
        q["file"] = file
        return try await get("/api/rds/instance/log", query: q)
    }

    func getRDSSnapshots(profile: String, region: String, id: String) async throws -> [RdsSnapshot] {
        try await get("/api/rds/instance/snapshots", query: rdsQuery(profile, region, id))
    }

    func getRDSMetrics(profile: String, region: String, id: String) async throws -> RdsMetricsSummary {
        try await get("/api/rds/instance/metrics", query: rdsQuery(profile, region, id))
    }

    func createRDSSnapshot(profile: String, region: String, id: String, snapshotId: String) async throws {
        try await postRaw("/api/rds/instance/snapshots", query: pq(profile, region), body: ["id": id, "snapshotId": snapshotId])
    }

    func setRDSInstanceState(profile: String, region: String, id: String, action: String) async throws -> RdsInstanceDetail {
        try await post("/api/rds/instance/state", query: pq(profile, region), body: ["id": id, "action": action])
    }

    func modifyRDSInstance(profile: String, region: String, id: String, deletionProtection: Bool? = nil, backupRetentionPeriod: Int? = nil) async throws -> RdsInstanceDetail {
        var body: [String: Any] = ["id": id]
        if let deletionProtection { body["deletionProtection"] = deletionProtection }
        if let backupRetentionPeriod { body["backupRetentionPeriod"] = backupRetentionPeriod }
        return try await put("/api/rds/instance/modify", query: pq(profile, region), body: body)
    }

    func addRDSTag(profile: String, region: String, id: String, arn: String, key: String, value: String) async throws -> RdsInstanceDetail {
        try await post("/api/rds/instance/tags", query: pq(profile, region), body: ["id": id, "arn": arn, "key": key, "value": value])
    }

    func removeRDSTag(profile: String, region: String, id: String, arn: String, key: String) async throws -> RdsInstanceDetail {
        try await post("/api/rds/instance/tags/remove", query: pq(profile, region), body: ["id": id, "arn": arn, "key": key])
    }

    // MARK: - DynamoDB

    func getDynamoDBTables(profile: String, region: String) async throws -> [String] {
        try await get("/api/dynamodb/tables", query: pq(profile, region))
    }

    /// Every attribute name of a table for the Filter Builder - sparse ones too (the sidecar scans a few pages and caches).
    func getDynamoDBAttributeNames(profile: String, region: String, tableName: String) async throws -> [String] {
        struct Response: Decodable { let names: [String]; let complete: Bool }
        let encoded = tableName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tableName
        let response: Response = try await get("/api/dynamodb/table/\(encoded)/attributes", query: pq(profile, region))
        return response.names
    }

    func getDynamoDBTable(profile: String, region: String, tableName: String) async throws -> DdbTableInfo {
        let encoded = tableName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tableName
        return try await get("/api/dynamodb/table/\(encoded)", query: pq(profile, region))
    }

    func scanDynamoDBTable(profile: String, region: String, tableName: String, limit: Int = 25, startKey: [String: Any]? = nil) async throws -> DdbScanResult {
        let encoded = tableName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tableName
        var q = pq(profile, region)
        q["limit"] = "\(limit)"
        if let startKey, !startKey.isEmpty, let data = try? JSONSerialization.data(withJSONObject: startKey), let json = String(data: data, encoding: .utf8) {
            q["startKey"] = json
        }
        return try await get("/api/dynamodb/scan/\(encoded)", query: q)
    }

    /// Whole-table Filter Builder search - the server scans the table from
    /// `startKey` applying `conditions`, and stops at `maxResults` matches,
    /// its time budget, or the end of the table.
    /// One short (~3 s) step of a whole-table search. Pass the previous
    /// result's `cursor` to continue; nil starts from the beginning.
    func searchDynamoDBTable(profile: String, region: String, tableName: String, conditions: [FilterCondition], maxResults: Int = 100, cursor: String? = nil) async throws -> DdbSearchResult {
        let encoded = tableName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tableName
        var body: [String: Any] = [
            "conditions": conditions.map(\.apiPayload),
            "maxResults": maxResults,
        ]
        if let cursor { body["cursor"] = cursor }
        return try await post("/api/dynamodb/search/\(encoded)", query: pq(profile, region), body: body)
    }

    /// The item exactly as stored (typed DynamoDB JSON) - nil if it no longer exists.
    func getDynamoDBItemTyped(profile: String, region: String, tableName: String, key: [String: Any], keyOrder: [String]) async throws -> [DdbNamedValue]? {
        let encoded = tableName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tableName
        var request = URLRequest(url: url("/api/dynamodb/item/\(encoded)/typed/get", query: pq(profile, region)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["key": key])
        let (data, response) = try await session.data(for: request)
        try await validate(response, data: data)
        // Decoded with JSONSerialization, not Codable: the typed shape is
        // recursive and keyed by type name, which `DdbItemCodec` handles.
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = object["item"] as? [String: Any] else { return nil }
        return try DdbItemCodec.parseTyped(item, keyOrder: keyOrder)
    }

    /// PutItem from typed values - keeps sets, numbers and binary exactly.
    func putDynamoDBItemTyped(profile: String, region: String, tableName: String, item: [DdbNamedValue]) async throws {
        let encoded = tableName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tableName
        try await postRaw("/api/dynamodb/item/\(encoded)/typed", query: pq(profile, region), body: ["item": DdbItemCodec.typedJSONObject(item)])
    }

    // MARK: DynamoDB table administration

    private func ddbPath(_ tableName: String, _ suffix: String) -> String {
        let encoded = tableName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tableName
        return "/api/dynamodb/table/\(encoded)\(suffix)"
    }

    func getDynamoDBTableDetail(profile: String, region: String, tableName: String) async throws -> DdbTableDetail {
        try await get(ddbPath(tableName, "/detail"), query: pq(profile, region))
    }

    func setDynamoDBDeletionProtection(profile: String, region: String, tableName: String, enabled: Bool) async throws -> DdbTableDetail {
        try await put(ddbPath(tableName, "/deletion-protection"), query: pq(profile, region), body: ["enabled": enabled])
    }

    func setDynamoDBPointInTimeRecovery(profile: String, region: String, tableName: String, enabled: Bool) async throws -> DdbTableDetail {
        try await put(ddbPath(tableName, "/pitr"), query: pq(profile, region), body: ["enabled": enabled])
    }

    func setDynamoDBTimeToLive(profile: String, region: String, tableName: String, attributeName: String, enabled: Bool) async throws -> DdbTableDetail {
        try await put(ddbPath(tableName, "/ttl"), query: pq(profile, region), body: ["attributeName": attributeName, "enabled": enabled])
    }

    func addDynamoDBTableTag(profile: String, region: String, tableName: String, arn: String, key: String, value: String) async throws -> DdbTableDetail {
        try await post(ddbPath(tableName, "/tags"), query: pq(profile, region), body: ["arn": arn, "key": key, "value": value])
    }

    func removeDynamoDBTableTag(profile: String, region: String, tableName: String, arn: String, key: String) async throws -> DdbTableDetail {
        try await post(ddbPath(tableName, "/tags/remove"), query: pq(profile, region), body: ["arn": arn, "key": key])
    }

    func getDynamoDBBackups(profile: String, region: String, tableName: String) async throws -> [DdbBackup] {
        try await get(ddbPath(tableName, "/backups"), query: pq(profile, region))
    }

    func createDynamoDBBackup(profile: String, region: String, tableName: String, backupName: String) async throws {
        try await postRaw(ddbPath(tableName, "/backups"), query: pq(profile, region), body: ["backupName": backupName])
    }

    func deleteDynamoDBBackup(profile: String, region: String, backupArn: String) async throws {
        try await postRaw("/api/dynamodb/backups/delete", query: pq(profile, region), body: ["backupArn": backupArn])
    }

    func getDynamoDBMetrics(profile: String, region: String, tableName: String) async throws -> DdbMetricsSummary {
        try await get(ddbPath(tableName, "/metrics"), query: pq(profile, region))
    }

    /// `sortKey.operator`: "none", "=", "<", "<=", ">", ">=", "between", "begins_with".
    func queryDynamoDBTable(profile: String, region: String, tableName: String, indexName: String?, partitionKey: (name: String, type: String, value: String), sortKey: (name: String, type: String, operator: String, value: String, value2: String)?, ascending: Bool, limit: Int, startKey: [String: Any]?, conditions: [FilterCondition] = []) async throws -> DdbPageResult {
        var body: [String: Any] = [
            "conditions": conditions.map(\.apiPayload),
            "partitionKey": ["name": partitionKey.name, "type": partitionKey.type, "value": partitionKey.value],
            "ascending": ascending,
            "limit": limit,
        ]
        if let indexName { body["indexName"] = indexName }
        if let sortKey { body["sortKey"] = ["name": sortKey.name, "type": sortKey.type, "operator": sortKey.operator, "value": sortKey.value, "value2": sortKey.value2] }
        if let startKey, !startKey.isEmpty { body["startKey"] = startKey }
        return try await post(ddbPath(tableName, "/query"), query: pq(profile, region), body: body)
    }

    func executeDynamoDBPartiQL(profile: String, region: String, statement: String, nextToken: String?, limit: Int = 1000) async throws -> DdbPageResult {
        var body: [String: Any] = ["statement": statement, "limit": min(max(limit, 1), 1000)]
        if let nextToken { body["nextToken"] = nextToken }
        return try await post("/api/dynamodb/partiql", query: pq(profile, region), body: body)
    }

    func createDynamoDBTable(profile: String, region: String, tableName: String, partitionKey: (name: String, type: String), sortKey: (name: String, type: String)?) async throws -> DdbTableDetail {
        var body: [String: Any] = ["tableName": tableName, "partitionKey": ["name": partitionKey.name, "type": partitionKey.type]]
        if let sortKey { body["sortKey"] = ["name": sortKey.name, "type": sortKey.type] }
        return try await post("/api/dynamodb/tables", query: pq(profile, region), body: body)
    }

    func deleteDynamoDBTable(profile: String, region: String, tableName: String) async throws {
        try await postRaw(ddbPath(tableName, "/delete"), query: pq(profile, region))
    }

    func putDynamoDBItem(profile: String, region: String, tableName: String, item: [String: Any]) async throws {
        let encoded = tableName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tableName
        try await postRaw("/api/dynamodb/item/\(encoded)", query: pq(profile, region), body: ["item": item])
    }

    func deleteDynamoDBItem(profile: String, region: String, tableName: String, key: [String: Any]) async throws {
        let encoded = tableName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tableName
        try await postRaw("/api/dynamodb/item/\(encoded)/delete", query: pq(profile, region), body: ["key": key])
    }

    // MARK: - S3

    func getS3Buckets(profile: String, region: String) async throws -> [S3Bucket] {
        try await get("/api/s3/buckets", query: pq(profile, region))
    }

    func getS3Objects(profile: String, region: String, bucket: String, prefix: String?) async throws -> S3Objects {
        var q = pq(profile, region)
        q["bucket"] = bucket
        if let prefix = prefix, !prefix.isEmpty { q["prefix"] = prefix }
        return try await get("/api/s3/objects", query: q)
    }

    func searchS3Objects(profile: String, region: String, bucket: String, prefix: String?, query: String) async throws -> [S3Object] {
        var q = pq(profile, region)
        q["bucket"] = bucket
        if let prefix = prefix, !prefix.isEmpty { q["prefix"] = prefix }
        q["query"] = query
        return try await get("/api/s3/search", query: q)
    }

    /// Delimiter-scoped search across every page of one folder, not just
    /// whatever page `getS3Objects` happened to load - "This Folder" search
    /// needs to actually search the whole folder, not just its first 1000
    /// entries.
    func searchS3FolderObjects(profile: String, region: String, bucket: String, prefix: String?, query: String) async throws -> S3Objects {
        var q = pq(profile, region)
        q["bucket"] = bucket
        if let prefix = prefix, !prefix.isEmpty { q["prefix"] = prefix }
        q["query"] = query
        return try await get("/api/s3/search-folder", query: q)
    }

    func getS3Object(profile: String, region: String, bucket: String, key: String) async throws -> S3FilePreview {
        var q = pq(profile, region)
        q["bucket"] = bucket
        q["key"] = key
        return try await get("/api/s3/object", query: q)
    }

    func downloadS3File(profile: String, region: String, bucket: String, key: String) async throws -> Data {
        var q = pq(profile, region)
        q["bucket"] = bucket
        q["key"] = key
        let request = URLRequest(url: url("/api/s3/download", query: q))
        let (data, response) = try await session.data(for: request)
        try await validate(response, data: data)
        return data
    }

    func getZipEntries(profile: String, region: String, bucket: String, key: String, path: [String]) async throws -> ZipEntryList {
        try await get("/api/s3/zip-entries", queryItems: zipQueryItems(profile: profile, region: region, bucket: bucket, key: key, path: path))
    }

    func getZipEntryContent(profile: String, region: String, bucket: String, key: String, path: [String]) async throws -> ZipEntryContent {
        try await get("/api/s3/zip-entry", queryItems: zipQueryItems(profile: profile, region: region, bucket: bucket, key: key, path: path))
    }

    /// Raw bytes of one archive entry (images, PDFs, downloads).
    func getZipEntryData(profile: String, region: String, bucket: String, key: String, path: [String]) async throws -> Data {
        let request = URLRequest(url: url("/api/s3/zip-entry-raw", queryItems: zipQueryItems(profile: profile, region: region, bucket: bucket, key: key, path: path)))
        let (data, response) = try await session.data(for: request)
        try await validate(response, data: data)
        return data
    }

    private func zipQueryItems(profile: String, region: String, bucket: String, key: String, path: [String]) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "profile", value: profile),
            URLQueryItem(name: "region", value: region),
            URLQueryItem(name: "bucket", value: bucket),
            URLQueryItem(name: "key", value: key),
        ]
        items += path.map { URLQueryItem(name: "path", value: $0) }
        return items
    }

    // MARK: - SQS

    func getSQSQueues(profile: String, region: String) async throws -> AuthResponse<[SqsQueue]> {
        try await get("/api/sqs/queues", query: pq(profile, region))
    }

    func getSQSQueueDetail(profile: String, region: String, queueUrl: String) async throws -> SqsQueueDetail {
        var q = pq(profile, region)
        q["queueUrl"] = queueUrl
        return try await get("/api/sqs/queue", query: q)
    }

    func updateSQSQueueAttributes(profile: String, region: String, queueUrl: String, attributes: [String: String]) async throws -> SqsQueueDetail {
        try await put("/api/sqs/queue/attributes", query: pq(profile, region), body: ["queueUrl": queueUrl, "attributes": attributes])
    }

    func sendSQSMessage(profile: String, region: String, queueUrl: String, body: String, delaySeconds: Int?, messageGroupId: String?, messageDeduplicationId: String?) async throws -> String? {
        var payload: [String: Any] = ["queueUrl": queueUrl, "body": body]
        if let delaySeconds { payload["delaySeconds"] = delaySeconds }
        if let messageGroupId { payload["messageGroupId"] = messageGroupId }
        if let messageDeduplicationId { payload["messageDeduplicationId"] = messageDeduplicationId }
        let response: SendMessageResponse = try await post("/api/sqs/messages/send", query: pq(profile, region), body: payload)
        return response.messageId
    }

    func receiveSQSMessages(profile: String, region: String, queueUrl: String, maxMessages: Int) async throws -> [SqsMessage] {
        try await post("/api/sqs/messages/receive", query: pq(profile, region), body: ["queueUrl": queueUrl, "maxMessages": maxMessages])
    }

    func deleteSQSMessage(profile: String, region: String, queueUrl: String, receiptHandle: String) async throws {
        try await postRaw("/api/sqs/messages/delete", query: pq(profile, region), body: ["queueUrl": queueUrl, "receiptHandle": receiptHandle])
    }

    func purgeSQSQueue(profile: String, region: String, queueUrl: String) async throws -> SqsQueueDetail {
        try await post("/api/sqs/queue/purge", query: pq(profile, region), body: ["queueUrl": queueUrl])
    }

    func addSQSTag(profile: String, region: String, queueUrl: String, key: String, value: String) async throws -> SqsQueueDetail {
        try await post("/api/sqs/tags", query: pq(profile, region), body: ["queueUrl": queueUrl, "key": key, "value": value])
    }

    func removeSQSTag(profile: String, region: String, queueUrl: String, key: String) async throws -> SqsQueueDetail {
        try await post("/api/sqs/tags/remove", query: pq(profile, region), body: ["queueUrl": queueUrl, "key": key])
    }

    // MARK: - CloudWatch

    func getCloudWatchAlarms(profile: String, region: String) async throws -> AuthResponse<[CloudWatchAlarm]> {
        try await get("/api/cloudwatch/alarms", query: pq(profile, region))
    }

    func getLogGroups(profile: String, region: String) async throws -> AuthResponse<[LogGroup]> {
        try await get("/api/cloudwatch/log-groups", query: pq(profile, region))
    }

    func getCloudWatchAlarmDetail(profile: String, region: String, alarmName: String) async throws -> CloudWatchAlarmDetail {
        var q = pq(profile, region)
        q["alarmName"] = alarmName
        return try await get("/api/cloudwatch/alarm", query: q)
    }

    func updateCloudWatchAlarmThreshold(profile: String, region: String, alarmName: String, threshold: Double, comparisonOperator: String, evaluationPeriods: Int, period: Int) async throws -> CloudWatchAlarmDetail {
        try await put("/api/cloudwatch/alarm/threshold", query: pq(profile, region), body: [
            "alarmName": alarmName,
            "threshold": threshold,
            "comparisonOperator": comparisonOperator,
            "evaluationPeriods": evaluationPeriods,
            "period": period,
        ])
    }

    func setCloudWatchAlarmActionsEnabled(profile: String, region: String, alarmName: String, enabled: Bool) async throws -> CloudWatchAlarmDetail {
        try await put("/api/cloudwatch/alarm/actions-enabled", query: pq(profile, region), body: ["alarmName": alarmName, "enabled": enabled])
    }

    func deleteCloudWatchAlarm(profile: String, region: String, alarmName: String) async throws {
        try await postRaw("/api/cloudwatch/alarm/delete", query: pq(profile, region), body: ["alarmName": alarmName])
    }

    func getLogGroupStreams(profile: String, region: String, logGroupName: String) async throws -> [LogStreamInfo] {
        var q = pq(profile, region)
        q["logGroupName"] = logGroupName
        return try await get("/api/cloudwatch/log-group/streams", query: q)
    }

    func getLogGroupEvents(profile: String, region: String, logGroupName: String, logStreamName: String) async throws -> [LogEventInfo] {
        var q = pq(profile, region)
        q["logGroupName"] = logGroupName
        q["logStreamName"] = logStreamName
        return try await get("/api/cloudwatch/log-group/events", query: q)
    }

    func setLogGroupRetention(profile: String, region: String, logGroupName: String, retentionInDays: Int?) async throws {
        var body: [String: Any] = ["logGroupName": logGroupName]
        if let retentionInDays { body["retentionInDays"] = retentionInDays }
        let _: OkResponse = try await put("/api/cloudwatch/log-group/retention", query: pq(profile, region), body: body)
    }

    func deleteLogGroup(profile: String, region: String, logGroupName: String) async throws {
        try await postRaw("/api/cloudwatch/log-group/delete", query: pq(profile, region), body: ["logGroupName": logGroupName])
    }

    // MARK: - CloudFront

    func getCloudFrontDistributions(profile: String, region: String) async throws -> AuthResponse<[CloudFrontDistribution]> {
        try await get("/api/cloudfront/distributions", query: pq(profile, region))
    }

    func getCloudFrontDistributionDetail(profile: String, region: String, id: String) async throws -> CloudFrontDistributionDetail {
        var q = pq(profile, region)
        q["id"] = id
        return try await get("/api/cloudfront/distribution", query: q)
    }

    func getCloudFrontInvalidations(profile: String, region: String, id: String) async throws -> [CloudFrontInvalidation] {
        try await get("/api/cloudfront/distribution/invalidations", query: pq(profile, region).merging(["id": id]) { $1 })
    }

    func getCloudFrontInvalidation(profile: String, region: String, id: String, invalidationId: String) async throws -> CloudFrontInvalidation {
        try await get("/api/cloudfront/distribution/invalidation", query: pq(profile, region).merging(["id": id, "invalidationId": invalidationId]) { $1 })
    }

    func createCloudFrontInvalidation(profile: String, region: String, id: String, paths: [String]) async throws -> CloudFrontInvalidation {
        try await post("/api/cloudfront/distribution/invalidations", query: pq(profile, region), body: ["id": id, "paths": paths])
    }

    func setCloudFrontDistributionEnabled(profile: String, region: String, id: String, enabled: Bool) async throws -> CloudFrontDistributionDetail {
        try await put("/api/cloudfront/distribution/enabled", query: pq(profile, region), body: ["id": id, "enabled": enabled])
    }

    func deleteCloudFrontDistribution(profile: String, region: String, id: String) async throws {
        try await postRaw("/api/cloudfront/distribution/delete", query: pq(profile, region), body: ["id": id])
    }

    func addCloudFrontTag(profile: String, region: String, id: String, key: String, value: String) async throws -> CloudFrontDistributionDetail {
        try await post("/api/cloudfront/distribution/tags", query: pq(profile, region), body: ["id": id, "key": key, "value": value])
    }

    func removeCloudFrontTag(profile: String, region: String, id: String, key: String) async throws -> CloudFrontDistributionDetail {
        try await post("/api/cloudfront/distribution/tags/remove", query: pq(profile, region), body: ["id": id, "key": key])
    }

    // MARK: - Route53

    func getHostedZones(profile: String, region: String) async throws -> AuthResponse<[HostedZone]> {
        try await get("/api/route53/zones", query: pq(profile, region))
    }

    func getRoute53ZoneDetail(profile: String, zoneId: String) async throws -> Route53ZoneDetail {
        try await get("/api/route53/zone", query: ["profile": profile, "zoneId": zoneId])
    }

    func getRoute53Records(profile: String, zoneId: String, startName: String? = nil, startType: String? = nil, startIdentifier: String? = nil) async throws -> Route53RecordPage {
        var q = ["profile": profile, "zoneId": zoneId]
        if let startName { q["startName"] = startName }
        if let startType { q["startType"] = startType }
        if let startIdentifier { q["startIdentifier"] = startIdentifier }
        return try await get("/api/route53/zone/records", query: q)
    }

    func createRoute53Record(profile: String, zoneId: String, name: String, type: String, ttl: Int, values: [String]) async throws {
        try await postRaw("/api/route53/zone/records", query: ["profile": profile], body: ["zoneId": zoneId, "name": name, "type": type, "ttl": ttl, "values": values])
    }

    func updateRoute53Record(profile: String, zoneId: String, record: Route53Record, ttl: Int, values: [String]) async throws {
        var body: [String: Any] = ["zoneId": zoneId, "name": record.name, "type": record.type, "ttl": ttl, "values": values]
        if let setIdentifier = record.setIdentifier { body["setIdentifier"] = setIdentifier }
        try await putRaw("/api/route53/zone/records", query: ["profile": profile], body: body)
    }

    func deleteRoute53Record(profile: String, zoneId: String, record: Route53Record) async throws {
        var body: [String: Any] = ["zoneId": zoneId, "name": record.name, "type": record.type]
        if let setIdentifier = record.setIdentifier { body["setIdentifier"] = setIdentifier }
        try await postRaw("/api/route53/zone/records/delete", query: ["profile": profile], body: body)
    }

    func updateRoute53ZoneComment(profile: String, zoneId: String, comment: String) async throws -> Route53ZoneDetail {
        try await put("/api/route53/zone/comment", query: ["profile": profile], body: ["zoneId": zoneId, "comment": comment])
    }

    func addRoute53ZoneTag(profile: String, zoneId: String, key: String, value: String) async throws -> Route53ZoneDetail {
        try await post("/api/route53/zone/tags", query: ["profile": profile], body: ["zoneId": zoneId, "key": key, "value": value])
    }

    func removeRoute53ZoneTag(profile: String, zoneId: String, key: String) async throws -> Route53ZoneDetail {
        try await post("/api/route53/zone/tags/remove", query: ["profile": profile], body: ["zoneId": zoneId, "key": key])
    }

    // MARK: - CodeCommit

    func getCodeCommitRepositories(profile: String, region: String) async throws -> [CodeCommitRepository] {
        try await get("/api/codecommit/repositories", query: pq(profile, region))
    }

    func getCodeCommitRepositoryDetail(profile: String, region: String, name: String) async throws -> CodeCommitRepositoryDetail {
        var q = pq(profile, region)
        q["name"] = name
        return try await get("/api/codecommit/repository", query: q)
    }

    func getCodeCommitBranches(profile: String, region: String, name: String) async throws -> [CodeCommitBranch] {
        var q = pq(profile, region)
        q["name"] = name
        return try await get("/api/codecommit/branches", query: q)
    }

    func getCodeCommitFolder(profile: String, region: String, name: String, path: String, commit: String?) async throws -> CodeCommitFolderListing {
        var q = pq(profile, region)
        q["name"] = name
        q["path"] = path
        if let commit { q["commit"] = commit }
        return try await get("/api/codecommit/folder", query: q)
    }

    func getCodeCommitFile(profile: String, region: String, name: String, path: String, commit: String?) async throws -> CodeCommitFileContent {
        var q = pq(profile, region)
        q["name"] = name
        q["path"] = path
        if let commit { q["commit"] = commit }
        return try await get("/api/codecommit/file", query: q)
    }

    func getCodeCommitCommits(profile: String, region: String, name: String, commit: String, limit: Int = 30) async throws -> [CodeCommitCommit] {
        var q = pq(profile, region)
        q["name"] = name
        q["commit"] = commit
        q["limit"] = "\(limit)"
        return try await get("/api/codecommit/commits", query: q)
    }

    func getCodeCommitCommitsForPath(profile: String, region: String, name: String, commit: String, path: String, cursor: String?, limit: Int = 30) async throws -> CodeCommitPathHistoryPage {
        var q = pq(profile, region)
        q["name"] = name
        q["commit"] = commit
        q["path"] = path
        q["limit"] = "\(limit)"
        if let cursor {
            q["cursor"] = cursor
        }
        return try await get("/api/codecommit/commits-for-path", query: q)
    }

    func getCodeCommitPullRequests(profile: String, region: String, name: String, status: String) async throws -> [CodeCommitPullRequest] {
        var q = pq(profile, region)
        q["name"] = name
        q["status"] = status
        return try await get("/api/codecommit/pull-requests", query: q)
    }

    func createCodeCommitPullRequest(profile: String, region: String, repositoryName: String, title: String, description: String?, sourceReference: String, destinationReference: String) async throws -> CodeCommitPullRequest {
        var body: [String: Any] = [
            "repositoryName": repositoryName,
            "title": title,
            "sourceReference": sourceReference,
            "destinationReference": destinationReference,
        ]
        if let description { body["description"] = description }
        return try await post("/api/codecommit/pull-requests", query: pq(profile, region), body: body)
    }

    func getCodeCommitCommit(profile: String, region: String, name: String, commit: String) async throws -> CodeCommitCommit {
        var q = pq(profile, region)
        q["name"] = name
        q["commit"] = commit
        return try await get("/api/codecommit/commit", query: q)
    }

    func getCodeCommitCommitsAhead(profile: String, region: String, name: String, source: String, destination: String) async throws -> [CodeCommitCommit] {
        var q = pq(profile, region)
        q["name"] = name
        q["source"] = source
        q["destination"] = destination
        return try await get("/api/codecommit/commits-ahead", query: q)
    }

    func getCodeCommitDifferences(profile: String, region: String, name: String, before: String?, after: String) async throws -> [CodeCommitDiffEntry] {
        var q = pq(profile, region)
        q["name"] = name
        if let before { q["before"] = before }
        q["after"] = after
        return try await get("/api/codecommit/differences", query: q)
    }

    /// `fullFile`: the whole file as context (the diff viewer's File mode).
    func getCodeCommitFileDiff(profile: String, region: String, name: String, path: String, before: String?, after: String, fullFile: Bool = false) async throws -> CodeCommitFileDiff {
        var q = pq(profile, region)
        if fullFile { q["full"] = "1" }
        q["name"] = name
        q["path"] = path
        if let before { q["before"] = before }
        q["after"] = after
        return try await get("/api/codecommit/file-diff", query: q)
    }

    func getCodeCommitPRLimits() async throws -> CodeCommitPRLimits {
        try await get("/api/codecommit/pr-limits")
    }

    func getCodeCommitPullRequest(profile: String, region: String, id: String) async throws -> CodeCommitPullRequest {
        var q = pq(profile, region)
        q["id"] = id
        return try await get("/api/codecommit/pull-request", query: q)
    }

    func checkCodeCommitMergeConflicts(profile: String, region: String, name: String, destination: String, source: String, mergeOption: CodeCommitMergeOption) async throws -> CodeCommitMergeCheck {
        var q = pq(profile, region)
        q["name"] = name
        q["destination"] = destination
        q["source"] = source
        q["mergeOption"] = mergeOption.rawValue
        return try await get("/api/codecommit/merge-conflicts", query: q)
    }

    func mergeCodeCommitPullRequest(profile: String, region: String, repositoryName: String, pullRequestId: String, mergeOption: CodeCommitMergeOption, commitMessage: String?) async throws -> CodeCommitPullRequest {
        var body: [String: Any] = [
            "repositoryName": repositoryName,
            "pullRequestId": pullRequestId,
            "mergeOption": mergeOption.rawValue,
        ]
        if let commitMessage, !commitMessage.isEmpty { body["commitMessage"] = commitMessage }
        return try await post("/api/codecommit/pull-requests/merge", query: pq(profile, region), body: body)
    }

    func closeCodeCommitPullRequest(profile: String, region: String, pullRequestId: String) async throws -> CodeCommitPullRequest {
        try await post("/api/codecommit/pull-requests/close", query: pq(profile, region), body: ["pullRequestId": pullRequestId])
    }

    func createCodeCommitBranch(profile: String, region: String, repositoryName: String, branchName: String, commitId: String) async throws {
        try await postRaw("/api/codecommit/branches", query: pq(profile, region), body: ["repositoryName": repositoryName, "branchName": branchName, "commitId": commitId])
    }

    func deleteCodeCommitBranch(profile: String, region: String, repositoryName: String, branchName: String) async throws {
        try await postRaw("/api/codecommit/branches/delete", query: pq(profile, region), body: ["repositoryName": repositoryName, "branchName": branchName])
    }

    func mergeCodeCommitBranches(profile: String, region: String, repositoryName: String, sourceBranch: String, destinationBranch: String, mergeOption: CodeCommitMergeOption, commitMessage: String?) async throws {
        var body: [String: Any] = ["repositoryName": repositoryName, "sourceBranch": sourceBranch, "destinationBranch": destinationBranch, "mergeOption": mergeOption.rawValue]
        if let commitMessage, !commitMessage.isEmpty { body["commitMessage"] = commitMessage }
        try await postRaw("/api/codecommit/branches/merge", query: pq(profile, region), body: body)
    }

    func createCodeCommitRepository(profile: String, region: String, repositoryName: String, description: String?) async throws {
        var body: [String: Any] = ["repositoryName": repositoryName]
        if let description, !description.isEmpty { body["description"] = description }
        try await postRaw("/api/codecommit/repositories", query: pq(profile, region), body: body)
    }

    func deleteCodeCommitRepository(profile: String, region: String, repositoryName: String) async throws {
        try await postRaw("/api/codecommit/repositories/delete", query: pq(profile, region), body: ["repositoryName": repositoryName])
    }

    func getCodeCommitPullRequestComments(profile: String, region: String, pullRequestId: String, repositoryName: String?, beforeCommitId: String?, afterCommitId: String?) async throws -> [CodeCommitCommentThread] {
        var q = pq(profile, region)
        q["pullRequestId"] = pullRequestId
        if let repositoryName { q["repositoryName"] = repositoryName }
        if let beforeCommitId { q["beforeCommitId"] = beforeCommitId }
        if let afterCommitId { q["afterCommitId"] = afterCommitId }
        return try await get("/api/codecommit/pull-requests/comments", query: q)
    }

    func postCodeCommitPullRequestComment(profile: String, region: String, pullRequestId: String, repositoryName: String, beforeCommitId: String, afterCommitId: String, content: String, filePath: String?, filePosition: Int?, relativeFileVersion: String?) async throws -> CodeCommitCommentThread {
        var body: [String: Any] = [
            "pullRequestId": pullRequestId,
            "repositoryName": repositoryName,
            "beforeCommitId": beforeCommitId,
            "afterCommitId": afterCommitId,
            "content": content,
        ]
        if let filePath { body["filePath"] = filePath }
        if let filePosition { body["filePosition"] = filePosition }
        if let relativeFileVersion { body["relativeFileVersion"] = relativeFileVersion }
        return try await post("/api/codecommit/pull-requests/comments", query: pq(profile, region), body: body)
    }

    func postCodeCommitCommentReply(profile: String, region: String, inReplyTo: String, content: String) async throws -> CodeCommitComment {
        try await post("/api/codecommit/comments/reply", query: pq(profile, region), body: ["inReplyTo": inReplyTo, "content": content])
    }

    func deleteCodeCommitComment(profile: String, region: String, commentId: String) async throws {
        try await postRaw("/api/codecommit/comments/delete", query: pq(profile, region), body: ["commentId": commentId])
    }

    func getCodeCommitPullRequestApprovals(profile: String, region: String, pullRequestId: String, revisionId: String) async throws -> [CodeCommitApproval] {
        var q = pq(profile, region)
        q["pullRequestId"] = pullRequestId
        q["revisionId"] = revisionId
        return try await get("/api/codecommit/pull-requests/approvals", query: q)
    }

    func setCodeCommitPullRequestApproval(profile: String, region: String, pullRequestId: String, revisionId: String, approved: Bool) async throws {
        try await postRaw("/api/codecommit/pull-requests/approvals", query: pq(profile, region), body: ["pullRequestId": pullRequestId, "revisionId": revisionId, "approved": approved])
    }

    func getCodeCommitPullRequestEvents(profile: String, region: String, pullRequestId: String) async throws -> [CodeCommitPullRequestEvent] {
        var q = pq(profile, region)
        q["pullRequestId"] = pullRequestId
        return try await get("/api/codecommit/pull-requests/events", query: q)
    }

    func getCodeCommitTriggers(profile: String, region: String, repositoryName: String) async throws -> [CodeCommitRepositoryTrigger] {
        var q = pq(profile, region)
        q["repositoryName"] = repositoryName
        return try await get("/api/codecommit/triggers", query: q)
    }

    func setCodeCommitTriggers(profile: String, region: String, repositoryName: String, triggers: [CodeCommitRepositoryTrigger]) async throws {
        let _: OkResponse = try await put("/api/codecommit/triggers", query: pq(profile, region), body: [
            "repositoryName": repositoryName,
            "triggers": triggers.map { t -> [String: Any] in
                ["name": t.name, "destinationArn": t.destinationArn, "customData": t.customData ?? "", "branches": t.branches, "events": t.events]
            },
        ])
    }

    func testCodeCommitTriggers(profile: String, region: String, repositoryName: String, triggers: [CodeCommitRepositoryTrigger]) async throws -> [String] {
        try await post("/api/codecommit/triggers/test", query: pq(profile, region), body: [
            "repositoryName": repositoryName,
            "triggers": triggers.map { t -> [String: Any] in
                ["name": t.name, "destinationArn": t.destinationArn, "customData": t.customData ?? "", "branches": t.branches, "events": t.events]
            },
        ])
    }

    func putCodeCommitFile(profile: String, region: String, repositoryName: String, branchName: String, filePath: String, fileContent: String, commitMessage: String, parentCommitId: String?) async throws -> String {
        var body: [String: Any] = ["repositoryName": repositoryName, "branchName": branchName, "filePath": filePath, "fileContent": fileContent, "commitMessage": commitMessage]
        if let parentCommitId { body["parentCommitId"] = parentCommitId }
        struct CommitIdResponse: Codable { let commitId: String }
        let response: CommitIdResponse = try await put("/api/codecommit/file", query: pq(profile, region), body: body)
        return response.commitId
    }

    func deleteCodeCommitFile(profile: String, region: String, repositoryName: String, branchName: String, filePath: String, commitMessage: String, parentCommitId: String) async throws -> String {
        struct CommitIdResponse: Codable { let commitId: String }
        let response: CommitIdResponse = try await post("/api/codecommit/file/delete", query: pq(profile, region), body: ["repositoryName": repositoryName, "branchName": branchName, "filePath": filePath, "commitMessage": commitMessage, "parentCommitId": parentCommitId])
        return response.commitId
    }

    func searchCodeCommitFiles(profile: String, region: String, repositoryName: String, commitSpecifier: String, query: String, cursor: String?, limit: Int) async throws -> CodeCommitFileSearchPage {
        var q = pq(profile, region)
        q["repositoryName"] = repositoryName
        q["commitSpecifier"] = commitSpecifier
        q["q"] = query
        q["limit"] = String(limit)
        if let cursor {
            q["cursor"] = cursor
        }
        return try await get("/api/codecommit/files/search", query: q)
    }

    // MARK: - CodeCommit repository settings

    func updateCodeCommitRepositoryName(profile: String, region: String, oldName: String, newName: String) async throws -> CodeCommitRepositoryDetail {
        try await put("/api/codecommit/repository/name", query: pq(profile, region), body: ["oldName": oldName, "newName": newName])
    }

    func updateCodeCommitRepositoryDescription(profile: String, region: String, name: String, description: String) async throws -> CodeCommitRepositoryDetail {
        try await put("/api/codecommit/repository/description", query: pq(profile, region), body: ["repositoryName": name, "description": description])
    }

    func updateCodeCommitDefaultBranch(profile: String, region: String, name: String, defaultBranchName: String) async throws -> CodeCommitRepositoryDetail {
        try await put("/api/codecommit/repository/default-branch", query: pq(profile, region), body: ["repositoryName": name, "defaultBranchName": defaultBranchName])
    }

    func addCodeCommitRepositoryTag(profile: String, region: String, name: String, key: String, value: String) async throws -> CodeCommitRepositoryDetail {
        try await post("/api/codecommit/repository/tags", query: pq(profile, region), body: ["repositoryName": name, "key": key, "value": value])
    }

    func removeCodeCommitRepositoryTag(profile: String, region: String, name: String, key: String) async throws -> CodeCommitRepositoryDetail {
        try await post("/api/codecommit/repository/tags/remove", query: pq(profile, region), body: ["repositoryName": name, "key": key])
    }

    // MARK: - Workspace (local git clone: Clone/Pull/Push/Merge)

    /// Every repo that currently has a workspace matched/cloned - used to
    /// preload a "has a workspace" indicator when the CodeCommit repo list
    /// loads, and for the Settings sheet's workspaces list.
    func listWorkspaces() async throws -> [WorkspaceEntry] {
        try await get("/api/workspace/list")
    }

    func getWorkspaceStatus(profile: String, region: String, name: String) async throws -> WorkspaceStatus {
        var q = pq(profile, region)
        q["name"] = name
        return try await get("/api/workspace/status", query: q)
    }

    func cloneWorkspace(profile: String, region: String, name: String, cloneUrl: String, parentDirectory: String) async throws -> GitCommandResult {
        try await post("/api/workspace/clone", query: pq(profile, region), body: ["name": name, "cloneUrl": cloneUrl, "parentDirectory": parentDirectory])
    }

    /// Links an already-existing local clone to this repo instead of
    /// running a fresh `git clone`.
    func matchWorkspace(profile: String, region: String, name: String, cloneUrl: String?, localPath: String) async throws -> MatchResult {
        var body: [String: Any] = ["name": name, "localPath": localPath]
        if let cloneUrl { body["cloneUrl"] = cloneUrl }
        return try await post("/api/workspace/match", query: pq(profile, region), body: body)
    }

    func getLocalWorkspaceDiffSummary(profile: String, region: String, name: String, branch: String) async throws -> [LocalDiffFile] {
        var q = pq(profile, region)
        q["name"] = name
        q["branch"] = branch
        return try await get("/api/workspace/diff/summary", query: q)
    }

    func getLocalWorkspaceFileDiff(profile: String, region: String, name: String, branch: String, path: String, fullFile: Bool = false) async throws -> CodeCommitFileDiff {
        var q = pq(profile, region)
        if fullFile { q["full"] = "1" }
        q["name"] = name
        q["branch"] = branch
        q["path"] = path
        return try await get("/api/workspace/diff/file", query: q)
    }

    func pullWorkspace(profile: String, region: String, name: String) async throws -> GitCommandResult {
        try await post("/api/workspace/pull", query: pq(profile, region), body: ["name": name])
    }

    func pushWorkspace(profile: String, region: String, name: String) async throws -> GitCommandResult {
        try await post("/api/workspace/push", query: pq(profile, region), body: ["name": name])
    }

    func mergeIntoWorkspace(profile: String, region: String, name: String, branch: String) async throws -> GitCommandResult {
        try await post("/api/workspace/merge", query: pq(profile, region), body: ["name": name, "branch": branch])
    }

    func forgetWorkspace(profile: String, region: String, name: String) async throws {
        try await postRaw("/api/workspace/forget", query: pq(profile, region), body: ["name": name])
    }

    // MARK: - App Config

    func getAppConfig() async throws -> AppConfig {
        try await get("/api/config")
    }

    /// The literal contents of `~/.awsvisualizer`, for the Settings "view
    /// raw config" popup - not the typed `AppConfig`, which only models the
    /// fields this app knows about.
    func getRawConfigFile() async throws -> String {
        let response: RawConfigFileResponse = try await get("/api/config/raw")
        return response.text
    }

    func updateDefaultRegion(_ region: String) async throws -> AppConfig {
        try await put("/api/config/aws", body: ["defaultRegion": region])
    }

    // MARK: Personal accounts (aws login / access keys)

    func getPersonalAccounts() async throws -> PersonalAccountsState {
        try await get("/api/personal-accounts")
    }

    /// Runs `aws login --profile` - opens the browser for the console sign-in.
    func loginPersonalAccount(profile: String, region: String) async throws -> PersonalAccountResult {
        try await post("/api/personal-accounts/login", body: ["profile": profile, "region": region], timeout: 320)
    }

    func addAccessKeyAccount(profile: String, accessKeyId: String, secretAccessKey: String, region: String) async throws -> PersonalAccountResult {
        try await post("/api/personal-accounts/access-keys", body: ["profile": profile, "accessKeyId": accessKeyId, "secretAccessKey": secretAccessKey, "region": region])
    }

    // MARK: Setup / access portals

    func getSetupState() async throws -> SetupState {
        try await get("/api/setup")
    }

    func addPlatform(startUrl: String, region: String, name: String?) async throws -> AddPlatformResponse {
        var body: [String: Any] = ["startUrl": startUrl, "region": region]
        if let name, !name.isEmpty { body["name"] = name }
        return try await post("/api/setup/platforms", body: body)
    }

    func removePlatform(id: String) async throws -> [SsoPlatformStatus] {
        let response: PlatformsResponse = try await post("/api/setup/platforms/remove", body: ["id": id])
        return response.platforms
    }

    func enableConfigPersistence() async throws {
        let _: PersistResponse = try await post("/api/setup/persist")
    }

    func updateMaxTabs(_ maxTabs: Int) async throws -> AppConfig {
        try await put("/api/config/max-tabs", body: ["maxTabs": maxTabs])
    }

    func updateDevTools(_ config: DevToolsConfig) async throws {
        let body: [String: Any] = [
            "enabled": config.enabled,
            "custom": config.custom.map { ["id": $0.id, "name": $0.name, "command": $0.command, "icon": $0.icon] },
        ]
        let _: OkResponse = try await put("/api/config/dev-tools", body: body)
    }

    func updateDynamoDbAutoColumnWidth(_ enabled: Bool) async throws -> AppConfig {
        try await put("/api/config/dynamodb-auto-column-width", body: ["enabled": enabled])
    }

    func updateCodeTheme(_ theme: CodeThemeID) async throws -> AppConfig {
        try await put("/api/config/code-theme", body: ["theme": theme.rawValue])
    }

    func updateViewPreferences(layoutMode: LayoutMode? = nil, wordWrap: Bool? = nil, fileIconTheme: FileIconTheme? = nil, historyLayout: LayoutMode? = nil) async throws -> AppConfig {
        var body: [String: Any] = [:]
        if let historyLayout { body["historyLayout"] = historyLayout.rawValue }
        if let fileIconTheme { body["fileIconTheme"] = fileIconTheme.rawValue }
        if let layoutMode { body["layoutMode"] = layoutMode.rawValue }
        if let wordWrap { body["wordWrap"] = wordWrap }
        return try await put("/api/config/view-preferences", body: body)
    }

    func updateDynamoDbItemView(_ view: DynamoItemViewMode) async throws -> AppConfig {
        try await put("/api/config/dynamodb-item-view", body: ["view": view.rawValue])
    }

    func updateButtonColors(_ colors: ButtonColorConfig) async throws -> AppConfig {
        try await put("/api/config/button-colors", body: colors.asDictionary)
    }

    func updateDefaultIDE(_ bundleIdentifier: String) async throws -> AppConfig {
        try await put("/api/config/default-ide", body: ["bundleIdentifier": bundleIdentifier])
    }

    // MARK: - Secrets Manager

    func getSecrets(profile: String, region: String) async throws -> [SecretsManagerSecret] {
        try await get("/api/secretsmanager/secrets", query: pq(profile, region))
    }

    func getSecretDetail(profile: String, region: String, name: String) async throws -> SecretsManagerSecretDetail {
        var q = pq(profile, region)
        q["name"] = name
        return try await get("/api/secretsmanager/secret", query: q)
    }

    func updateSecretDescription(profile: String, region: String, name: String, description: String) async throws -> SecretsManagerSecretDetail {
        try await put("/api/secretsmanager/secret/description", query: pq(profile, region), body: ["name": name, "description": description])
    }

    func addSecretTag(profile: String, region: String, name: String, key: String, value: String) async throws -> SecretsManagerSecretDetail {
        try await post("/api/secretsmanager/secret/tags", query: pq(profile, region), body: ["name": name, "key": key, "value": value])
    }

    func removeSecretTag(profile: String, region: String, name: String, key: String) async throws -> SecretsManagerSecretDetail {
        try await post("/api/secretsmanager/secret/tags/remove", query: pq(profile, region), body: ["name": name, "key": key])
    }

    func deleteSecret(profile: String, region: String, name: String, recoveryWindowInDays: Int) async throws {
        try await postRaw("/api/secretsmanager/secret/delete", query: pq(profile, region), body: ["name": name, "recoveryWindowInDays": recoveryWindowInDays])
    }

    func restoreSecret(profile: String, region: String, name: String) async throws -> SecretsManagerSecretDetail {
        try await post("/api/secretsmanager/secret/restore", query: pq(profile, region), body: ["name": name])
    }

    /// Only called when the user explicitly clicks "Reveal" - never as part
    /// of loading a secret's detail page.
    /// New version of the secret's value (becomes AWSCURRENT).
    func putSecretValue(profile: String, region: String, name: String, secretString: String) async throws -> SecretsManagerSecretValue {
        try await put("/api/secretsmanager/secret/value", query: pq(profile, region), body: ["name": name, "secretString": secretString])
    }

    func getSecretValue(profile: String, region: String, name: String) async throws -> SecretsManagerSecretValue {
        var q = pq(profile, region)
        q["name"] = name
        return try await get("/api/secretsmanager/secret/value", query: q)
    }

    func createSecret(profile: String, region: String, name: String, description: String, secretString: String, kmsKeyId: String, tags: [SecretsManagerTag]) async throws -> SecretsManagerSecretDetail {
        var body: [String: Any] = ["name": name, "secretString": secretString]
        if !description.isEmpty { body["description"] = description }
        if !kmsKeyId.isEmpty { body["kmsKeyId"] = kmsKeyId }
        if !tags.isEmpty { body["tags"] = tags.map { ["key": $0.key, "value": $0.value] } }
        return try await post("/api/secretsmanager/secrets", query: pq(profile, region), body: body)
    }

    func getSecretResourcePolicy(profile: String, region: String, name: String) async throws -> SecretsManagerResourcePolicy {
        var q = pq(profile, region)
        q["name"] = name
        return try await get("/api/secretsmanager/secret/policy", query: q)
    }

    func putSecretResourcePolicy(profile: String, region: String, name: String, policy: String) async throws -> SecretsManagerResourcePolicy {
        try await put("/api/secretsmanager/secret/policy", query: pq(profile, region), body: ["name": name, "policy": policy])
    }

    func deleteSecretResourcePolicy(profile: String, region: String, name: String) async throws {
        try await postRaw("/api/secretsmanager/secret/policy/delete", query: pq(profile, region), body: ["name": name])
    }

    func updateSecretRotation(profile: String, region: String, name: String, rotationLambdaARN: String, automaticallyAfterDays: Int) async throws -> SecretsManagerSecretDetail {
        try await post("/api/secretsmanager/secret/rotation", query: pq(profile, region), body: ["name": name, "rotationLambdaARN": rotationLambdaARN, "automaticallyAfterDays": automaticallyAfterDays])
    }

    func rotateSecretNow(profile: String, region: String, name: String) async throws -> SecretsManagerSecretDetail {
        try await post("/api/secretsmanager/secret/rotation/rotate-now", query: pq(profile, region), body: ["name": name])
    }

    func cancelSecretRotation(profile: String, region: String, name: String) async throws -> SecretsManagerSecretDetail {
        try await post("/api/secretsmanager/secret/rotation/cancel", query: pq(profile, region), body: ["name": name])
    }

    // MARK: - CloudFormation

    func getStacks(profile: String, region: String) async throws -> [CloudFormationStack] {
        try await get("/api/cloudformation/stacks", query: pq(profile, region))
    }

    func getStackDetail(profile: String, region: String, name: String) async throws -> CloudFormationStackDetail {
        var q = pq(profile, region)
        q["name"] = name
        return try await get("/api/cloudformation/stack", query: q)
    }

    func getStackEvents(profile: String, region: String, name: String) async throws -> [CloudFormationStackEvent] {
        var q = pq(profile, region)
        q["name"] = name
        return try await get("/api/cloudformation/stack/events", query: q)
    }

    func getStackResources(profile: String, region: String, name: String) async throws -> [CloudFormationStackResource] {
        var q = pq(profile, region)
        q["name"] = name
        return try await get("/api/cloudformation/stack/resources", query: q)
    }

    func getStackTemplate(profile: String, region: String, name: String) async throws -> String {
        var q = pq(profile, region)
        q["name"] = name
        let response: TemplateResponse = try await get("/api/cloudformation/stack/template", query: q)
        return response.templateBody
    }

    func setStackTerminationProtection(profile: String, region: String, name: String, enabled: Bool) async throws -> CloudFormationStackDetail {
        try await put("/api/cloudformation/stack/termination-protection", query: pq(profile, region), body: ["stackName": name, "enabled": enabled])
    }

    func deleteStack(profile: String, region: String, name: String) async throws {
        try await postRaw("/api/cloudformation/stack/delete", query: pq(profile, region), body: ["stackName": name])
    }

    // MARK: - Elastic Load Balancing

    func getLoadBalancers(profile: String, region: String) async throws -> [LoadBalancer] {
        try await get("/api/elasticloadbalancing/load-balancers", query: pq(profile, region))
    }

    private func elbQuery(_ profile: String, _ region: String, _ arn: String) -> [String: String] {
        var q = pq(profile, region)
        q["arn"] = arn
        return q
    }

    func getLoadBalancerDetail(profile: String, region: String, arn: String) async throws -> LoadBalancerDetail {
        try await get("/api/elasticloadbalancing/load-balancer", query: elbQuery(profile, region, arn))
    }

    func getLoadBalancerListeners(profile: String, region: String, arn: String) async throws -> [ElbListener] {
        try await get("/api/elasticloadbalancing/load-balancer/listeners", query: elbQuery(profile, region, arn))
    }

    func getLoadBalancerTargetGroups(profile: String, region: String, arn: String) async throws -> [ElbTargetGroup] {
        try await get("/api/elasticloadbalancing/load-balancer/target-groups", query: elbQuery(profile, region, arn))
    }

    func setLoadBalancerDeletionProtection(profile: String, region: String, arn: String, enabled: Bool) async throws -> LoadBalancerDetail {
        try await put("/api/elasticloadbalancing/load-balancer/deletion-protection", query: pq(profile, region), body: ["arn": arn, "enabled": enabled])
    }

    func addLoadBalancerTag(profile: String, region: String, arn: String, key: String, value: String) async throws -> LoadBalancerDetail {
        try await post("/api/elasticloadbalancing/load-balancer/tags", query: pq(profile, region), body: ["arn": arn, "key": key, "value": value])
    }

    func removeLoadBalancerTag(profile: String, region: String, arn: String, key: String) async throws -> LoadBalancerDetail {
        try await post("/api/elasticloadbalancing/load-balancer/tags/remove", query: pq(profile, region), body: ["arn": arn, "key": key])
    }

    // MARK: - API Gateway

    func getRestApis(profile: String, region: String) async throws -> [RestApi] {
        try await get("/api/apigateway/apis", query: pq(profile, region))
    }

    // MARK: API Gateway v2 (HTTP + WebSocket APIs)

    func getHttpApis(profile: String, region: String) async throws -> [HttpApi] {
        try await get("/api/apigatewayv2/apis", query: pq(profile, region))
    }

    func getHttpApiDetail(profile: String, region: String, apiId: String) async throws -> HttpApiDetail {
        try await get("/api/apigatewayv2/api", query: pq(profile, region).merging(["apiId": apiId]) { $1 })
    }

    func deployHttpApi(profile: String, region: String, apiId: String, stageName: String, description: String?) async throws -> HttpApiDetail {
        var body: [String: Any] = ["apiId": apiId, "stageName": stageName]
        if let description, !description.isEmpty { body["description"] = description }
        return try await post("/api/apigatewayv2/api/deploy", query: pq(profile, region), body: body)
    }

    func deleteHttpApi(profile: String, region: String, apiId: String) async throws {
        try await postRaw("/api/apigatewayv2/api/delete", query: pq(profile, region), body: ["apiId": apiId])
    }

    func addHttpApiTag(profile: String, region: String, apiId: String, key: String, value: String) async throws -> HttpApiDetail {
        try await post("/api/apigatewayv2/api/tags", query: pq(profile, region), body: ["apiId": apiId, "key": key, "value": value])
    }

    func removeHttpApiTag(profile: String, region: String, apiId: String, key: String) async throws -> HttpApiDetail {
        try await post("/api/apigatewayv2/api/tags/remove", query: pq(profile, region), body: ["apiId": apiId, "key": key])
    }

    func getApiGatewayResources(profile: String, region: String, apiId: String) async throws -> [ApiGatewayResource] {
        var q = pq(profile, region)
        q["apiId"] = apiId
        return try await get("/api/apigateway/resources", query: q)
    }

    func deleteApiGatewayResource(profile: String, region: String, apiId: String, resourceId: String) async throws {
        try await postRaw("/api/apigateway/resources/delete", query: pq(profile, region), body: ["apiId": apiId, "resourceId": resourceId])
    }

    func deleteApiGatewayMethod(profile: String, region: String, apiId: String, resourceId: String, httpMethod: String) async throws {
        try await postRaw("/api/apigateway/methods/delete", query: pq(profile, region), body: ["apiId": apiId, "resourceId": resourceId, "httpMethod": httpMethod])
    }

    func getApiGatewayStages(profile: String, region: String, apiId: String) async throws -> [ApiGatewayStage] {
        var q = pq(profile, region)
        q["apiId"] = apiId
        return try await get("/api/apigateway/stages", query: q)
    }

    func deployApiGateway(profile: String, region: String, apiId: String, stageName: String, description: String?) async throws -> [ApiGatewayStage] {
        var body: [String: Any] = ["apiId": apiId, "stageName": stageName]
        if let description { body["description"] = description }
        return try await post("/api/apigateway/deploy", query: pq(profile, region), body: body)
    }

    func deleteApiGatewayStage(profile: String, region: String, apiId: String, stageName: String) async throws {
        try await postRaw("/api/apigateway/stages/delete", query: pq(profile, region), body: ["apiId": apiId, "stageName": stageName])
    }

    func updateRestApi(profile: String, region: String, apiId: String, name: String?, description: String?) async throws -> RestApi {
        var body: [String: Any] = ["apiId": apiId]
        if let name { body["name"] = name }
        if let description { body["description"] = description }
        return try await put("/api/apigateway/api", query: pq(profile, region), body: body)
    }

    func deleteRestApi(profile: String, region: String, apiId: String) async throws {
        try await postRaw("/api/apigateway/api/delete", query: pq(profile, region), body: ["apiId": apiId])
    }

    // MARK: - SNS

    func getTopics(profile: String, region: String) async throws -> [SnsTopic] {
        try await get("/api/sns/topics", query: pq(profile, region))
    }

    private func snsQuery(_ profile: String, _ region: String, _ arn: String) -> [String: String] {
        var q = pq(profile, region)
        q["arn"] = arn
        return q
    }

    func createSnsTopic(profile: String, region: String, name: String, fifo: Bool, displayName: String?) async throws -> SnsTopic {
        var body: [String: Any] = ["name": name, "fifo": fifo]
        if let displayName, !displayName.isEmpty { body["displayName"] = displayName }
        return try await post("/api/sns/topics", query: pq(profile, region), body: body)
    }

    func getSnsTopicDetail(profile: String, region: String, arn: String) async throws -> SnsTopicDetail {
        try await get("/api/sns/topic", query: snsQuery(profile, region, arn))
    }

    func deleteSnsTopic(profile: String, region: String, arn: String) async throws {
        try await postRaw("/api/sns/topic/delete", query: pq(profile, region), body: ["arn": arn])
    }

    /// `attribute` is "Policy" (access policy) or "DeliveryPolicy".
    func getSnsTopicPolicy(profile: String, region: String, arn: String, attribute: String) async throws -> String? {
        var q = snsQuery(profile, region, arn)
        q["attribute"] = attribute
        let response: OptionalPolicyResponse = try await get("/api/sns/topic/policy", query: q)
        return response.policy
    }

    /// `attribute` is "DisplayName", "Policy" or "DeliveryPolicy".
    func setSnsTopicAttribute(profile: String, region: String, arn: String, attribute: String, value: String) async throws {
        try await putRaw("/api/sns/topic/attribute", query: pq(profile, region), body: ["arn": arn, "attribute": attribute, "value": value])
    }

    func getSnsSubscriptions(profile: String, region: String, arn: String) async throws -> [SnsSubscription] {
        try await get("/api/sns/topic/subscriptions", query: snsQuery(profile, region, arn))
    }

    func createSnsSubscription(profile: String, region: String, arn: String, protocol: String, endpoint: String) async throws {
        try await postRaw("/api/sns/topic/subscriptions", query: pq(profile, region), body: ["arn": arn, "protocol": `protocol`, "endpoint": endpoint])
    }

    func deleteSnsSubscription(profile: String, region: String, subscriptionArn: String) async throws {
        try await postRaw("/api/sns/subscriptions/delete", query: pq(profile, region), body: ["subscriptionArn": subscriptionArn])
    }

    func publishSnsMessage(profile: String, region: String, arn: String, message: String, subject: String?, messageGroupId: String?, messageDeduplicationId: String?) async throws -> String? {
        var body: [String: Any] = ["arn": arn, "message": message]
        if let subject, !subject.isEmpty { body["subject"] = subject }
        if let messageGroupId, !messageGroupId.isEmpty { body["messageGroupId"] = messageGroupId }
        if let messageDeduplicationId, !messageDeduplicationId.isEmpty { body["messageDeduplicationId"] = messageDeduplicationId }
        let response: SendMessageResponse = try await post("/api/sns/topic/publish", query: pq(profile, region), body: body)
        return response.messageId
    }

    func addSnsTopicTag(profile: String, region: String, arn: String, key: String, value: String) async throws -> SnsTopicDetail {
        try await post("/api/sns/topic/tags", query: pq(profile, region), body: ["arn": arn, "key": key, "value": value])
    }

    func removeSnsTopicTag(profile: String, region: String, arn: String, key: String) async throws -> SnsTopicDetail {
        try await post("/api/sns/topic/tags/remove", query: pq(profile, region), body: ["arn": arn, "key": key])
    }

    // MARK: - ECR

    func getEcrRepositories(profile: String, region: String) async throws -> [EcrRepository] {
        try await get("/api/ecr/repositories", query: pq(profile, region))
    }

    private func ecrQuery(_ profile: String, _ region: String, _ name: String) -> [String: String] {
        var q = pq(profile, region)
        q["name"] = name
        return q
    }

    func getEcrRepositoryDetail(profile: String, region: String, name: String) async throws -> EcrRepositoryDetail {
        try await get("/api/ecr/repository", query: ecrQuery(profile, region, name))
    }

    func getEcrImages(profile: String, region: String, name: String, nextToken: String?) async throws -> EcrImagePage {
        var q = ecrQuery(profile, region, name)
        if let nextToken { q["nextToken"] = nextToken }
        return try await get("/api/ecr/repository/images", query: q)
    }

    func getEcrScanFindings(profile: String, region: String, name: String, digest: String) async throws -> EcrScanFindings {
        var q = ecrQuery(profile, region, name)
        q["digest"] = digest
        return try await get("/api/ecr/repository/image/findings", query: q)
    }

    func startEcrImageScan(profile: String, region: String, name: String, digest: String) async throws {
        try await postRaw("/api/ecr/repository/image/scan", query: pq(profile, region), body: ["name": name, "digest": digest])
    }

    func deleteEcrImage(profile: String, region: String, name: String, digest: String) async throws {
        try await postRaw("/api/ecr/repository/image/delete", query: pq(profile, region), body: ["name": name, "digest": digest])
    }

    /// `kind` is "lifecycle-policy" or "policy" (repository permissions).
    func getEcrPolicy(profile: String, region: String, name: String, kind: String) async throws -> String? {
        let response: OptionalPolicyResponse = try await get("/api/ecr/repository/\(kind)", query: ecrQuery(profile, region, name))
        return response.policy
    }

    func putEcrPolicy(profile: String, region: String, name: String, kind: String, policy: String) async throws {
        try await putRaw("/api/ecr/repository/\(kind)", query: pq(profile, region), body: ["name": name, "policy": policy])
    }

    func deleteEcrPolicy(profile: String, region: String, name: String, kind: String) async throws {
        try await postRaw("/api/ecr/repository/\(kind)/delete", query: pq(profile, region), body: ["name": name])
    }

    func setEcrTagMutability(profile: String, region: String, name: String, immutable: Bool) async throws -> EcrRepositoryDetail {
        try await put("/api/ecr/repository/tag-mutability", query: pq(profile, region), body: ["name": name, "mutability": immutable ? "IMMUTABLE" : "MUTABLE"])
    }

    func setEcrScanOnPush(profile: String, region: String, name: String, enabled: Bool) async throws -> EcrRepositoryDetail {
        try await put("/api/ecr/repository/scan-on-push", query: pq(profile, region), body: ["name": name, "enabled": enabled])
    }

    func addEcrRepositoryTag(profile: String, region: String, name: String, arn: String, key: String, value: String) async throws -> EcrRepositoryDetail {
        try await post("/api/ecr/repository/tags", query: pq(profile, region), body: ["name": name, "arn": arn, "key": key, "value": value])
    }

    func removeEcrRepositoryTag(profile: String, region: String, name: String, arn: String, key: String) async throws -> EcrRepositoryDetail {
        try await post("/api/ecr/repository/tags/remove", query: pq(profile, region), body: ["name": name, "arn": arn, "key": key])
    }

    // MARK: - KMS

    func getKmsKeys(profile: String, region: String) async throws -> [KmsKey] {
        try await get("/api/kms/keys", query: pq(profile, region))
    }

    func getKmsKeyDetail(profile: String, region: String, keyId: String) async throws -> KmsKeyDetail {
        var q = pq(profile, region)
        q["keyId"] = keyId
        return try await get("/api/kms/key", query: q)
    }

    func getKmsKeyPolicy(profile: String, region: String, keyId: String) async throws -> String {
        var q = pq(profile, region)
        q["keyId"] = keyId
        let response: PolicyResponse = try await get("/api/kms/key/policy", query: q)
        return response.policy
    }

    func updateKmsKeyPolicy(profile: String, region: String, keyId: String, policy: String) async throws {
        let _: OkResponse = try await put("/api/kms/key/policy", query: pq(profile, region), body: ["keyId": keyId, "policy": policy])
    }

    func setKmsKeyEnabled(profile: String, region: String, keyId: String, enabled: Bool) async throws -> KmsKeyDetail {
        try await put("/api/kms/key/enabled", query: pq(profile, region), body: ["keyId": keyId, "enabled": enabled])
    }

    func setKmsKeyRotation(profile: String, region: String, keyId: String, enabled: Bool, rotationPeriodInDays: Int? = nil) async throws -> KmsKeyDetail {
        var body: [String: Any] = ["keyId": keyId, "enabled": enabled]
        if let rotationPeriodInDays { body["rotationPeriodInDays"] = rotationPeriodInDays }
        return try await put("/api/kms/key/rotation", query: pq(profile, region), body: body)
    }

    func scheduleKmsKeyDeletion(profile: String, region: String, keyId: String, pendingWindowInDays: Int) async throws -> KmsKeyDetail {
        try await post("/api/kms/key/deletion", query: pq(profile, region), body: ["keyId": keyId, "pendingWindowInDays": pendingWindowInDays])
    }

    func cancelKmsKeyDeletion(profile: String, region: String, keyId: String) async throws -> KmsKeyDetail {
        try await post("/api/kms/key/deletion/cancel", query: pq(profile, region), body: ["keyId": keyId])
    }

    func addKmsAlias(profile: String, region: String, keyId: String, aliasName: String) async throws -> KmsKeyDetail {
        try await post("/api/kms/key/aliases", query: pq(profile, region), body: ["keyId": keyId, "aliasName": aliasName])
    }

    func removeKmsAlias(profile: String, region: String, keyId: String, aliasName: String) async throws -> KmsKeyDetail {
        try await post("/api/kms/key/aliases/remove", query: pq(profile, region), body: ["keyId": keyId, "aliasName": aliasName])
    }

    func addKmsTag(profile: String, region: String, keyId: String, key: String, value: String) async throws -> KmsKeyDetail {
        try await post("/api/kms/key/tags", query: pq(profile, region), body: ["keyId": keyId, "key": key, "value": value])
    }

    func removeKmsTag(profile: String, region: String, keyId: String, key: String) async throws -> KmsKeyDetail {
        try await post("/api/kms/key/tags/remove", query: pq(profile, region), body: ["keyId": keyId, "key": key])
    }

    // MARK: - Health Check

    func healthCheck() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/config") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - Supporting Types

struct SSOStatus: Decodable {
    let loggedIn: Bool
    let expiresAt: String?
    let startUrl: String?
    let region: String?
    let sessionName: String?
    let loginTime: String?
    let profiles: [DiscoveredProfile]?
    let ssoSessions: [SSOSessionInfo]?
}

struct DiscoveredProfile: Decodable {
    let name: String
    let region: String?
}

struct SSOSessionInfo: Decodable {
    let name: String
    let sso_start_url: String
    let sso_region: String
}

struct LoginResponse: Decodable {
    let success: Bool
    let command: String?
    let startUrl: String?
}

struct SendMessageResponse: Decodable {
    let messageId: String?
}

struct OkResponse: Decodable {
    let ok: Bool
}

struct PolicyResponse: Decodable {
    let policy: String
}

struct TemplateResponse: Decodable {
    let templateBody: String
}

struct LocalPathResponse: Decodable {
    let path: String
}

struct ProfileCheckResponse: Decodable {
    let total: Int
    let valid: Int
    let profiles: [ProfileCheckResult]
}

// MARK: - Error

enum APIError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server"
        case .httpError(400, let body) where ValidationFailure.from(body: body) != nil:
            return AppLanguage.current.validationMessage(ValidationFailure.from(body: body)!)
        case .httpError(_, let body) where CardInputFailure.from(body: body) != nil:
            return CardInputFailure.from(body: body)!.text(AppLanguage.current)
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        }
    }

    /// The session itself was rejected (expired / invalid credentials).
    /// 403 is a missing IAM permission and 503 throttling / network trouble
    /// on the sidecar's side - neither means "log in again", so neither
    /// triggers the "AWS Session Expired" notification any more.
    var isNotAuthorized: Bool {
        if case .httpError(let code, _) = self {
            return code == 401
        }
        return false
    }
}

extension Error {
    /// A cancelled request: Swift's `CancellationError`, or URLSession's
    /// `URLError(.cancelled)` that an in-flight request throws when its task
    /// is cancelled (a SwiftUI `.task(id:)` restarting). Not a failure to show.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        return Task.isCancelled
    }

    /// "Not Authorized" for permission/auth failures, otherwise the normal
    /// localized description - so callers never have to show a raw AWS
    /// error string for something the user simply doesn't have access to.
    var friendlyMessage: String {
        if let apiError = self as? APIError {
            if apiError.isNotAuthorized { return "Not Authorized" }
            if case .httpError(403, _) = apiError { return "Not Authorized - this role is missing the permission" }
            if case .httpError(503, _) = apiError { return "AWS is throttling or not reachable right now - try again in a moment" }
        }
        return localizedDescription
    }
}

/// A card's input problem from the sidecar (`type: "CardInput"`), in both languages.
struct CardInputFailure: Decodable {
    let type: String
    let text: LocalizedText

    static func from(body: String) -> CardInputFailure? {
        guard let data = body.data(using: .utf8), let failure = try? JSONDecoder().decode(CardInputFailure.self, from: data), failure.type == "CardInput" else { return nil }
        return failure
    }
}
