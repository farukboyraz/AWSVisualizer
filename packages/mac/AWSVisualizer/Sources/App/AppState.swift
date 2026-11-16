import Foundation
import SwiftUI

enum AppScreen: String, CaseIterable {
    case boot
    case main
}

/// Every AWS service id we can actually render a real view for. The rawValue
/// matches the backend service catalog's `id`. Anything selected by the user
/// that isn't one of these cases falls back to a "not implemented yet" view.
enum ServiceScreen: String, CaseIterable {
    case elasticbeanstalk
    case lambda
    case ec2
    case ecs
    case rds
    case dynamodb
    case s3
    case sqs
    case cloudwatch
    case cloudfront
    case route53
    case codecommit
    case secretsmanager
    case cloudformation
    case elasticloadbalancing
    case apigateway
    case sns
    case ecr
    case kms
    case lightsail
    case batch
    case autoscaling = "ec2-autoscaling"
    case outposts
    case serverlessapplicationrepository
    case wavelength
    case localzones
    case nitroenclaves
    case eks
    case fargate
    case apprunner
    case efs
    case fsx
    case ebs
    case s3glacier
    case storagegateway
    case backup
    case elasticache
    case redshift
    case neptune
    case documentdb
    case keyspaces
    case timestream
    case qldb
    case memorydb
    case rdsProxy = "rds-proxy"
    case dms
    case vpc
    case directconnect
    case globalaccelerator
    case privatelink
    case transitgateway
    case cloudmap
    case appmesh
    case vpnclient
    case iam
    case cognito
    case guardduty
    case inspector
    case securityhub
    case waf
    case acm
    case macie
    case directoryservice
    case artifact
    case firewallmanager
    case detective
    case identityCenter = "iam-identitycenter"
    case networkfirewall
    case verifiedaccess
    case resourceaccessmanager
    case cloudtrail
    case config
    case systemsmanager
    case organizations
    case controltower
    case trustedadvisor
    case servicecatalog
    case licensemanager
    case computeoptimizer
    case costexplorer
    case budgets
    case healthdashboard
    case wellarchitectedtool
    case resourcegroups
    case opsworks
    case launchwizard
    case codebuild
    case codepipeline
    case codedeploy
    case codeartifact
    case cloudshell
    case cloud9
    case xray
    case codestar
    case codewhisperer
    case codecatalyst
    case athena
    case emr
    case kinesis
    case opensearch
    case quicksight
    case glue
    case datazone
    case lakeformation
    case msk
    case datapipeline
    case cloudsearch
    case sagemaker
    case bedrock
    case rekognition
    case comprehend
    case textract
    case polly
    case transcribe
    case translate
    case lex
    case personalize
    case forecast
    case kendra
    case amazonQ = "q"
    case eventbridge
    case stepfunctions
    case appflow
    case mq
    case apppipes
    case migrationhub
    case datasync
    case transferfamily
    case applicationdiscoveryservice
    case snowfamily
    case mgn
    case elastictranscoder
    case mediaconvert
    case medialive
    case mediapackage
    case mediastore
    case ivs
    case iotcore
    case iotanalytics
    case iotgreengrass
    case iotdevicedefender
    case iotsitewise
    case workmail
    case chime
    case connect
    case pinpoint
    case ses
    case honeycode
    case workspaces
    case appstream
    case worklink
    case amplify
    case appsync
    case devicefarm
    case location
    case managedblockchain
    case qldbBlockchain = "qldb-blockchain"
    case groundstation
    case braket
    case robomaker
    case gamelift
}

let dashboardServiceID = "dashboard"

enum AppLanguage: String, CaseIterable {
    case en = "English"
    case tr = "Türkçe"

    var okButtonTitle: String {
        switch self {
        case .en: "OK"
        case .tr: "Tamam"
        }
    }

    var tabLimitWarningTitle: String {
        switch self {
        case .en: "Tab limit reached"
        case .tr: "Sekme limitine ulaşıldı"
        }
    }

    func tabLimitWarningMessage(maxTabs: Int) -> String {
        switch self {
        case .en: "You already have \(maxTabs) tabs open, which is the current limit. Close a tab or raise the limit in Settings."
        case .tr: "Şu anki limit olan \(maxTabs) sekme zaten açık. Bir sekmeyi kapatın ya da limiti Ayarlar'dan artırın."
        }
    }

    var selectDefaultServicesLabel: String {
        switch self {
        case .en: "Select default services"
        case .tr: "Varsayılan servisleri seç"
        }
    }

    var minServiceWarningTitle: String {
        switch self {
        case .en: "At least one service required"
        case .tr: "En az bir servis gerekli"
        }
    }

    var minServiceWarningMessage: String {
        switch self {
        case .en: "You need to keep at least one service selected."
        case .tr: "En az bir servisi seçili tutmanız gerekiyor."
        }
    }

    var closeTabLabel: String {
        switch self {
        case .en: "Close Tab"
        case .tr: "Sekmeyi Kapat"
        }
    }

    var closeOtherTabsLabel: String {
        switch self {
        case .en: "Close Other Tabs"
        case .tr: "Diğer Sekmeleri Kapat"
        }
    }

    var closeAllTabsLabel: String {
        switch self {
        case .en: "Close All Tabs"
        case .tr: "Tüm Sekmeleri Kapat"
        }
    }

    var cancelButtonTitle: String {
        switch self {
        case .en: "Cancel"
        case .tr: "Vazgeç"
        }
    }

    var closeAllTabsConfirmationTitle: String {
        switch self {
        case .en: "Close all tabs?"
        case .tr: "Tüm sekmeler kapatılsın mı?"
        }
    }

    var closeAllTabsConfirmationMessage: String {
        switch self {
        case .en: "All open tabs will be closed. Are you sure?"
        case .tr: "Açık olan tüm sekmeler kapanacak. Emin misiniz?"
        }
    }

    var yesButtonTitle: String {
        switch self {
        case .en: "Yes"
        case .tr: "Evet"
        }
    }

    var noButtonTitle: String {
        switch self {
        case .en: "No"
        case .tr: "Hayır"
        }
    }

    /// Generic "you have unsaved changes" exit warning - shared by the
    /// Filter Builder popup and Settings (any screen with a draft-then-
    /// Save model whose close button should warn before discarding).
    var discardChangesTitle: String {
        switch self {
        case .en: "Changes not applied"
        case .tr: "Değişiklikleriniz uygulanmadı"
        }
    }

    var discardChangesMessage: String {
        switch self {
        case .en: "Your changes haven't been applied. Are you sure you want to exit?"
        case .tr: "Değişiklikleriniz uygulanmadı. Çıkmak istediğinize emin misiniz?"
        }
    }

    /// Shown automatically before every `DeleteButton` actually runs its
    /// action (see `DeleteButton.swift`) - a single, consistent "are you
    /// sure" for every delete across the app, rather than each screen
    /// wording its own.
    var deleteConfirmationTitle: String {
        switch self {
        case .en: "Delete this data?"
        case .tr: "Bu veri silinsin mi?"
        }
    }

    var deleteConfirmationMessage: String {
        switch self {
        case .en: "This data will be deleted. Are you sure you want to delete it?"
        case .tr: "Bu veri silinecektir. Silmek istediğinize emin misiniz?"
        }
    }

    var clearFiltersButtonLabel: String {
        switch self {
        case .en: "Clear Filters"
        case .tr: "Filtreleri Temizle"
        }
    }

    var clearFiltersConfirmationTitle: String {
        switch self {
        case .en: "Clear all filters?"
        case .tr: "Tüm filtreler temizlensin mi?"
        }
    }

    var clearFiltersConfirmationMessage: String {
        switch self {
        case .en: "Filters will be cleared. Are you sure?"
        case .tr: "Filtreler temizlenecektir. Emin misiniz?"
        }
    }

    var maxFilterConditionsWarning: String {
        switch self {
        case .en: "You can add up to \(FilterCondition.maxConditions) filter conditions."
        case .tr: "En fazla \(FilterCondition.maxConditions) arama kriteri ekleyebilirsiniz."
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct WorkspaceTab: Identifiable {
    let id = UUID()
    var serviceID: String
}

@Observable
final class AppState {
    var screen: AppScreen = .boot
    var currentProfile: String = "" {
        didSet {
            if let match = profiles.first(where: { $0.name == currentProfile }) {
                currentRegion = match.region
                // Account info in the popover follows the selected profile
                // (it used to stay on whichever profile the app booted with).
                if let identity = match.identity {
                    callerIdentity = identity
                }
            }
            // Switching profiles (top-right picker or the popover's own
            // picker) points every open tab at a different AWS account -
            // whatever was selected in the sidebar/tab bar no longer means
            // the same thing, so land back on a single fresh Dashboard tab,
            // as if the app had just been opened.
            if oldValue != currentProfile {
                resetToDashboard()
            }
        }
    }
    var currentRegion: String = "eu-west-1"
    var language: AppLanguage = .en {
        // Error text built outside a view (`friendlyMessage`) follows it too.
        didSet { AppLanguage.current = language }
    }
    var appearance: AppAppearance = .system
    var isAuthenticated: Bool = false
    var callerIdentity: CallerIdentity?
    var profiles: [AWSProfile] = []
    var accessibleEnvironments: [AccessibleEnvironment] = []

    var serviceCatalog: [AWSServiceCatalogEntry] = []
    var selectedServiceIDs: [String] = []
    var favoriteServiceIDs: Set<String> = []
    var hasLoadedServiceSelection = false
    /// Services picked on first sign-in (`userDefaultServices` in ~/.awsvisualizer).
    var userDefaultServiceIDs: [String] = []

    var tabs: [WorkspaceTab]
    var activeTabID: WorkspaceTab.ID
    var maxTabs: Int = 7 {
        didSet { clampTabsToMax() }
    }
    var tabLimitWarningVisible: Bool = false
    /// Tools offered by the right-edge Dev Tools panel (Settings ›
    /// Developer); the panel only shows when at least one is enabled.
    var devTools: DevToolsConfig = .empty
    /// Set to open the Settings window on a given page (e.g. the sidebar's
    /// "Select Services..." opens Settings › Services).
    var requestedSettingsPage: SettingsPage?
    /// Whether DynamoDB's scan-results grid sizes each column to fit its
    /// longest value/header, vs. splitting the available width evenly -
    /// persisted in `~/.awsvisualizer`, on by default.
    var dynamoDbAutoColumnWidth: Bool = true
    var dynamoDbItemView: DynamoItemViewMode = .json
    var codeTheme: CodeThemeID = .vscode
    /// List + detail screens side by side, or one page at a time with a
    /// Back button (Settings → Layout, persisted in `~/.awsvisualizer`).
    var layoutMode: LayoutMode = .sideBySide
    /// Settings' default word wrap (persisted).
    var wordWrapDefault = false
    /// What text viewers use right now - starts from `wordWrapDefault`,
    /// View → Word Wrap (⌥Z) flips it for the session only.
    var wordWrap = false
    /// File / folder icons in file lists (Settings → Layout, persisted).
    var fileIconTheme: FileIconTheme = .colorful
    /// CodeCommit file History over the file or next to it (Settings, persisted).
    var historyLayout: LayoutMode = .singlePage
    /// Settings › Display › Dashboard.
    var dashboardPrefs = DashboardPrefs.defaults
    /// The local API's version (GET /api/config `app.version`) - shown in Settings › About.
    var apiVersion: String?
    /// Where a dashboard card (or an action's result) wants to go; the
    /// service's screen picks it up after loading its list and clears it.
    var pendingDeepLink: CardLinkTarget?

    /// A card's search for the opened service's filter field (`ScreenFilterField`).
    var pendingFilter: (service: String, text: String)?

    /// Opens a service, and in it one resource / tab when the screen
    /// supports it; a card's search goes into the screen's filter field.
    func open(_ target: CardLinkTarget) {
        pendingDeepLink = target.resource == nil && target.query == nil && target.prefix == nil ? nil : target
        pendingFilter = target.filter.flatMap { $0.isEmpty ? nil : (target.service, $0) }
        selectedService = target.service
    }

    /// The pending filter text when it is for the service on screen; cleared once taken.
    func takePendingFilter() -> String? {
        guard let pending = pendingFilter, pending.service == selectedService else { return nil }
        pendingFilter = nil
        return pending.text
    }

    /// The pending link for `service`, cleared once taken.
    func takeDeepLink(for service: String) -> CardLinkTarget? {
        guard let link = pendingDeepLink, link.service == service else { return nil }
        pendingDeepLink = nil
        return link
    }
    /// Per-kind background colors for `AppButton` (New/Edit/Delete/Save/
    /// Clone/Refresh/Approve) - Settings-editable, persisted in
    /// `~/.awsvisualizer`. Text/icon color is never stored here, always
    /// derived from the background for contrast (see `AppButton.swift`).
    var buttonColors: ButtonColorConfig = .defaults
    /// Bundle identifier of the IDE `OpenInIDEControl` (Lambda's Code tab)
    /// preselects - persisted in `~/.awsvisualizer`. Empty means "no
    /// preference," the control falls back to the first installed IDE.
    var defaultIDEBundleIdentifier: String = ""

    init() {
        let initialTab = WorkspaceTab(serviceID: dashboardServiceID)
        tabs = [initialTab]
        activeTabID = initialTab.id
    }

    var needsServiceSelection: Bool {
        hasLoadedServiceSelection && selectedServiceIDs.isEmpty
    }

    var selectedCatalogEntries: [AWSServiceCatalogEntry] {
        selectedServiceIDs.compactMap { id in serviceCatalog.first { $0.id == id } }
    }

    var implementedSelectedServiceIDs: [String] {
        selectedCatalogEntries.filter { $0.implemented }.map { $0.id }
    }

    var selectedService: String {
        get { activeTab?.serviceID ?? dashboardServiceID }
        set {
            guard let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
            tabs[index].serviceID = newValue
        }
    }

    private var activeTab: WorkspaceTab? {
        tabs.first { $0.id == activeTabID }
    }

    /// Closes every open tab and lands on a single fresh Dashboard tab -
    /// used after the selected-services set changes, since previously open
    /// tabs may point at a service that's no longer selected.
    func resetToDashboard() {
        let tab = WorkspaceTab(serviceID: dashboardServiceID)
        tabs = [tab]
        activeTabID = tab.id
    }

    func openInNewTab(_ serviceID: String) {
        if let existing = tabs.first(where: { $0.serviceID == serviceID }) {
            activeTabID = existing.id
            return
        }
        // Single-tab mode: there's nowhere else to open a new tab, so just
        // navigate the one tab in place instead of ever hitting the tab
        // limit warning.
        guard maxTabs > 1 else {
            selectedService = serviceID
            return
        }
        guard tabs.count < maxTabs else {
            tabLimitWarningVisible = true
            return
        }
        let tab = WorkspaceTab(serviceID: serviceID)
        tabs.append(tab)
        activeTabID = tab.id
    }

    func closeTab(_ id: WorkspaceTab.ID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs[max(0, index - 1)].id
        }
    }

    func activateTab(_ id: WorkspaceTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    func closeOtherTabs(keeping id: WorkspaceTab.ID) {
        guard let kept = tabs.first(where: { $0.id == id }) else { return }
        tabs = [kept]
        activeTabID = kept.id
    }

    private func clampTabsToMax() {
        guard maxTabs > 0, tabs.count > maxTabs else { return }
        var kept: [WorkspaceTab] = []
        if let active = activeTab {
            kept.append(active)
        }
        for tab in tabs where !kept.contains(where: { $0.id == tab.id }) {
            guard kept.count < maxTabs else { break }
            kept.append(tab)
        }
        tabs = kept
        if !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs.first?.id ?? activeTabID
        }
    }

    func applyAuthenticatedProfiles(_ profiles: [AWSProfile], selecting profile: AWSProfile, identity: CallerIdentity?) {
        self.profiles = profiles
        callerIdentity = identity
        currentProfile = profile.name
        isAuthenticated = true
        screen = .main
    }

    /// The selected profile's entry, if it's in the list.
    var currentProfileInfo: AWSProfile? {
        profiles.first { $0.name == currentProfile }
    }

    /// When the profile list was last re-checked - used to debounce the
    /// automatic refreshes (app activation, "Not Authorized" responses).
    var lastProfileRefresh: Date?

    /// Replaces the profile list with a fresh `check-profiles` result,
    /// keeping the current selection when it still exists. Every profile
    /// in ~/.aws/config is kept - expired ones are flagged, not dropped.
    func applyProfileCheck(_ results: [ProfileCheckResult]) {
        profiles = results.map(AWSProfile.init(checkResult:))
        lastProfileRefresh = Date()
        if let current = currentProfileInfo, let identity = current.identity {
            callerIdentity = identity
        }
    }
}
