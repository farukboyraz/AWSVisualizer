import Foundation

protocol APIServiceProtocol {
    // Status & Auth
    func getStatus() async throws -> SSOStatus
    func login(ssoSession: String?) async throws -> LoginResponse
    func logout() async throws
    func checkProfiles() async throws -> ProfileCheckResponse
    func getCallerIdentity(profile: String, region: String) async throws -> CallerIdentity
    func getAccessibleEnvironments() async throws -> [AccessibleEnvironment]
    func createProfile(name: String, ssoSessionName: String, accountId: String, roleName: String, region: String) async throws

    // Service Catalog
    func getServiceCatalog() async throws -> [AWSServiceCatalogEntry]
    func getSelectedServices() async throws -> [String]
    func setSelectedServices(_ services: [String]) async throws
    func getFavoriteServices() async throws -> [String]
    func setFavoriteServices(_ services: [String]) async throws
    func getServiceCounts(profile: String, region: String, services: [String], source: String?) async throws -> [String: Int?]

    // Cost
    func getCost(profile: String, view: DashboardPrefs.CostView, months: Int, month: String?, fresh: Bool) async throws -> AuthResponse<CostSummary>

    // Elastic Beanstalk
    func getEnvironments(profile: String, region: String) async throws -> [EBEnvironment]
    func getEvents(profile: String, region: String, environment: String) async throws -> [EbEvent]
    func getEbEnvironmentDetail(profile: String, region: String, environmentName: String) async throws -> EbEnvironmentDetail
    func restartEbAppServer(profile: String, region: String, environmentName: String) async throws
    func rebuildEbEnvironment(profile: String, region: String, environmentName: String) async throws
    func terminateEbEnvironment(profile: String, region: String, environmentName: String) async throws
    func swapEbEnvironmentCnames(profile: String, region: String, sourceEnvironmentName: String, destinationEnvironmentName: String) async throws
    func setEbEnvironmentVariable(profile: String, region: String, environmentName: String, key: String, value: String) async throws -> EbEnvironmentDetail
    func removeEbEnvironmentVariable(profile: String, region: String, environmentName: String, key: String) async throws -> EbEnvironmentDetail
    func addEbEnvironmentTag(profile: String, region: String, environmentName: String, environmentArn: String, key: String, value: String) async throws -> EbEnvironmentDetail
    func removeEbEnvironmentTag(profile: String, region: String, environmentName: String, environmentArn: String, key: String) async throws -> EbEnvironmentDetail
    func cloneEbEnvironment(profile: String, region: String, sourceEnvironmentName: String, newEnvironmentName: String, cnamePrefix: String?) async throws -> EbEnvironmentDetail

    // Lambda
    func getLambdaFunctions(profile: String, region: String) async throws -> AuthResponse<[LambdaFunction]>

    // EC2
    func getEC2Instances(profile: String, region: String) async throws -> AuthResponse<[Ec2Instance]>
    func getEc2InstanceDetail(profile: String, region: String, instanceId: String) async throws -> Ec2InstanceDetail
    func setEc2InstanceState(profile: String, region: String, instanceId: String, action: String) async throws
    func setEc2InstanceType(profile: String, region: String, instanceId: String, instanceType: String) async throws -> Ec2InstanceDetail
    func setEc2TerminationProtection(profile: String, region: String, instanceId: String, enabled: Bool) async throws -> Ec2InstanceDetail
    func setEc2Monitoring(profile: String, region: String, instanceId: String, enabled: Bool) async throws -> Ec2InstanceDetail
    func addEc2Tag(profile: String, region: String, instanceId: String, key: String, value: String) async throws -> Ec2InstanceDetail
    func removeEc2Tag(profile: String, region: String, instanceId: String, key: String) async throws -> Ec2InstanceDetail
    func getEc2KeyPairs(profile: String, region: String) async throws -> [Ec2KeyPair]
    func launchEc2Instance(profile: String, region: String, imageId: String, instanceType: String, keyName: String?, securityGroupIds: [String]?, subnetId: String?, name: String?) async throws -> Ec2InstanceDetail

    // ECS
    func getECSClusters(profile: String, region: String) async throws -> AuthResponse<[EcsCluster]>

    // RDS
    func getRDSInstances(profile: String, region: String) async throws -> AuthResponse<[RdsInstance]>

    // DynamoDB
    func getDynamoDBTables(profile: String, region: String) async throws -> [String]
    func getDynamoDBTable(profile: String, region: String, tableName: String) async throws -> DdbTableInfo
    func scanDynamoDBTable(profile: String, region: String, tableName: String, limit: Int, startKey: [String: Any]?) async throws -> DdbScanResult
    func putDynamoDBItem(profile: String, region: String, tableName: String, item: [String: Any]) async throws
    func deleteDynamoDBItem(profile: String, region: String, tableName: String, key: [String: Any]) async throws

    // S3
    func getS3Buckets(profile: String, region: String) async throws -> [S3Bucket]
    func getS3Objects(profile: String, region: String, bucket: String, prefix: String?) async throws -> S3Objects
    func searchS3Objects(profile: String, region: String, bucket: String, prefix: String?, query: String) async throws -> [S3Object]
    func getS3Object(profile: String, region: String, bucket: String, key: String) async throws -> S3FilePreview
    func downloadS3File(profile: String, region: String, bucket: String, key: String) async throws -> Data
    func getZipEntries(profile: String, region: String, bucket: String, key: String, path: [String]) async throws -> ZipEntryList
    func getZipEntryContent(profile: String, region: String, bucket: String, key: String, path: [String]) async throws -> ZipEntryContent

    // SQS
    func getSQSQueues(profile: String, region: String) async throws -> AuthResponse<[SqsQueue]>
    func getSQSQueueDetail(profile: String, region: String, queueUrl: String) async throws -> SqsQueueDetail
    func updateSQSQueueAttributes(profile: String, region: String, queueUrl: String, attributes: [String: String]) async throws -> SqsQueueDetail
    func sendSQSMessage(profile: String, region: String, queueUrl: String, body: String, delaySeconds: Int?, messageGroupId: String?, messageDeduplicationId: String?) async throws -> String?
    func receiveSQSMessages(profile: String, region: String, queueUrl: String, maxMessages: Int) async throws -> [SqsMessage]
    func deleteSQSMessage(profile: String, region: String, queueUrl: String, receiptHandle: String) async throws
    func addSQSTag(profile: String, region: String, queueUrl: String, key: String, value: String) async throws -> SqsQueueDetail
    func removeSQSTag(profile: String, region: String, queueUrl: String, key: String) async throws -> SqsQueueDetail

    // CloudWatch
    func getCloudWatchAlarms(profile: String, region: String) async throws -> AuthResponse<[CloudWatchAlarm]>
    func getLogGroups(profile: String, region: String) async throws -> AuthResponse<[LogGroup]>
    func getCloudWatchAlarmDetail(profile: String, region: String, alarmName: String) async throws -> CloudWatchAlarmDetail
    func updateCloudWatchAlarmThreshold(profile: String, region: String, alarmName: String, threshold: Double, comparisonOperator: String, evaluationPeriods: Int, period: Int) async throws -> CloudWatchAlarmDetail
    func setCloudWatchAlarmActionsEnabled(profile: String, region: String, alarmName: String, enabled: Bool) async throws -> CloudWatchAlarmDetail
    func deleteCloudWatchAlarm(profile: String, region: String, alarmName: String) async throws
    func getLogGroupStreams(profile: String, region: String, logGroupName: String) async throws -> [LogStreamInfo]
    func getLogGroupEvents(profile: String, region: String, logGroupName: String, logStreamName: String) async throws -> [LogEventInfo]
    func setLogGroupRetention(profile: String, region: String, logGroupName: String, retentionInDays: Int?) async throws
    func deleteLogGroup(profile: String, region: String, logGroupName: String) async throws

    // CloudFront
    func getCloudFrontDistributions(profile: String, region: String) async throws -> AuthResponse<[CloudFrontDistribution]>
    func getCloudFrontDistributionDetail(profile: String, region: String, id: String) async throws -> CloudFrontDistributionDetail
    func setCloudFrontDistributionEnabled(profile: String, region: String, id: String, enabled: Bool) async throws -> CloudFrontDistributionDetail
    func deleteCloudFrontDistribution(profile: String, region: String, id: String) async throws
    func addCloudFrontTag(profile: String, region: String, id: String, key: String, value: String) async throws -> CloudFrontDistributionDetail
    func removeCloudFrontTag(profile: String, region: String, id: String, key: String) async throws -> CloudFrontDistributionDetail

    // Route53
    func getHostedZones(profile: String, region: String) async throws -> AuthResponse<[HostedZone]>

    // CodeCommit
    func getCodeCommitRepositories(profile: String, region: String) async throws -> [CodeCommitRepository]
    func getCodeCommitRepositoryDetail(profile: String, region: String, name: String) async throws -> CodeCommitRepositoryDetail
    func getCodeCommitBranches(profile: String, region: String, name: String) async throws -> [CodeCommitBranch]
    func getCodeCommitFolder(profile: String, region: String, name: String, path: String, commit: String?) async throws -> CodeCommitFolderListing
    func getCodeCommitFile(profile: String, region: String, name: String, path: String, commit: String?) async throws -> CodeCommitFileContent
    func getCodeCommitCommits(profile: String, region: String, name: String, commit: String, limit: Int) async throws -> [CodeCommitCommit]
    func getCodeCommitCommitsForPath(profile: String, region: String, name: String, commit: String, path: String, cursor: String?, limit: Int) async throws -> CodeCommitPathHistoryPage
    func getCodeCommitPullRequests(profile: String, region: String, name: String, status: String) async throws -> [CodeCommitPullRequest]
    func createCodeCommitPullRequest(profile: String, region: String, repositoryName: String, title: String, description: String?, sourceReference: String, destinationReference: String) async throws -> CodeCommitPullRequest
    func getCodeCommitCommit(profile: String, region: String, name: String, commit: String) async throws -> CodeCommitCommit
    func getCodeCommitCommitsAhead(profile: String, region: String, name: String, source: String, destination: String) async throws -> [CodeCommitCommit]
    func getCodeCommitDifferences(profile: String, region: String, name: String, before: String?, after: String) async throws -> [CodeCommitDiffEntry]
    func getCodeCommitFileDiff(profile: String, region: String, name: String, path: String, before: String?, after: String, fullFile: Bool) async throws -> CodeCommitFileDiff
    func getCodeCommitPRLimits() async throws -> CodeCommitPRLimits
    func getCodeCommitPullRequest(profile: String, region: String, id: String) async throws -> CodeCommitPullRequest
    func checkCodeCommitMergeConflicts(profile: String, region: String, name: String, destination: String, source: String, mergeOption: CodeCommitMergeOption) async throws -> CodeCommitMergeCheck
    func mergeCodeCommitPullRequest(profile: String, region: String, repositoryName: String, pullRequestId: String, mergeOption: CodeCommitMergeOption, commitMessage: String?) async throws -> CodeCommitPullRequest
    func closeCodeCommitPullRequest(profile: String, region: String, pullRequestId: String) async throws -> CodeCommitPullRequest

    // CodeCommit - branch create/delete, direct merge
    func createCodeCommitBranch(profile: String, region: String, repositoryName: String, branchName: String, commitId: String) async throws
    func deleteCodeCommitBranch(profile: String, region: String, repositoryName: String, branchName: String) async throws
    func mergeCodeCommitBranches(profile: String, region: String, repositoryName: String, sourceBranch: String, destinationBranch: String, mergeOption: CodeCommitMergeOption, commitMessage: String?) async throws

    // CodeCommit - repository create/delete
    func createCodeCommitRepository(profile: String, region: String, repositoryName: String, description: String?) async throws
    func deleteCodeCommitRepository(profile: String, region: String, repositoryName: String) async throws

    // CodeCommit - pull request comments
    func getCodeCommitPullRequestComments(profile: String, region: String, pullRequestId: String, repositoryName: String?, beforeCommitId: String?, afterCommitId: String?) async throws -> [CodeCommitCommentThread]
    func postCodeCommitPullRequestComment(profile: String, region: String, pullRequestId: String, repositoryName: String, beforeCommitId: String, afterCommitId: String, content: String, filePath: String?, filePosition: Int?, relativeFileVersion: String?) async throws -> CodeCommitCommentThread
    func postCodeCommitCommentReply(profile: String, region: String, inReplyTo: String, content: String) async throws -> CodeCommitComment
    func deleteCodeCommitComment(profile: String, region: String, commentId: String) async throws

    // CodeCommit - pull request approvals
    func getCodeCommitPullRequestApprovals(profile: String, region: String, pullRequestId: String, revisionId: String) async throws -> [CodeCommitApproval]
    func setCodeCommitPullRequestApproval(profile: String, region: String, pullRequestId: String, revisionId: String, approved: Bool) async throws

    // CodeCommit - pull request activity timeline
    func getCodeCommitPullRequestEvents(profile: String, region: String, pullRequestId: String) async throws -> [CodeCommitPullRequestEvent]

    // CodeCommit - repository triggers
    func getCodeCommitTriggers(profile: String, region: String, repositoryName: String) async throws -> [CodeCommitRepositoryTrigger]
    func setCodeCommitTriggers(profile: String, region: String, repositoryName: String, triggers: [CodeCommitRepositoryTrigger]) async throws
    func testCodeCommitTriggers(profile: String, region: String, repositoryName: String, triggers: [CodeCommitRepositoryTrigger]) async throws -> [String]

    // CodeCommit - file edit / direct commit
    func putCodeCommitFile(profile: String, region: String, repositoryName: String, branchName: String, filePath: String, fileContent: String, commitMessage: String, parentCommitId: String?) async throws -> String
    func deleteCodeCommitFile(profile: String, region: String, repositoryName: String, branchName: String, filePath: String, commitMessage: String, parentCommitId: String) async throws -> String

    // CodeCommit - quick file switcher
    func searchCodeCommitFiles(profile: String, region: String, repositoryName: String, commitSpecifier: String, query: String, cursor: String?, limit: Int) async throws -> CodeCommitFileSearchPage

    // CodeCommit repository settings
    func updateCodeCommitRepositoryName(profile: String, region: String, oldName: String, newName: String) async throws -> CodeCommitRepositoryDetail
    func updateCodeCommitRepositoryDescription(profile: String, region: String, name: String, description: String) async throws -> CodeCommitRepositoryDetail
    func updateCodeCommitDefaultBranch(profile: String, region: String, name: String, defaultBranchName: String) async throws -> CodeCommitRepositoryDetail
    func addCodeCommitRepositoryTag(profile: String, region: String, name: String, key: String, value: String) async throws -> CodeCommitRepositoryDetail
    func removeCodeCommitRepositoryTag(profile: String, region: String, name: String, key: String) async throws -> CodeCommitRepositoryDetail

    // Workspace (local git clone: Clone/Pull/Push/Merge)
    func listWorkspaces() async throws -> [WorkspaceEntry]
    func getWorkspaceStatus(profile: String, region: String, name: String) async throws -> WorkspaceStatus
    func cloneWorkspace(profile: String, region: String, name: String, cloneUrl: String, parentDirectory: String) async throws -> GitCommandResult
    func matchWorkspace(profile: String, region: String, name: String, cloneUrl: String?, localPath: String) async throws -> MatchResult
    func getLocalWorkspaceDiffSummary(profile: String, region: String, name: String, branch: String) async throws -> [LocalDiffFile]
    func getLocalWorkspaceFileDiff(profile: String, region: String, name: String, branch: String, path: String, fullFile: Bool) async throws -> CodeCommitFileDiff
    func pullWorkspace(profile: String, region: String, name: String) async throws -> GitCommandResult
    func pushWorkspace(profile: String, region: String, name: String) async throws -> GitCommandResult
    func mergeIntoWorkspace(profile: String, region: String, name: String, branch: String) async throws -> GitCommandResult
    func forgetWorkspace(profile: String, region: String, name: String) async throws

    // App Config
    func getAppConfig() async throws -> AppConfig
    func getRawConfigFile() async throws -> String
    func updateDefaultRegion(_ region: String) async throws -> AppConfig
    func updateMaxTabs(_ maxTabs: Int) async throws -> AppConfig
    func updateDynamoDbAutoColumnWidth(_ enabled: Bool) async throws -> AppConfig
    func updateButtonColors(_ colors: ButtonColorConfig) async throws -> AppConfig

    // Secrets Manager
    func getSecrets(profile: String, region: String) async throws -> [SecretsManagerSecret]
    func getSecretDetail(profile: String, region: String, name: String) async throws -> SecretsManagerSecretDetail
    func updateSecretDescription(profile: String, region: String, name: String, description: String) async throws -> SecretsManagerSecretDetail
    func addSecretTag(profile: String, region: String, name: String, key: String, value: String) async throws -> SecretsManagerSecretDetail
    func removeSecretTag(profile: String, region: String, name: String, key: String) async throws -> SecretsManagerSecretDetail
    func deleteSecret(profile: String, region: String, name: String, recoveryWindowInDays: Int) async throws
    func restoreSecret(profile: String, region: String, name: String) async throws -> SecretsManagerSecretDetail
    func getSecretValue(profile: String, region: String, name: String) async throws -> SecretsManagerSecretValue

    // CloudFormation
    func getStacks(profile: String, region: String) async throws -> [CloudFormationStack]
    func getStackDetail(profile: String, region: String, name: String) async throws -> CloudFormationStackDetail
    func getStackEvents(profile: String, region: String, name: String) async throws -> [CloudFormationStackEvent]
    func getStackResources(profile: String, region: String, name: String) async throws -> [CloudFormationStackResource]
    func getStackTemplate(profile: String, region: String, name: String) async throws -> String
    func setStackTerminationProtection(profile: String, region: String, name: String, enabled: Bool) async throws -> CloudFormationStackDetail
    func deleteStack(profile: String, region: String, name: String) async throws

    // Elastic Load Balancing
    func getLoadBalancers(profile: String, region: String) async throws -> [LoadBalancer]

    // API Gateway
    func getRestApis(profile: String, region: String) async throws -> [RestApi]
    func getApiGatewayResources(profile: String, region: String, apiId: String) async throws -> [ApiGatewayResource]
    func deleteApiGatewayResource(profile: String, region: String, apiId: String, resourceId: String) async throws
    func deleteApiGatewayMethod(profile: String, region: String, apiId: String, resourceId: String, httpMethod: String) async throws
    func getApiGatewayStages(profile: String, region: String, apiId: String) async throws -> [ApiGatewayStage]
    func deployApiGateway(profile: String, region: String, apiId: String, stageName: String, description: String?) async throws -> [ApiGatewayStage]
    func deleteApiGatewayStage(profile: String, region: String, apiId: String, stageName: String) async throws
    func updateRestApi(profile: String, region: String, apiId: String, name: String?, description: String?) async throws -> RestApi
    func deleteRestApi(profile: String, region: String, apiId: String) async throws

    // SNS
    func getTopics(profile: String, region: String) async throws -> [SnsTopic]

    // ECR
    func getEcrRepositories(profile: String, region: String) async throws -> [EcrRepository]

    // KMS
    func getKmsKeys(profile: String, region: String) async throws -> [KmsKey]
    func getKmsKeyDetail(profile: String, region: String, keyId: String) async throws -> KmsKeyDetail
    func getKmsKeyPolicy(profile: String, region: String, keyId: String) async throws -> String
    func updateKmsKeyPolicy(profile: String, region: String, keyId: String, policy: String) async throws
    func setKmsKeyEnabled(profile: String, region: String, keyId: String, enabled: Bool) async throws -> KmsKeyDetail
    func setKmsKeyRotation(profile: String, region: String, keyId: String, enabled: Bool, rotationPeriodInDays: Int?) async throws -> KmsKeyDetail
    func addKmsAlias(profile: String, region: String, keyId: String, aliasName: String) async throws -> KmsKeyDetail
    func removeKmsAlias(profile: String, region: String, keyId: String, aliasName: String) async throws -> KmsKeyDetail
    func addKmsTag(profile: String, region: String, keyId: String, key: String, value: String) async throws -> KmsKeyDetail
    func removeKmsTag(profile: String, region: String, keyId: String, key: String) async throws -> KmsKeyDetail

    // Health
    func healthCheck() async -> Bool
}
