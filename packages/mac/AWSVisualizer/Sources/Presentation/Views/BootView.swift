import SwiftUI

/// First screen. Fresh install (no ~/.awsvisualizer, no platform): ask for
/// the access-portal URL, then ask whether ~/.awsvisualizer may be created
/// (if not, the portal is asked again on every launch). With a platform
/// configured: straight to its login (skipped when the SSO token is still
/// valid), with "Change / add platform" below. Login runs
/// `aws sso login --sso-session <platform>`, so the token is shared with the
/// terminal (`aws ... --profile development` works without logging in again).
struct BootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum Phase: Equatable {
        case working(String)
        /// Node.js / npm missing, too old or out of support.
        case runtime(RuntimeCheck)
        /// Node.js download or core `npm install`, with live output.
        case runtimeTask
        /// First sign-in: pick the services whose packages get installed.
        case chooseDefaults
        case installingDefaults
        /// Default services whose packages aren't installed (yet).
        case missingDefaults([String])
        case setup
        case consent
        case login
        case profiles
        case failed(String)
    }

    @State private var phase: Phase = .working("Starting local services...")
    @State private var setup: SetupState?
    @State private var loggingInId: String?
    @State private var loginError: String?
    @State private var showPersonalSheet = false
    @State private var personalState: PersonalAccountsState?

    @State private var taskLog = TaskLog()
    @State private var taskTitle = ""
    @State private var taskSuccessTitle: String?
    @State private var taskFailed = false
    @State private var taskRetry: (() async -> Void)?
    @State private var defaultsSelection: Set<String> = []
    @State private var installController = PackageInstallController()
    @State private var retryServices: RetryRequest?
    /// Signed in, waiting for the default-services steps before entering the app.
    @State private var pendingEntry: PendingEntry?

    struct PendingEntry {
        let profiles: [AWSProfile]
        let active: AWSProfile
        let identity: CallerIdentity?
    }

    struct RetryRequest: Identifiable {
        let id = UUID()
        let services: [String]
    }

    private var wideContent: Bool {
        switch phase {
        case .runtimeTask, .chooseDefaults, .installingDefaults: true
        default: false
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            AWSBrandMark(size: 64)
            Text("AWS Visualizer")
                .font(.largeTitle.bold())
            Text("AWS Environment Manager")
                .font(.title3)
                .foregroundStyle(.secondary)
            Divider().frame(width: 300)
            content
                .frame(maxWidth: wideContent ? 760 : 600)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: phase)
        .task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .working(let message):
            BrandedLoader(message: message).frame(height: 120)
        case .runtime(let check):
            runtimeCard(check)
        case .runtimeTask:
            runtimeTaskCard
        case .chooseDefaults:
            chooseDefaultsCard
        case .installingDefaults:
            installingDefaultsCard
        case .missingDefaults(let ids):
            missingDefaultsCard(ids)
        case .setup:
            card {
                Text("Connect to AWS").font(.title3.bold())
                    .sheet(isPresented: $showPersonalSheet) {
                        PersonalAccountSheet(awsLoginSupported: personalState?.awsLoginSupported ?? false, cliVersion: personalState?.cliVersion) {
                            showPersonalSheet = false
                            Task { await enterApp() }
                        } onCancel: {
                            showPersonalSheet = false
                        }
                    }
                Text("Enter your AWS access portal (IAM Identity Center) start URL.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                PlatformSetupForm(knownSessions: setup?.knownSessions ?? [], onCancel: (setup?.platforms.isEmpty ?? true) ? nil : { phase = .login }) { url, region, name in
                    let response = try await api.addPlatform(startUrl: url, region: region, name: name)
                    setup = try await api.getSetupState()
                    _ = response
                    phase = (setup?.configPersisted ?? false) ? .login : .consent
                }
                Divider()
                HStack {
                    Text("No access portal? Sign in to a personal AWS account (root or IAM user) instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    SecondaryButton("Personal account", systemImage: "person.crop.circle") {
                        Task {
                            personalState = try? await api.getPersonalAccounts()
                            showPersonalSheet = true
                        }
                    }
                }
            }
        case .consent:
            card {
                Label("Save settings to ~/.awsvisualizer?", systemImage: "doc.badge.gearshape")
                    .font(.title3.bold())
                Text("AWS Visualizer can create a small settings file in your home folder (~/.awsvisualizer) to remember this portal, your selected services and preferences. Without it nothing is written there and the portal URL is asked again on the next launch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    SecondaryButton("Don't allow") { phase = .login }
                    ConfirmButton("Allow") {
                        Task {
                            do {
                                try await api.enableConfigPersistence()
                                setup = try await api.getSetupState()
                                phase = .login
                            } catch {
                                phase = .failed(error.friendlyMessage)
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        case .login:
            loginCard
        case .profiles:
            card {
                Text("Set up profiles").font(.title3.bold())
                Text("You're signed in, but no AWS CLI profile points at these accounts yet. Give the ones you use a profile name (e.g. development, production) - the same names work in the terminal: aws s3 ls --profile development.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    AccessibleEnvironmentsSection(environments: appState.accessibleEnvironments, allowsEditing: true)
                }
                .frame(maxHeight: 320)
                if appState.accessibleEnvironments.isEmpty {
                    Text("No accounts were returned for this sign-in.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    SecondaryButton("Back") { phase = .login }
                    Spacer()
                    ConfirmButton("Continue", isDisabled: !appState.accessibleEnvironments.contains { $0.configuredProfileName != nil }) {
                        Task { await enterApp() }
                    }
                }
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                RefreshButton("Retry") { Task { await start() } }
            }
        }
    }

    private var loginCard: some View {
        card {
            Text("Log in").font(.title3.bold())
            Text("Opens your browser for AWS sign-in. One login covers every account and profile of a platform, in this app and in the terminal.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(setup?.platforms ?? []) { platform in
                PlatformRow(platform: platform, isLoggingIn: loggingInId == platform.id, onLogin: {
                    Task { await login(platform) }
                })
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button {
                    phase = .setup
                } label: {
                    Label("Change or add platform", systemImage: "arrow.triangle.swap")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Spacer()
                if setup?.platforms.contains(where: \.loggedIn) == true {
                    ConfirmButton("Continue", isDisabled: loggingInId != nil) {
                        Task { await enterApp() }
                    }
                }
            }
            if setup?.configPersisted == false {
                Text("~/.awsvisualizer isn't saved - this portal will be asked again next time.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Node.js / npm

    @ViewBuilder
    private func runtimeCard(_ check: RuntimeCheck) -> some View {
        card {
            switch check {
            case .outdated(let r):
                Label("Node.js \(r.nodeVersion) is out of support", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.bold())
                    .foregroundStyle(.orange)
                Text("AWS Visualizer runs on it, but Node.js \(r.nodeVersion.major) no longer gets security fixes (Node.js 20 support ended on 30 April 2026). Node.js \(RuntimeManager.recommendedNode.major) LTS with npm \(RuntimeManager.recommendedNpm.major)+ is recommended.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                runtimeDetails(r)
                HStack {
                    Spacer()
                    SecondaryButton("Continue with Node.js \(r.nodeVersion.major)") {
                        RuntimeManager.shared.use(r)
                        Task { await continueAfterRuntime() }
                    }
                }
                runtimeInstallButtons
            case .tooOld(let r):
                Label("Node.js \(r.nodeVersion) is too old", systemImage: "xmark.octagon.fill")
                    .font(.title3.bold()).foregroundStyle(.red)
                Text("The local API needs Node.js \(RuntimeManager.minimumNode.major) or later (\(RuntimeManager.recommendedNode.major) LTS recommended) and npm \(RuntimeManager.minimumNpm.major)+.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                runtimeDetails(r)
                runtimeInstallButtons
            case .missing, .ok:
                Label("Node.js is required", systemImage: "shippingbox")
                    .font(.title3.bold())
                Text("AWS Visualizer runs its local API on Node.js. No Node.js \(RuntimeManager.minimumNode.major)+ with npm was found (looked in the app's folder, nvm, Homebrew and /usr/local).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                runtimeInstallButtons
            }
        }
    }

    private func runtimeDetails(_ r: NodeRuntime) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Node.js", value: "v\(r.nodeVersion)")
            LabeledContent("npm", value: r.npmVersion.map(\.description) ?? "not found")
            LabeledContent("Location", value: r.binDirectory.path)
        }
        .font(.caption)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Default: the official .pkg (system-wide). Then nvm (system-wide,
    /// switchable versions). Below, separately: app-only.
    private var runtimeInstallButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Node.js \(RuntimeManager.installMajor) LTS for every app").font(.callout.bold())
                    Spacer()
                    ConfirmButton("Install Node.js \(RuntimeManager.installMajor) LTS", systemImage: "arrow.down.circle") {
                        Task { await installNode(.system) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Text("Downloads the official installer from nodejs.org, checks its SHA-256 and opens the macOS Installer (you enter your password there). Node.js goes to /usr/local/bin - the terminal and other apps use it too.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("With nvm (switch between versions)").font(.callout.bold())
                    Spacer()
                    SecondaryButton(RuntimeManager.isNvmInstalled ? "Install Node.js \(RuntimeManager.installMajor) with nvm" : "Install nvm + Node.js \(RuntimeManager.installMajor)", systemImage: "square.stack.3d.up") {
                        Task { await installNode(.nvm) }
                    }
                }
                Text(RuntimeManager.isNvmInstalled
                     ? "nvm is installed: runs `nvm install \(RuntimeManager.installMajor)` and makes it the nvm default. More versions can be added and switched in Settings › Node.js & Packages."
                     : "Installs nvm with its official script (~/.nvm, loader lines added to ~/.zshrc), then Node.js \(RuntimeManager.installMajor) as the nvm default. Versions can be added and switched later in Settings › Node.js & Packages.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Link("nodejs.org/download", destination: URL(string: "https://nodejs.org/en/download")!)
                    .font(.caption)
                Spacer()
                Button {
                    Task { await installNode(.appLocal) }
                } label: {
                    Label("Install only for AWS Visualizer (no password)", systemImage: "lock.shield")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Unpacks Node.js into ~/Library/Application Support/AWSVisualizer/node - only this app uses it")
                SecondaryButton("Check again", systemImage: "arrow.clockwise") { Task { await start() } }
            }
        }
    }

    private var runtimeTaskCard: some View {
        card {
            InstallProgressPanel(title: taskTitle, steps: taskLog.steps, isRunning: taskLog.isRunning, noun: "steps", successTitle: taskSuccessTitle) { _ in
                Task { await taskRetry?() }
            }
            .frame(minHeight: 420)
            if !taskLog.isRunning {
                HStack {
                    if taskFailed {
                        SecondaryButton("Back") { Task { await start() } }
                    }
                    Spacer()
                    if taskFailed {
                        RefreshButton("Retry") { Task { await taskRetry?() } }
                    } else {
                        ConfirmButton("Continue") { Task { await continueAfterRuntime() } }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }

    enum NodeInstallKind {
        /// nodejs.org .pkg → /usr/local (every app).
        case system
        /// nvm (+ nvm itself if missing) → ~/.nvm (every app via the shell profile).
        case nvm
        /// tarball → Application Support (this app only).
        case appLocal
    }

    private func installNode(_ kind: NodeInstallKind) async {
        let major = RuntimeManager.installMajor
        taskTitle = switch kind {
        case .system: "Installing Node.js \(major) LTS (system-wide)…"
        case .nvm: RuntimeManager.isNvmInstalled ? "Installing Node.js \(major) with nvm…" : "Installing nvm and Node.js \(major)…"
        case .appLocal: "Installing Node.js \(major) LTS for AWS Visualizer…"
        }
        taskSuccessTitle = nil
        taskFailed = false
        taskRetry = { await installNode(kind) }
        taskLog.reset()
        phase = .runtimeTask
        var release: RuntimeManager.NodeRelease?
        var nvmTag: String?
        do {
            let runtime: NodeRuntime
            switch kind {
            case .nvm:
                if !RuntimeManager.isNvmInstalled {
                    nvmTag = try await RuntimeManager.shared.installNvm(log: taskLog)
                }
                runtime = try await RuntimeManager.shared.installNodeWithNvm("\(major)", setDefault: true, log: taskLog)
                RuntimeManager.shared.use(runtime)
            case .system, .appLocal:
                taskLog.begin("release", "Find the latest Node.js \(major) LTS")
                taskLog.append("$ curl https://nodejs.org/dist/index.json\n")
                let found = try await RuntimeManager.shared.latestRelease()
                release = found
                taskLog.append("\(found.version)\n")
                taskLog.finish()
                runtime = kind == .system
                    ? try await RuntimeManager.shared.installSystemNode(found, log: taskLog)
                    : try await RuntimeManager.shared.installNode(found, log: taskLog)
            }
            var success = "Node.js \(runtime.nodeVersion) and npm \(runtime.npmVersion.map(\.description) ?? "-") installed"
            // Core packages next, in the same terminal.
            if let apiDirectory = SidecarManager.resolveApiDirectory() {
                let missing = RuntimeManager.shared.missingCorePackages(apiDirectory: apiDirectory)
                if !missing.isEmpty {
                    taskTitle = "Installing the app's core npm packages…"
                    taskRetry = { await installCore(apiDirectory, missing: missing) }
                    taskLog.begin("core-check", "Check core packages")
                    taskLog.append("Missing: \(missing.joined(separator: ", "))\n")
                    taskLog.finish()
                    do {
                        try await RuntimeManager.shared.installCorePackages(apiDirectory: apiDirectory, log: taskLog)
                        success += ", core packages installed"
                    } catch {
                        taskFailed = true
                        taskLog.fail(error.localizedDescription, command: RuntimeManager.shared.coreInstallCommand(apiDirectory: apiDirectory).display)
                        return
                    }
                }
            }
            taskSuccessTitle = success
            taskLog.done()
        } catch {
            taskFailed = true
            let command = switch kind {
            case .system: RuntimeManager.shared.manualPkgInstallCommand(release)
            case .nvm: RuntimeManager.shared.manualNvmInstallCommand(tag: nvmTag)
            case .appLocal: RuntimeManager.shared.manualNodeInstallCommand(release)
            }
            taskLog.fail(error.localizedDescription, command: command)
        }
    }

    private func installCore(_ apiDirectory: URL, missing: [String]) async {
        taskTitle = "Installing the app's core npm packages…"
        taskSuccessTitle = "Core packages installed"
        taskFailed = false
        taskRetry = { await installCore(apiDirectory, missing: missing) }
        taskLog.reset()
        phase = .runtimeTask
        taskLog.begin("check", "Check core packages")
        taskLog.append("Missing: \(missing.joined(separator: ", "))\n")
        taskLog.finish()
        do {
            try await RuntimeManager.shared.installCorePackages(apiDirectory: apiDirectory, log: taskLog)
            taskLog.done()
        } catch {
            taskFailed = true
            taskLog.fail(error.localizedDescription, command: RuntimeManager.shared.coreInstallCommand(apiDirectory: apiDirectory).display)
        }
    }

    // MARK: - Default services

    private var chooseDefaultsCard: some View {
        card {
            Text("Choose your default services").font(.title3.bold())
            Text("Pick the AWS services you work with. Their SDK packages are installed next with npm, step by step, and they appear in your sidebar. Others can be installed later from Settings › Services.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ServiceSelectionList(mode: .onboarding, selection: $defaultsSelection)
                .frame(height: 380)
            HStack {
                Spacer()
                ConfirmButton("Save and install (\(defaultsSelection.count))", systemImage: "arrow.down.circle", isDisabled: defaultsSelection.isEmpty) {
                    Task { await saveDefaults() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Job rows, with services fixed by a retry since shown as installed.
    private var defaultInstallSteps: [InstallStepItem] {
        installController.steps.map { step in
            var s = step
            if s.status == .failed, appState.serviceCatalog.first(where: { $0.id == s.id })?.packagesInstalled == true {
                s.status = .installed
                s.error = nil
            }
            return s
        }
    }

    private var installingDefaultsCard: some View {
        card {
            InstallProgressPanel(title: "Installing your services…", steps: defaultInstallSteps, isRunning: installController.isRunning) { item in
                retryServices = RetryRequest(services: [item.id])
            }
            .frame(minHeight: 440)
            if let error = installController.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                ConfirmButton(installController.isRunning ? "Continue in background" : "Continue") {
                    Task { await finishEntering() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .sheet(item: $retryServices) { request in
            PackageInstallSheet(services: request.services) {
                retryServices = nil
            }
        }
    }

    private func missingDefaultsCard(_ ids: [String]) -> some View {
        card {
            Label("Some default services aren't installed", systemImage: "shippingbox")
                .font(.title3.bold())
            Text("The npm packages of these default services are missing:")
                .font(.callout).foregroundStyle(.secondary)
            Text(ids.compactMap { id in appState.serviceCatalog.first { $0.id == id }?.name }.joined(separator: ", "))
                .font(.callout)
            HStack {
                Spacer()
                SecondaryButton("Skip") { Task { await finishEntering() } }
                ConfirmButton("Install now (\(ids.count))", systemImage: "arrow.down.circle") {
                    startDefaultInstall(ids)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func saveDefaults() async {
        let ids = appState.serviceCatalog.map(\.id).filter { defaultsSelection.contains($0) }
        do {
            try await api.setUserDefaultServices(ids)
            try await api.setSelectedServices(ids)
            appState.userDefaultServiceIDs = ids
            appState.selectedServiceIDs = ids
            startDefaultInstall(ids)
        } catch {
            phase = .failed(error.friendlyMessage)
        }
    }

    private func startDefaultInstall(_ ids: [String]) {
        phase = .installingDefaults
        installController.start(ids, api: api) { _ in
            Task { await appState.reloadServiceCatalog(using: api) }
        }
    }

    private func finishEntering() async {
        installController.cancelPolling()
        await appState.reloadServiceCatalog(using: api)
        guard let entry = pendingEntry else { return }
        pendingEntry = nil
        appState.applyAuthenticatedProfiles(entry.profiles, selecting: entry.active, identity: entry.identity)
        appState.lastProfileRefresh = Date()
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(20)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .transition(.opacity)
    }

    private func start() async {
        phase = .working("Checking Node.js and npm...")
        let check = await RuntimeManager.shared.check()
        if case .ok = check {
            await continueAfterRuntime()
        } else {
            phase = .runtime(check)
        }
    }

    /// Core npm packages, then the sidecar.
    private func continueAfterRuntime() async {
        if let apiDirectory = SidecarManager.resolveApiDirectory() {
            let missing = RuntimeManager.shared.missingCorePackages(apiDirectory: apiDirectory)
            if !missing.isEmpty {
                await installCore(apiDirectory, missing: missing)
                return
            }
        }
        await startSidecar()
    }

    private func startSidecar() async {
        phase = .working("Starting local services...")
        let sidecarReady = await SidecarManager.shared.ensureRunning { message in
            phase = .working(message)
        }
        guard sidecarReady else {
            phase = .failed(SidecarManager.shared.lastFailure ?? "The local API service could not be started. Make sure Node.js is installed, then retry.")
            return
        }
        phase = .working("Checking AWS sign-in...")
        do {
            let state = try await api.getSetupState()
            setup = state
            guard state.awsCliAvailable else {
                phase = .failed("The AWS CLI (v2) wasn't found. Install it (https://aws.amazon.com/cli/), then retry - sign-in runs `aws sso login`.")
                return
            }
            if state.platforms.isEmpty {
                if let personal = try? await api.getPersonalAccounts(), !personal.accounts.isEmpty,
                   let check = try? await api.checkProfiles(), check.profiles.contains(where: \.valid) {
                    await enterApp()
                } else {
                    phase = .setup
                }
            } else if state.platforms.contains(where: \.loggedIn) {
                await enterApp()
            } else {
                phase = .login
            }
        } catch {
            phase = .failed(error.friendlyMessage)
        }
    }

    private func login(_ platform: SsoPlatformStatus) async {
        loggingInId = platform.id
        loginError = nil
        do {
            let response = try await api.login(ssoSession: platform.id)
            guard response.success else {
                loginError = "Sign-in didn't complete. Please try again."
                loggingInId = nil
                return
            }
            setup = try await api.getSetupState()
            loggingInId = nil
            await enterApp()
        } catch {
            loginError = error.friendlyMessage
            loggingInId = nil
        }
    }

    private func enterApp() async {
        phase = .working("Checking profiles...")
        do {
            try await resolveActiveProfile()
        } catch {
            phase = .failed(error.friendlyMessage)
        }
    }

    private func showProfileSetup() async {
        phase = .working("Loading your AWS accounts...")
        appState.accessibleEnvironments = (try? await api.getAccessibleEnvironments()) ?? []
        phase = .profiles
    }

    private func resolveActiveProfile() async throws {
        let profileCheck = try await api.checkProfiles()
        let validProfiles = profileCheck.profiles.filter { $0.valid }

        guard let firstValid = validProfiles.first else {
            await showProfileSetup()
            return
        }

        let profiles = profileCheck.profiles.map(AWSProfile.init(checkResult:))
        let activeProfile = AWSProfile(checkResult: firstValid)

        phase = .working("Loading services...")
        async let catalog = try? api.getServiceCatalog()
        async let selected = try? api.getSelectedServices()
        async let favorites = try? api.getFavoriteServices()
        async let config = try? api.getAppConfig()
        appState.serviceCatalog = (await catalog) ?? []
        appState.selectedServiceIDs = (await selected) ?? []
        appState.favoriteServiceIDs = Set((await favorites) ?? [])
        appState.hasLoadedServiceSelection = true
        if let loadedConfig = await config {
            appState.maxTabs = loadedConfig.maxTabs
            appState.apiVersion = loadedConfig.app.version
            appState.devTools = loadedConfig.devTools ?? DevToolsConfig(
                enabled: (loadedConfig.terminalPanelEnabled ? ["terminal"] : []) + (loadedConfig.kiroCliPanelEnabled ? ["kiro-cli"] : []),
                custom: []
            )
            appState.dynamoDbAutoColumnWidth = loadedConfig.dynamoDbAutoColumnWidth
            appState.dynamoDbItemView = loadedConfig.dynamoDbItemView.flatMap(DynamoItemViewMode.init(rawValue:)) ?? .json
            appState.codeTheme = loadedConfig.codeTheme.flatMap(CodeThemeID.init(rawValue:)) ?? .vscode
            appState.layoutMode = loadedConfig.layoutMode.flatMap(LayoutMode.init(rawValue:)) ?? .sideBySide
            appState.wordWrapDefault = loadedConfig.wordWrap ?? false
            appState.wordWrap = appState.wordWrapDefault
            appState.fileIconTheme = loadedConfig.fileIconTheme.flatMap(FileIconTheme.init(rawValue:)) ?? .colorful
            appState.historyLayout = loadedConfig.historyLayout.flatMap(LayoutMode.init(rawValue:)) ?? .singlePage
            appState.dashboardPrefs = loadedConfig.dashboard ?? .defaults
            appState.buttonColors = loadedConfig.buttonColors
            appState.defaultIDEBundleIdentifier = loadedConfig.defaultIdeBundleIdentifier
        }

        pendingEntry = PendingEntry(profiles: profiles, active: activeProfile, identity: firstValid.identity)
        appState.userDefaultServiceIDs = (try? await api.getUserDefaultServices()) ?? []
        if appState.userDefaultServiceIDs.isEmpty {
            defaultsSelection = []
            phase = .chooseDefaults
            return
        }
        // Defaults whose packages are missing and haven't already failed (those are shown in Settings › Services).
        let missing = appState.userDefaultServiceIDs.filter { id in
            guard let entry = appState.serviceCatalog.first(where: { $0.id == id }) else { return false }
            return entry.needsPackageInstall && entry.packageInstallFailed != true
        }
        if !missing.isEmpty {
            phase = .missingDefaults(missing)
            return
        }
        await finishEntering()
    }
}
