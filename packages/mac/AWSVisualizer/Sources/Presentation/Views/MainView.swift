import SwiftUI
import AppKit

struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.colorScheme) private var colorScheme
    @State private var showProfilePopover = false
    @State private var isSidebarCollapsed = false
    @State private var isTerminalCollapsed = true
    @State private var showSettings = false
    @State private var terminalExpandedWidth: CGFloat = 480
    @State private var terminalDragStartWidth: CGFloat?
    /// Declared by the screen on display (`ScreenTitle`), shown in the window's title bar.
    @State private var screenTitle: String?

    private let sidebarWidth: CGFloat = 220
    private let collapsedSidebarWidth: CGFloat = 56
    private let collapsedTerminalWidth: CGFloat = 32
    private let terminalMinWidth: CGFloat = 320
    private let terminalMaxWidth: CGFloat = 900

    var body: some View {
        @Bindable var state = appState
        HStack(spacing: 0) {
            SidebarView(isCollapsed: $isSidebarCollapsed, collapsedWidth: collapsedSidebarWidth, expandedWidth: sidebarWidth)
            Divider()
            VStack(spacing: 0) {
                if let profile = appState.currentProfileInfo, !profile.isValid {
                    ExpiredProfileBanner(profile: profile)
                    Divider()
                }
                if appState.maxTabs > 1 || appState.tabs.count > 1 {
                    TabBarView()
                    Divider()
                }
                detailView
                    .id(appState.activeTabID)
                    .onPreferenceChange(ScreenTitleKey.self) { screenTitle = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.contentBackground(colorScheme))
            }
            let devTools = DevToolCatalog.enabled(in: appState.devTools)
            if !devTools.isEmpty {
                devToolsDivider
                DevToolsPanelView(
                    isCollapsed: $isTerminalCollapsed,
                    collapsedWidth: collapsedTerminalWidth,
                    expandedWidth: terminalExpandedWidth,
                    tools: devTools
                )
                .id(devTools.map(\.id).joined(separator: ","))
            }
        }
        // Re-check which profiles are signed in when the app comes back to
        // the front (the user may have run `aws sso login` elsewhere) and
        // when any request is rejected as unauthorized. Both are debounced
        // in `refreshProfiles` - this is not a background poll.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await appState.refreshProfiles(using: api) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .awsRequestNotAuthorized)) { _ in
            Task { await appState.refreshProfiles(using: api) }
        }
        .navigationTitle(windowTitle)
        .animation(.easeInOut(duration: 0.2), value: isSidebarCollapsed)
        .animation(.easeInOut(duration: 0.2), value: isTerminalCollapsed)
        .alert(
            appState.language.tabLimitWarningTitle,
            isPresented: $state.tabLimitWarningVisible
        ) {
            Button(appState.language.okButtonTitle) {}
        } message: {
            Text(appState.language.tabLimitWarningMessage(maxTabs: appState.maxTabs))
        }
        .task {
            // First launch: nothing selected yet - Settings › Services opens
            // with the implemented services preselected.
            if appState.needsServiceSelection { appState.requestedSettingsPage = .services }
        }
        .onChange(of: appState.requestedSettingsPage) { _, page in
            if page != nil { showSettings = true }
        }
        .sheet(isPresented: $showSettings, onDismiss: { appState.requestedSettingsPage = nil }) {
            SettingsView(initialPage: appState.requestedSettingsPage ?? .general)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Profile", selection: $state.currentProfile) {
                    ForEach(appState.profiles) { p in
                        Text(p.pickerLabel).tag(p.name)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 70, maxWidth: 150)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showProfilePopover.toggle()
                } label: {
                    // `.resizable()` + an explicit frame sizes the glyph to
                    // exactly 24x24 - sizing it via `.font(size:)` instead
                    // (as before) reserves the font's full line height
                    // (ascender+descender) around the glyph, which reads as
                    // unwanted vertical padding above/below the icon.
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showProfilePopover) {
                    ProfilePopover(onOpenSettings: {
                        showProfilePopover = false
                        showSettings = true
                    })
                }
            }
        }
    }

    /// Divider between the main content and the Dev Tools panel. Collapsed,
    /// it's a plain fixed divider (no resize affordance - collapsed width is
    /// intentionally not adjustable); expanded, it doubles as a drag handle
    /// that adjusts `terminalExpandedWidth`, mirroring the drag pattern in
    /// `ResizableSplitView` but mirrored (dragging left grows the panel,
    /// since the panel sits to the right of this divider).
    @ViewBuilder
    private var devToolsDivider: some View {
        if isTerminalCollapsed {
            Divider()
        } else {
            Divider()
                .overlay(
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            // `.global` coordinate space - see
                            // `DataGridColumnResizeHandle`'s doc comment in
                            // DataGridView.swift for why the default
                            // `.local` space causes jitter on a divider
                            // whose own position moves with the width it's
                            // dragging.
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    let base = terminalDragStartWidth ?? terminalExpandedWidth
                                    if terminalDragStartWidth == nil { terminalDragStartWidth = terminalExpandedWidth }
                                    let proposed = base - value.translation.width
                                    terminalExpandedWidth = min(max(proposed, terminalMinWidth), terminalMaxWidth)
                                }
                                .onEnded { _ in
                                    terminalDragStartWidth = nil
                                }
                        )
                )
        }
    }

    /// The header shows which screen this is - the screen's own title, or
    /// the service's catalog name for screens that don't declare one.
    private var windowTitle: String {
        if let screenTitle, !screenTitle.isEmpty { return screenTitle }
        if appState.selectedService == dashboardServiceID { return "Dashboard" }
        return appState.serviceCatalog.first { $0.id == appState.selectedService }?.name ?? "AWS Manager"
    }

    @ViewBuilder
    private var detailView: some View {
        if appState.selectedService == dashboardServiceID {
            DashboardView()
        } else if let entry = appState.serviceCatalog.first(where: { $0.id == appState.selectedService }), entry.needsPackageInstall {
            ServicePackageMissingView(entry: entry)
        } else if let screen = ServiceScreen(rawValue: appState.selectedService) {
            implementedView(for: screen)
        } else {
            ServiceComingSoonView(entry: appState.serviceCatalog.first { $0.id == appState.selectedService })
        }
    }

    @ViewBuilder
    private func implementedView(for screen: ServiceScreen) -> some View {
        switch screen {
        case .elasticbeanstalk:
            EnvironmentsView()
        case .lambda:
            LambdaView()
        case .ec2:
            EC2View()
        case .ecs:
            ECSView()
        case .rds:
            RDSView()
        case .dynamodb:
            DynamoDBView()
        case .s3:
            S3View()
        case .sqs:
            SQSView()
        case .cloudwatch:
            CloudWatchView()
        case .cloudfront:
            CloudFrontView()
        case .route53:
            Route53View()
        case .codecommit:
            CodeCommitView()
        case .secretsmanager:
            SecretsManagerView()
        case .cloudformation:
            CloudFormationView()
        case .elasticloadbalancing:
            ElasticLoadBalancingView()
        case .apigateway:
            ApiGatewayView()
        case .sns:
            SnsView()
        case .ecr:
            EcrView()
        case .kms:
            KmsView()
        case .lightsail:
            LightsailView()
        case .batch:
            BatchView()
        case .autoscaling:
            AutoScalingView()
        case .outposts:
            OutpostsView()
        case .serverlessapplicationrepository:
            ServerlessRepoView()
        case .wavelength:
            EdgeZonesView(kind: .wavelength).id("wavelength")
        case .localzones:
            EdgeZonesView(kind: .local).id("localzones")
        case .nitroenclaves:
            NitroEnclavesView()
        case .eks:
            EksView()
        case .fargate:
            FargateView()
        case .apprunner:
            AppRunnerView()
        case .efs:
            EfsView()
        case .fsx:
            FsxView()
        case .ebs:
            EbsView()
        case .s3glacier:
            GlacierView()
        case .storagegateway:
            StorageGatewayView()
        case .backup:
            BackupView()
        case .elasticache:
            ResourcePageServiceView(service: "elasticache", title: "ElastiCache", emptyMessage: "No ElastiCache clusters or serverless caches in this region", noun: "cache")
        case .redshift:
            ResourcePageServiceView(service: "redshift", title: "Redshift", emptyMessage: "No Redshift clusters or serverless workgroups in this region", noun: "cluster")
        case .neptune:
            ResourcePageServiceView(service: "neptune", title: "Neptune", emptyMessage: "No Neptune clusters in this region", noun: "cluster")
        case .documentdb:
            ResourcePageServiceView(service: "documentdb", title: "DocumentDB", emptyMessage: "No DocumentDB clusters in this region", noun: "cluster")
        case .keyspaces:
            ResourcePageServiceView(service: "keyspaces", title: "Keyspaces", emptyMessage: "No keyspaces in this region (system keyspaces are hidden)", noun: "keyspace or table")
        case .timestream:
            ResourcePageServiceView(service: "timestream", title: "Timestream", emptyMessage: "No Timestream databases in this region", noun: "database or table")
        case .qldb:
            ResourcePageServiceView(service: "qldb", title: "QLDB", emptyMessage: "No QLDB ledgers in this region", noun: "ledger")
        case .memorydb:
            ResourcePageServiceView(service: "memorydb", title: "MemoryDB", emptyMessage: "No MemoryDB clusters in this region", noun: "cluster")
        case .rdsProxy:
            ResourcePageServiceView(service: "rds-proxy", title: "RDS Proxy", emptyMessage: "No RDS proxies in this region", noun: "proxy")
        case .dms:
            ResourcePageServiceView(service: "dms", title: "Database Migration Service", emptyMessage: "No DMS tasks, replication instances or endpoints in this region", noun: "resource")
        case .vpc:
            ResourcePageServiceView(service: "vpc", title: "VPC", emptyMessage: "No VPCs in this region", noun: "VPC or security group")
        case .directconnect:
            ResourcePageServiceView(service: "directconnect", title: "Direct Connect", emptyMessage: "No Direct Connect connections, virtual interfaces or gateways", noun: "resource")
        case .globalaccelerator:
            ResourcePageServiceView(service: "globalaccelerator", title: "Global Accelerator", emptyMessage: "No accelerators (Global Accelerator is global - the region selector doesn't apply)", noun: "accelerator")
        case .privatelink:
            ResourcePageServiceView(service: "privatelink", title: "PrivateLink", emptyMessage: "No VPC endpoints or endpoint services in this region", noun: "endpoint")
        case .transitgateway:
            ResourcePageServiceView(service: "transitgateway", title: "Transit Gateway", emptyMessage: "No transit gateways in this region", noun: "transit gateway")
        case .cloudmap:
            ResourcePageServiceView(service: "cloudmap", title: "Cloud Map", emptyMessage: "No Cloud Map namespaces in this region", noun: "namespace or service")
        case .appmesh:
            ResourcePageServiceView(service: "appmesh", title: "App Mesh", emptyMessage: "No meshes in this region", noun: "mesh")
        case .vpnclient:
            ResourcePageServiceView(service: "vpnclient", title: "Client VPN", emptyMessage: "No Client VPN endpoints in this region", noun: "endpoint")
        case .iam:
            ResourcePageServiceView(service: "iam", title: "IAM", emptyMessage: "No IAM users, roles, groups or customer managed policies (IAM is global)", noun: "user, role, group or policy")
        case .cognito:
            ResourcePageServiceView(service: "cognito", title: "Cognito", emptyMessage: "No user pools or identity pools in this region", noun: "pool")
        case .guardduty:
            ResourcePageServiceView(service: "guardduty", title: "GuardDuty", emptyMessage: "GuardDuty is not enabled in this region", noun: "detector")
        case .inspector:
            ResourcePageServiceView(service: "inspector", title: "Inspector", emptyMessage: "Inspector status unavailable in this region", noun: "page")
        case .securityhub:
            ResourcePageServiceView(service: "securityhub", title: "Security Hub", emptyMessage: "Security Hub is not enabled in this region", noun: "page")
        case .waf:
            ResourcePageServiceView(service: "waf", title: "WAF & Shield", emptyMessage: "No web ACLs, rule groups or IP sets", noun: "resource")
        case .acm:
            ResourcePageServiceView(service: "acm", title: "Certificate Manager", emptyMessage: "No certificates in this region (CloudFront certificates live in us-east-1)", noun: "certificate")
        case .macie:
            ResourcePageServiceView(service: "macie", title: "Macie", emptyMessage: "Macie is not enabled in this region", noun: "page or job")
        case .directoryservice:
            ResourcePageServiceView(service: "directoryservice", title: "Directory Service", emptyMessage: "No directories in this region", noun: "directory")
        case .artifact:
            ResourcePageServiceView(service: "artifact", title: "Artifact", emptyMessage: "No AWS Artifact reports available", noun: "report")
        case .firewallmanager:
            ResourcePageServiceView(service: "firewallmanager", title: "Firewall Manager", emptyMessage: "Firewall Manager is not set up for this account", noun: "policy")
        case .detective:
            ResourcePageServiceView(service: "detective", title: "Detective", emptyMessage: "Detective is not enabled in this region", noun: "behavior graph")
        case .identityCenter:
            ResourcePageServiceView(service: "iam-identitycenter", title: "IAM Identity Center", emptyMessage: "No Identity Center instance in this region (it lives in its home region only)", noun: "permission set")
        case .networkfirewall:
            ResourcePageServiceView(service: "networkfirewall", title: "Network Firewall", emptyMessage: "No firewalls, firewall policies or rule groups in this region", noun: "resource")
        case .verifiedaccess:
            ResourcePageServiceView(service: "verifiedaccess", title: "Verified Access", emptyMessage: "No Verified Access instances in this region", noun: "resource")
        case .resourceaccessmanager:
            ResourcePageServiceView(service: "resourceaccessmanager", title: "Resource Access Manager", emptyMessage: "No resource shares in this region", noun: "resource share")
        case .cloudtrail:
            ResourcePageServiceView(service: "cloudtrail", title: "CloudTrail", emptyMessage: "No trails or event data stores in this region", noun: "trail")
        case .config:
            ResourcePageServiceView(service: "config", title: "Config", emptyMessage: "AWS Config is not set up in this region", noun: "rule or pack")
        case .systemsmanager:
            ResourcePageServiceView(service: "systemsmanager", title: "Systems Manager", emptyMessage: "No managed nodes, parameters, documents or maintenance windows in this region", noun: "resource")
        case .organizations:
            ResourcePageServiceView(service: "organizations", title: "Organizations", emptyMessage: "This account is not part of an organization", noun: "account, OU or policy")
        case .controltower:
            ResourcePageServiceView(service: "controltower", title: "Control Tower", emptyMessage: "Control Tower is not set up here (it only answers in its home region)", noun: "control")
        case .trustedadvisor:
            ResourcePageServiceView(service: "trustedadvisor", title: "Trusted Advisor", emptyMessage: "No recommendations (the Trusted Advisor API needs a Business or Enterprise support plan)", noun: "recommendation")
        case .servicecatalog:
            ResourcePageServiceView(service: "servicecatalog", title: "Service Catalog", emptyMessage: "No portfolios, products or provisioned products in this region", noun: "portfolio or product")
        case .licensemanager:
            ResourcePageServiceView(service: "licensemanager", title: "License Manager", emptyMessage: "No license configurations or granted licenses in this region", noun: "license")
        case .computeoptimizer:
            ResourcePageServiceView(service: "computeoptimizer", title: "Compute Optimizer", emptyMessage: "Compute Optimizer status unavailable in this region", noun: "page")
        case .costexplorer:
            ResourcePageServiceView(service: "costexplorer", title: "Cost Explorer", emptyMessage: "Cost Explorer data unavailable", noun: "report")
        case .budgets:
            ResourcePageServiceView(service: "budgets", title: "Budgets", emptyMessage: "No budgets in this account", noun: "budget")
        case .healthdashboard:
            ResourcePageServiceView(service: "healthdashboard", title: "Health Dashboard", emptyMessage: "No events (the Health API needs a Business or Enterprise support plan)", noun: "event")
        case .wellarchitectedtool:
            ResourcePageServiceView(service: "wellarchitectedtool", title: "Well-Architected Tool", emptyMessage: "No workloads in this region", noun: "workload")
        case .resourcegroups:
            ResourcePageServiceView(service: "resourcegroups", title: "Resource Groups & Tag Editor", emptyMessage: "No resource groups in this region", noun: "group")
        case .opsworks:
            ResourcePageServiceView(service: "opsworks", title: "OpsWorks", emptyMessage: "No OpsWorks stacks in this region", noun: "stack")
        case .launchwizard:
            ResourcePageServiceView(service: "launchwizard", title: "Launch Wizard", emptyMessage: "No Launch Wizard deployments in this region", noun: "deployment")
        case .codebuild:
            ResourcePageServiceView(service: "codebuild", title: "CodeBuild", emptyMessage: "No build projects in this region", noun: "project")
        case .codepipeline:
            ResourcePageServiceView(service: "codepipeline", title: "CodePipeline", emptyMessage: "No pipelines in this region", noun: "pipeline")
        case .codedeploy:
            ResourcePageServiceView(service: "codedeploy", title: "CodeDeploy", emptyMessage: "No CodeDeploy applications in this region", noun: "application")
        case .codeartifact:
            ResourcePageServiceView(service: "codeartifact", title: "CodeArtifact", emptyMessage: "No CodeArtifact domains or repositories in this region", noun: "repository")
        case .cloudshell:
            ResourcePageServiceView(service: "cloudshell", title: "CloudShell", emptyMessage: "CloudShell information unavailable", noun: "page")
        case .cloud9:
            ResourcePageServiceView(service: "cloud9", title: "Cloud9", emptyMessage: "No Cloud9 environments in this region", noun: "environment")
        case .xray:
            ResourcePageServiceView(service: "xray", title: "X-Ray", emptyMessage: "X-Ray is unavailable in this region", noun: "page")
        case .codestar:
            ResourcePageServiceView(service: "codestar", title: "CodeStar Connections", emptyMessage: "No connections, hosts or notification rules in this region", noun: "connection")
        case .codewhisperer:
            ResourcePageServiceView(service: "codewhisperer", title: "Amazon Q Developer", emptyMessage: "Q Developer information unavailable", noun: "page")
        case .codecatalyst:
            ResourcePageServiceView(service: "codecatalyst", title: "CodeCatalyst", emptyMessage: "CodeCatalyst information unavailable", noun: "page")
        case .athena:
            ResourcePageServiceView(service: "athena", title: "Athena", emptyMessage: "No workgroups in this region", noun: "workgroup")
        case .emr:
            ResourcePageServiceView(service: "emr", title: "EMR", emptyMessage: "No active EMR clusters or EMR Serverless applications in this region", noun: "cluster")
        case .kinesis:
            ResourcePageServiceView(service: "kinesis", title: "Kinesis", emptyMessage: "No data streams, Firehose streams or Flink applications in this region", noun: "stream")
        case .opensearch:
            ResourcePageServiceView(service: "opensearch", title: "OpenSearch Service", emptyMessage: "No OpenSearch domains or serverless collections in this region", noun: "domain")
        case .quicksight:
            ResourcePageServiceView(service: "quicksight", title: "QuickSight", emptyMessage: "QuickSight isn't set up for this account in this region", noun: "dashboard")
        case .glue:
            ResourcePageServiceView(service: "glue", title: "Glue", emptyMessage: "No Glue databases, crawlers, jobs or connections in this region", noun: "resource")
        case .datazone:
            ResourcePageServiceView(service: "datazone", title: "DataZone", emptyMessage: "No DataZone domains in this region", noun: "domain")
        case .lakeformation:
            ResourcePageServiceView(service: "lakeformation", title: "Lake Formation", emptyMessage: "Lake Formation is unavailable in this region", noun: "page")
        case .msk:
            ResourcePageServiceView(service: "msk", title: "Managed Streaming for Kafka", emptyMessage: "No MSK clusters in this region", noun: "cluster")
        case .datapipeline:
            ResourcePageServiceView(service: "datapipeline", title: "Data Pipeline", emptyMessage: "No pipelines in this region", noun: "pipeline")
        case .cloudsearch:
            ResourcePageServiceView(service: "cloudsearch", title: "CloudSearch", emptyMessage: "No CloudSearch domains in this region", noun: "domain")
        case .sagemaker:
            ResourcePageServiceView(service: "sagemaker", title: "SageMaker", emptyMessage: "No endpoints, notebooks, Studio domains, pipelines, training jobs or models in this region", noun: "resource")
        case .bedrock:
            ResourcePageServiceView(service: "bedrock", title: "Bedrock", emptyMessage: "Bedrock isn't available in this region", noun: "resource")
        case .rekognition:
            ResourcePageServiceView(service: "rekognition", title: "Rekognition", emptyMessage: "No face collections, stream processors or Custom Labels projects in this region", noun: "resource")
        case .comprehend:
            ResourcePageServiceView(service: "comprehend", title: "Comprehend", emptyMessage: "No custom classifiers, recognizers, endpoints or flywheels in this region", noun: "model")
        case .textract:
            ResourcePageServiceView(service: "textract", title: "Textract", emptyMessage: "Textract information unavailable in this region", noun: "page")
        case .polly:
            ResourcePageServiceView(service: "polly", title: "Polly", emptyMessage: "Polly is unavailable in this region", noun: "page")
        case .transcribe:
            ResourcePageServiceView(service: "transcribe", title: "Transcribe", emptyMessage: "Transcribe is unavailable in this region", noun: "resource")
        case .translate:
            ResourcePageServiceView(service: "translate", title: "Translate", emptyMessage: "Translate is unavailable in this region", noun: "resource")
        case .lex:
            ResourcePageServiceView(service: "lex", title: "Lex", emptyMessage: "No Lex V2 bots in this region", noun: "bot")
        case .personalize:
            ResourcePageServiceView(service: "personalize", title: "Personalize", emptyMessage: "No Personalize dataset groups in this region", noun: "dataset group")
        case .forecast:
            ResourcePageServiceView(service: "forecast", title: "Forecast", emptyMessage: "No Forecast dataset groups in this region", noun: "dataset group")
        case .kendra:
            ResourcePageServiceView(service: "kendra", title: "Kendra", emptyMessage: "No Kendra indexes in this region", noun: "index")
        case .amazonQ:
            ResourcePageServiceView(service: "q", title: "Amazon Q Business", emptyMessage: "No Amazon Q Business applications in this region", noun: "application")
        case .eventbridge:
            ResourcePageServiceView(service: "eventbridge", title: "EventBridge", emptyMessage: "No event buses, rules or schedules in this region", noun: "resource")
        case .stepfunctions:
            ResourcePageServiceView(service: "stepfunctions", title: "Step Functions", emptyMessage: "No state machines in this region", noun: "state machine")
        case .appflow:
            ResourcePageServiceView(service: "appflow", title: "AppFlow", emptyMessage: "No AppFlow flows in this region", noun: "flow")
        case .mq:
            ResourcePageServiceView(service: "mq", title: "Amazon MQ", emptyMessage: "No brokers in this region", noun: "broker")
        case .apppipes:
            ResourcePageServiceView(service: "apppipes", title: "EventBridge Pipes", emptyMessage: "No pipes in this region", noun: "pipe")
        case .migrationhub:
            ResourcePageServiceView(service: "migrationhub", title: "Migration Hub", emptyMessage: "No progress update streams (Migration Hub only answers in its home region)", noun: "stream")
        case .datasync:
            ResourcePageServiceView(service: "datasync", title: "DataSync", emptyMessage: "No DataSync tasks, locations or agents in this region", noun: "task")
        case .transferfamily:
            ResourcePageServiceView(service: "transferfamily", title: "Transfer Family", emptyMessage: "No Transfer Family servers, connectors or workflows in this region", noun: "server")
        case .applicationdiscoveryservice:
            ResourcePageServiceView(service: "applicationdiscoveryservice", title: "Application Discovery Service", emptyMessage: "Discovery isn't set up here (it only answers in the Migration Hub home region)", noun: "page")
        case .snowfamily:
            ResourcePageServiceView(service: "snowfamily", title: "Snow Family", emptyMessage: "No Snow jobs or clusters in this region", noun: "job")
        case .mgn:
            ResourcePageServiceView(service: "mgn", title: "Application Migration Service", emptyMessage: "MGN isn't initialized in this region", noun: "source server")
        case .elastictranscoder:
            ResourcePageServiceView(service: "elastictranscoder", title: "Elastic Transcoder", emptyMessage: "Elastic Transcoder information unavailable", noun: "page")
        case .mediaconvert:
            ResourcePageServiceView(service: "mediaconvert", title: "MediaConvert", emptyMessage: "No MediaConvert queues, templates or presets in this region", noun: "queue")
        case .medialive:
            ResourcePageServiceView(service: "medialive", title: "MediaLive", emptyMessage: "No MediaLive channels or inputs in this region", noun: "channel")
        case .mediapackage:
            ResourcePageServiceView(service: "mediapackage", title: "MediaPackage", emptyMessage: "No MediaPackage channels in this region", noun: "channel")
        case .mediastore:
            ResourcePageServiceView(service: "mediastore", title: "MediaStore", emptyMessage: "No MediaStore containers in this region (AWS has announced the end of MediaStore)", noun: "container")
        case .ivs:
            ResourcePageServiceView(service: "ivs", title: "Interactive Video Service", emptyMessage: "No IVS channels in this region", noun: "channel")
        case .iotcore:
            ResourcePageServiceView(service: "iotcore", title: "IoT Core", emptyMessage: "IoT Core is unavailable in this region", noun: "thing")
        case .iotanalytics:
            ResourcePageServiceView(service: "iotanalytics", title: "IoT Analytics", emptyMessage: "IoT Analytics information unavailable", noun: "page")
        case .iotgreengrass:
            ResourcePageServiceView(service: "iotgreengrass", title: "IoT Greengrass", emptyMessage: "No Greengrass core devices, deployments or components in this region", noun: "core device")
        case .iotdevicedefender:
            ResourcePageServiceView(service: "iotdevicedefender", title: "IoT Device Defender", emptyMessage: "Device Defender is unavailable in this region", noun: "page")
        case .iotsitewise:
            ResourcePageServiceView(service: "iotsitewise", title: "IoT SiteWise", emptyMessage: "No SiteWise asset models, assets, gateways or portals in this region", noun: "asset")
        case .workmail:
            ResourcePageServiceView(service: "workmail", title: "WorkMail", emptyMessage: "No WorkMail organizations in this region", noun: "organization")
        case .chime:
            ResourcePageServiceView(service: "chime", title: "Chime SDK Voice", emptyMessage: "No Voice Connectors, phone numbers or SIP media applications in this region", noun: "resource")
        case .connect:
            ResourcePageServiceView(service: "connect", title: "Amazon Connect", emptyMessage: "No Connect instances in this region", noun: "instance")
        case .pinpoint:
            ResourcePageServiceView(service: "pinpoint", title: "Pinpoint", emptyMessage: "Pinpoint information unavailable", noun: "page")
        case .ses:
            ResourcePageServiceView(service: "ses", title: "Simple Email Service", emptyMessage: "SES is unavailable in this region", noun: "identity")
        case .honeycode:
            ResourcePageServiceView(service: "honeycode", title: "Honeycode", emptyMessage: "Honeycode information unavailable", noun: "page")
        case .workspaces:
            ResourcePageServiceView(service: "workspaces", title: "WorkSpaces", emptyMessage: "No WorkSpaces or directories in this region", noun: "WorkSpace")
        case .appstream:
            ResourcePageServiceView(service: "appstream", title: "AppStream 2.0", emptyMessage: "No AppStream fleets or stacks in this region", noun: "fleet")
        case .worklink:
            ResourcePageServiceView(service: "worklink", title: "WorkLink", emptyMessage: "WorkLink information unavailable", noun: "page")
        case .amplify:
            ResourcePageServiceView(service: "amplify", title: "Amplify", emptyMessage: "No Amplify apps in this region", noun: "app")
        case .appsync:
            ResourcePageServiceView(service: "appsync", title: "AppSync", emptyMessage: "No GraphQL APIs in this region", noun: "API")
        case .devicefarm:
            ResourcePageServiceView(service: "devicefarm", title: "Device Farm", emptyMessage: "No Device Farm projects (Device Farm lives in us-west-2)", noun: "project")
        case .location:
            ResourcePageServiceView(service: "location", title: "Location Service", emptyMessage: "No maps, place indexes, trackers or geofences in this region", noun: "resource")
        case .managedblockchain:
            ResourcePageServiceView(service: "managedblockchain", title: "Managed Blockchain", emptyMessage: "No blockchain networks in this region", noun: "network")
        case .qldbBlockchain:
            ResourcePageServiceView(service: "qldb-blockchain", title: "Quantum Ledger Database", emptyMessage: "QLDB information unavailable", noun: "page")
        case .groundstation:
            ResourcePageServiceView(service: "groundstation", title: "Ground Station", emptyMessage: "Ground Station is unavailable in this region", noun: "mission profile")
        case .braket:
            ResourcePageServiceView(service: "braket", title: "Braket", emptyMessage: "Braket is unavailable in this region", noun: "device")
        case .robomaker:
            ResourcePageServiceView(service: "robomaker", title: "RoboMaker", emptyMessage: "RoboMaker information unavailable", noun: "page")
        case .gamelift:
            ResourcePageServiceView(service: "gamelift", title: "GameLift", emptyMessage: "No GameLift fleets, builds or queues in this region", noun: "fleet")
        }
    }
}
