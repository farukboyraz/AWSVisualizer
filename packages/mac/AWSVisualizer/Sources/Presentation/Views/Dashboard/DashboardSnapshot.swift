import SwiftUI
import AppKit

/// Developer aid: `AWSVIS_DASHBOARD_SNAPSHOT=<folder>` renders the dashboard
/// with sample data (no sidecar, no AWS) to PNGs - light/dark × EN/TR, wide
/// and narrow - and quits. Lets a layout change be checked without screen
/// recording permission or a signed-in account.
enum DashboardSnapshot {
    @MainActor static func runIfRequested() {
        guard let folder = ProcessInfo.processInfo.environment["AWSVIS_DASHBOARD_SNAPSHOT"], !folder.isEmpty else { return }
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = DashboardModel.sample(entries: sampleEntries)
        var withCards = DashboardPrefs.defaults
        withCards.cards = [
            DashboardCard(id: "c1", title: "Raporlar", service: "s3", template: "s3.folderStats", kind: .metric, icon: "folder.fill", profiles: ["sample-profile"], params: ["bucket": "acme-reports", "prefix": "monthly/2026/"]),
            DashboardCard(id: "c2", title: "Açık siparişler", service: "dynamodb", template: "dynamodb.search", kind: .metric, icon: "line.3.horizontal.decrease.circle.fill", profiles: ["sample-profile"], params: ["table": "Orders", "search": #"{"mode":"query","index":"status-index","pk":{"name":"status","type":"S","value":"OPEN"}}"#]),
            DashboardCard(id: "c5", title: "develop → main PR", service: "codecommit", template: "codecommit.createPullRequest", kind: .action, icon: "arrow.triangle.pull", profiles: ["sample-profile"], params: ["repository": "web-app", "source": "develop", "destination": "main"]),
            DashboardCard(id: "c6", title: "web-app geçmişi", service: "codecommit", template: "codecommit.openRepository", kind: .link, icon: "clock.arrow.circlepath", params: ["repository": "web-app", "tab": "commits"]),
            DashboardCard(id: "c3", title: "Kullanıcılar", service: "dynamodb", template: "dynamodb.itemCount", kind: .metric, icon: "tablecells.fill", profiles: ["sample-profile"], params: ["table": "Users"]),
            DashboardCard(id: "c4", title: "Hatırlatma", service: "note", template: "note.text", kind: .note, icon: "note.text", params: ["text": "Cuma günü staging ortamı kapatılacak."]),
        ]
        let ago = Date().addingTimeInterval(-420)
        let cardStates: [String: DashboardCardState] = [
            "c1": .loaded(DashboardCached(fetchedAt: ago, data: DashboardCardValue(value: 1284, unit: LocalizedText(en: "objects", tr: "nesne"), details: [LocalizedText(en: "3.2 GB", tr: "3.2 GB")]))),
            "c2": .loaded(DashboardCached(fetchedAt: ago, data: DashboardCardValue(value: 37, unit: LocalizedText(en: "items", tr: "kayıt")))),
            "c3": .failed("AccessDeniedException: not authorized to DescribeTable", previous: nil),
        ]
        var vivid = DashboardPrefs.defaults
        vivid.colorStyle = .vivid
        var monthly = DashboardPrefs.defaults
        monthly.set(.distribution, false)
        monthly.set(.attentionKpi, false)
        monthly.hideEmptyServices = true
        monthly.servicesLayout = .flat
        let monthlyModel = model.with(costState: .loaded(sampleMonthlyCost))
        let variants: [(String, DashboardPrefs, DashboardModel, DashboardPrefs.CostView, NSAppearance.Name, AppLanguage, CGFloat)] = [
            ("muted-light-tr", withCards, model, .month, .aqua, .tr, 1400),
            ("muted-dark-en", .defaults, model, .month, .darkAqua, .en, 1400),
            ("vivid-light-en", vivid, model, .month, .aqua, .en, 1400),
            ("monthly-partial-dark-tr", monthly, monthlyModel, .monthly, .darkAqua, .tr, 1400),
            ("muted-light-tr-narrow", .defaults, model, .month, .aqua, .tr, 980),
        ]
        for (name, prefs, model, view, appearance, language, width) in variants {
            NSAppearance.current = NSAppearance(named: appearance)
            let content = DashboardContent(
                model: model, prefs: prefs, language: language,
                profile: "sample-profile", region: "eu-west-1", account: "123456789012", favorites: ["lambda", "dynamodb", "s3", "cloudwatch"], width: width - 56,
                costView: .constant(view), costMonth: .constant(DashboardContent.currentMonthKey), costMonths: .constant(6), chartStyle: .constant(view == .monthly ? .line : .bar),
                cardStates: cardStates
            )
            .padding(28)
            .frame(width: width)
            .background(Theme.detailBackground(appearance == .darkAqua ? .dark : .light))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            .environment(AppState())
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("dashboard-\(name).png"))
                print("wrote dashboard-\(name).png")
            }
        }
        // The hover bubble and a Details sheet on their own (hover can't be rendered).
        if let cost = model.cost, let point = cost.daily.dropFirst(5).first {
            for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSAppearance.current = NSAppearance(named: appearance)
                let top = cost.services(on: point.date).prefix(3)
                let bubble = DashboardTooltipView(
                    data: DashboardTooltipData(
                        title: DashboardFormat.periodLabel(point.date, monthly: false, language: .tr),
                        subtitle: "\(DashboardFormat.money(point.amount, currency: "USD")) · \(DashboardFormat.signedPercent(point.amount, vs: cost.dailyAverage)) ort.'ya göre",
                        rows: top.map { .init(label: DashboardFormat.shortServiceName($0.name), value: DashboardFormat.money($0.amount, currency: "USD")) },
                        detail: .costPoint(date: point.date)
                    ),
                    language: .tr, onDetails: { _ in }
                )
                .padding(30)
                .background(Theme.detailBackground(appearance == .darkAqua ? .dark : .light))
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                write(bubble, name: "tooltip-\(scheme)", dir: dir)
                let sheet = DashboardDetailSheet(detail: .costPoint(date: point.date), model: model, language: .tr, onOpen: { _ in }, onClose: {}, scrollable: false)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                write(sheet, name: "detail-\(scheme)", dir: dir)
            }
        }
        // The spend chart in each style, and its tooltip.
        if let cost = model.cost {
            for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSAppearance.current = NSAppearance(named: appearance)
                for style in DashboardPrefs.ChartStyle.allCases {
                    let chart = DashboardCostChart(cost: cost, style: style, language: .tr)
                        .frame(width: 860, height: 300)
                        .padding(20)
                        .background(Theme.detailBackground(appearance == .darkAqua ? .dark : .light))
                        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                    write(chart, name: "chart-\(style.rawValue)-\(scheme)", dir: dir)
                }
                // Tooltip in place: a period in the middle and one at each edge.
                for (name, index) in [("mid", cost.daily.count / 2), ("left", 0), ("right", cost.daily.count - 1)] {
                    let pinned = DashboardCostChart(cost: cost, style: name == "right" ? .line : .bar, language: .tr, pinned: cost.daily[index].date)
                        .frame(width: 860, height: 300)
                        .padding(.horizontal, 20)
                        .padding(.top, 200)
                        .padding(.bottom, 20)
                        .background(Theme.detailBackground(appearance == .darkAqua ? .dark : .light))
                        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                    write(pinned, name: "cost-tooltip-\(name)-\(scheme)", dir: dir)
                }
            }
        }
        exit(0)
    }

    @MainActor private static func write<V: View>(_ view: V, name: String, dir: URL) {
        let renderer = ImageRenderer(content: view.environment(AppState()))
        renderer.scale = 1
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            print("wrote \(name).png")
        }
    }

    private static var sampleMonthlyCost: DashboardModel.Cost {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        var points: [(date: Date, amount: Double)] = []
        for back in (0..<6).reversed() {
            let date = calendar.date(byAdding: .month, value: -back, to: start)!
            let amount: Double = back == 0 ? 410 : 980 + Double(back * 73 % 160)
            points.append((date, amount))
        }
        var total = 0.0
        for point in points { total += point.amount }
        return DashboardModel.Cost(
            total: total, currency: "USD", start: nil, end: nil,
            services: [("Amazon Elastic Compute Cloud - Compute", 2100), ("Amazon Relational Database Service", 1300), ("Amazon Simple Storage Service", 700), ("AWS Lambda", 420), ("Amazon CloudFront", 300), ("Amazon DynamoDB", 200), ("Amazon CloudWatch", 150)],
            daily: points, monthly: true, view: .monthly
        )
    }

    private static let sampleEntries: [AWSServiceCatalogEntry] = [
        ("ec2", "EC2", "Compute", "desktopcomputer"), ("lambda", "Lambda", "Compute", "bolt.fill"), ("batch", "Batch", "Compute", "square.stack.3d.forward.dottedline"),
        ("ecs", "ECS", "Containers", "shippingbox.fill"), ("ecr", "ECR", "Containers", "shippingbox.circle"),
        ("s3", "S3", "Storage", "archivebox.fill"), ("efs", "EFS", "Storage", "externaldrive.fill"), ("backup", "AWS Backup", "Storage", "clock.arrow.circlepath"),
        ("rds", "RDS", "Database", "cylinder.split.1x2"), ("dynamodb", "DynamoDB", "Database", "tablecells"), ("elasticache", "ElastiCache", "Database", "memorychip"),
        ("cloudfront", "CloudFront", "Networking & Content Delivery", "globe"), ("route53", "Route 53", "Networking & Content Delivery", "signpost.right.and.left"), ("apigateway", "API Gateway", "Networking & Content Delivery", "point.3.connected.trianglepath.dotted"),
        ("iam", "IAM", "Security, Identity & Compliance", "person.badge.key"), ("kms", "KMS", "Security, Identity & Compliance", "lock.square"), ("secretsmanager", "Secrets Manager", "Security, Identity & Compliance", "key.fill"),
        ("cloudwatch", "CloudWatch", "Management & Governance", "chart.xyaxis.line"), ("cloudformation", "CloudFormation", "Management & Governance", "square.3.layers.3d"),
        ("sqs", "SQS", "Application Integration", "tray.full"), ("sns", "SNS", "Application Integration", "bell.badge"),
        ("glue", "Glue", "Analytics", "drop"), ("sagemaker", "SageMaker", "Machine Learning", "brain"),
    ].enumerated().map { index, e in
        AWSServiceCatalogEntry(id: e.0, name: e.1, category: e.2, icon: e.3, implemented: true, packagesInstalled: index == 7 ? false : true, packageInstallFailed: nil)
    }
}
