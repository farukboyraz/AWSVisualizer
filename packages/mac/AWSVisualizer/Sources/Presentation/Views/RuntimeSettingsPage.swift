import SwiftUI
import AppKit

/// Settings › Node.js & Packages: which Node.js the app runs on, nvm
/// (install / update, versions, `nvm alias default`), system-wide and
/// app-only installs, and where the AWS SDK packages live. Actions run
/// right away (no Save Changes), each in a popup with its terminal output.
struct RuntimeSettingsPage: View {
    var onOpenServices: () -> Void = {}

    @Environment(\.apiService) private var api
    @State private var runtimes: [NodeRuntime] = []
    @State private var nvmVersion: String?
    @State private var nvmDefault: String?
    @State private var nvmVersions: [String] = []
    @State private var releases: [RuntimeManager.NodeReleaseInfo] = []
    @State private var releaseError: String?
    @State private var preference: RuntimePreference?
    @State private var packages: PackagesStatus?
    @State private var loading = true

    /// "" = automatic, else a bin directory path.
    @State private var choice = ""
    @State private var applying = false
    @State private var applyMessage: String?

    @State private var selectedRelease = ""
    @State private var makeDefault = true
    @State private var task: RuntimeTask?
    @State private var confirmUninstall: String?
    @State private var confirmRemoveLocal = false

    private var current: NodeRuntime? { RuntimeManager.shared.selected }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if loading {
                ProgressView("Looking for Node.js installs…").frame(maxWidth: .infinity)
            } else {
                currentSection
                Divider()
                nvmSection
                Divider()
                installSection
                Divider()
                packagesSection
            }
        }
        .task { await reload() }
        .sheet(item: $task) { t in
            RuntimeTaskSheet(task: t) {
                task = nil
                Task { await reload() }
            }
        }
        .alert("Uninstall Node.js \(confirmUninstall ?? "")?", isPresented: Binding(get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } })) {
            Button("Cancel", role: .cancel) { confirmUninstall = nil }
            Button("Uninstall", role: .destructive) {
                if let v = confirmUninstall {
                    task = RuntimeTask(title: "Uninstalling Node.js \(v)…", success: "Node.js \(v) uninstalled") { log in
                        try await RuntimeManager.shared.uninstallNvmVersion(v, log: log)
                    }
                }
                confirmUninstall = nil
            }
        } message: {
            Text("Runs `nvm uninstall \(confirmUninstall ?? "")`. Global npm packages installed under that version are removed with it.")
        }
        .alert("Remove the app-only Node.js?", isPresented: $confirmRemoveLocal) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                try? RuntimeManager.shared.removeAppLocalNode()
                Task { await reload() }
            }
        } message: {
            Text("Deletes \(RuntimeManager.managedNodeDirectory.path). Other Node.js installs are not touched.")
        }
    }

    // MARK: Sections

    private var currentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("AWS Visualizer runs on")
            if let current {
                runtimeSummary(current)
            } else {
                Text("No Node.js selected.").foregroundStyle(.secondary)
            }
            HStack {
                Picker("Node.js for AWS Visualizer", selection: $choice) {
                    Text("Automatic (recommended)").tag("")
                    ForEach(runtimes.filter { if case .tooOld = RuntimeManager.classify($0) { false } else { true } }, id: \.binDirectory) { r in
                        Text(label(r)).tag(r.binDirectory.path)
                    }
                }
                .frame(maxWidth: 480)
                SaveButton("Apply and restart", isLoading: applying, isDisabled: choice == (preference?.preferredNodeBin ?? "") && !applying) {
                    Task { await apply() }
                }
            }
            Text("Automatic: the nvm default, then a system-wide install, then the app-only one - the first with Node.js \(RuntimeManager.recommendedNode.major)+ and npm \(RuntimeManager.recommendedNpm.major)+. Restarting the local API takes a few seconds.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let applyMessage { Text(applyMessage).font(.caption).foregroundStyle(.secondary) }
            if preference?.persisted == false {
                Text("~/.awsvisualizer isn't saved, so the choice lasts until the app quits.").font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var nvmSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("nvm")
                if let nvmVersion { Text("v\(nvmVersion)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if nvmVersion != nil {
                    SecondaryButton("Update nvm", systemImage: "arrow.triangle.2.circlepath") { installNvmTask() }
                }
            }
            if nvmVersion == nil {
                Text("nvm keeps several Node.js versions side by side and switches between them. It installs into ~/.nvm with its official script, which adds the loader lines to ~/.zshrc - every terminal and app then has nvm and the default version.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                NewButton("Install nvm", systemImage: "square.stack.3d.up") { installNvmTask() }
            } else if nvmVersions.isEmpty {
                Text("No Node.js versions installed with nvm yet - install one below.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(nvmVersions, id: \.self) { v in nvmRow(v) }
                }
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Default = `nvm alias default`, the version new terminals start with.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func nvmRow(_ v: String) -> some View {
        let bin = RuntimeManager.nvmDirectory.appendingPathComponent("versions/node/\(v)/bin")
        let usedByApp = current?.binDirectory.standardizedFileURL.path == bin.standardizedFileURL.path
        let usable = (SemVer(v) ?? SemVer(0)) >= RuntimeManager.minimumNode
        return HStack(spacing: 8) {
            Text(v).font(.system(.callout, design: .monospaced))
            if v == nvmDefault { badge("default", .blue) }
            if usedByApp { badge("AWS Visualizer", .green) }
            if !usable { badge("too old for AWS Visualizer", .orange) }
            Spacer()
            if v != nvmDefault {
                SecondaryButton("Make default", compactSize: 22) {
                    task = RuntimeTask(title: "Setting the nvm default…", success: "nvm default is now \(v)") { log in
                        try await RuntimeManager.shared.setNvmDefault(v, log: log)
                    }
                }
            }
            if usable && !usedByApp {
                SecondaryButton("Use here", compactSize: 22) {
                    choice = bin.path
                    Task { await apply() }
                }
                .help("Run AWS Visualizer's local API on \(v)")
            }
            DeleteButton(compactSize: 22, isDisabled: usedByApp, help: usedByApp ? "In use by AWS Visualizer" : "nvm uninstall \(v)") {
                confirmUninstall = v
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Install a Node.js version")
            if let releaseError {
                Text(releaseError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Picker("Version", selection: $selectedRelease) {
                    ForEach(releases) { r in
                        Text("\(r.version) · \(r.lts.map { "LTS \($0)" } ?? "Current") · \(r.date)").tag(r.version)
                    }
                }
                .frame(maxWidth: 380)
                Spacer()
            }
            HStack(spacing: 10) {
                NewButton("With nvm", systemImage: "square.stack.3d.up", isDisabled: selectedRelease.isEmpty) { installWithNvm() }
                Toggle("Make it the nvm default", isOn: $makeDefault).toggleStyle(.checkbox).font(.caption)
                Spacer()
                SecondaryButton("System-wide (.pkg)", systemImage: "desktopcomputer", isDisabled: selectedRelease.isEmpty) { installPkg() }
                    .help("Official nodejs.org installer → /usr/local/bin (asks for your password in the macOS Installer)")
                SecondaryButton("Only for AWS Visualizer", systemImage: "lock.shield", isDisabled: selectedRelease.isEmpty) { installLocal() }
                    .help("Unpacks into ~/Library/Application Support/AWSVisualizer/node")
            }
            installedElsewhere
        }
    }

    @ViewBuilder
    private var installedElsewhere: some View {
        let others = runtimes.filter { if case .nvm = $0.source { false } else { true } }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Other installs").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(others, id: \.binDirectory) { r in
                    HStack {
                        Text(label(r)).font(.caption)
                        Text(r.binDirectory.path).font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        if r.source == .appLocal {
                            DeleteButton(compactSize: 20, isDisabled: current?.source == .appLocal, help: "Remove the app-only Node.js") { confirmRemoveLocal = true }
                        }
                    }
                }
            }
        }
    }

    private var packagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("AWS SDK packages")
            if let packages {
                let installed = packages.services.values.filter(\.installed).count
                Text("\(installed) of \(packages.services.count) services installed · SDK \(packages.sdkVersion)\(packages.failures.isEmpty ? "" : " · \(packages.failures.count) failed")")
                    .font(.callout)
                HStack {
                    Text(packages.modulesDir).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    RevealButton("Show in Finder", compactSize: 22) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: packages.modulesDir)])
                    }
                    OpenButton("Manage in Services", compactSize: 22, action: onOpenServices)
                }
                Text("Installed with the Node.js the app runs on; any npm works too (the app picks packages up right away).").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Unavailable while the local API is down.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(color.opacity(0.15)).foregroundStyle(color).clipShape(Capsule())
    }

    private func label(_ r: NodeRuntime) -> String {
        "v\(r.nodeVersion) · npm \(r.npmVersion.map(\.description) ?? "-") · \(r.source.label)"
    }

    private func runtimeSummary(_ r: NodeRuntime) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Node.js v\(r.nodeVersion) · npm \(r.npmVersion.map(\.description) ?? "-")").font(.callout.bold())
                Text("\(r.source.label) · \(r.binDirectory.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if case .outdated = RuntimeManager.classify(r) { badge("out of support - update recommended", .orange) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Actions

    private func reload() async {
        let manager = RuntimeManager.shared
        async let found = manager.detectAll()
        async let nvm = manager.nvmVersion()
        async let def = manager.nvmDefaultVersion()
        runtimes = await found
        nvmVersion = await nvm
        nvmDefault = await def
        nvmVersions = manager.nvmInstalledVersions()
        preference = try? await api.getRuntimePreference()
        choice = preference?.preferredNodeBin ?? ""
        packages = try? await api.getPackagesStatus()
        loading = false
        if releases.isEmpty {
            do {
                releases = try await manager.availableReleases()
                selectedRelease = releases.first { $0.lts != nil && $0.major == RuntimeManager.installMajor }?.version ?? releases.first?.version ?? ""
                releaseError = nil
            } catch {
                releaseError = "Couldn't load the release list from nodejs.org: \(error.localizedDescription)"
            }
        }
    }

    private func apply() async {
        applying = true
        applyMessage = nil
        defer { applying = false }
        do {
            preference = try await api.setRuntimePreference(choice.isEmpty ? nil : choice)
        } catch {
            applyMessage = error.friendlyMessage
            return
        }
        if choice.isEmpty {
            _ = await RuntimeManager.shared.check()
        } else if let r = runtimes.first(where: { $0.binDirectory.path == choice }) {
            RuntimeManager.shared.use(r)
        }
        let ok = await SidecarManager.shared.restart { applyMessage = $0 }
        applyMessage = ok ? "The local API now runs on Node.js \(current.map { "v\($0.nodeVersion)" } ?? "-")." : (SidecarManager.shared.lastFailure ?? "The local API didn't come back - check the Node.js choice and try again.")
        await reload()
    }

    private func installNvmTask() {
        task = RuntimeTask(title: nvmVersion == nil ? "Installing nvm…" : "Updating nvm…", success: nil, failureCommand: { RuntimeManager.shared.manualNvmInstallCommand(tag: nil) }) { log in
            let tag = try await RuntimeManager.shared.installNvm(log: log)
            return "nvm \(tag) installed"
        }
    }

    private func release() -> RuntimeManager.NodeRelease {
        RuntimeManager.NodeRelease(version: selectedRelease, tarball: "node-\(selectedRelease)-darwin-\(RuntimeManager.platformArch).tar.gz")
    }

    private func installWithNvm() {
        let v = selectedRelease
        let setDefault = makeDefault
        task = RuntimeTask(title: "Installing Node.js \(v) with nvm…", success: nil, failureCommand: { RuntimeManager.shared.manualNvmInstallCommand(tag: nil, node: v) }) { log in
            if !RuntimeManager.isNvmInstalled { _ = try await RuntimeManager.shared.installNvm(log: log) }
            let r = try await RuntimeManager.shared.installNodeWithNvm(v, setDefault: setDefault, log: log)
            return "Node.js \(r.nodeVersion) installed with nvm\(setDefault ? " (default)" : "")"
        }
    }

    private func installPkg() {
        let r = release()
        // The app keeps running on its current Node; switch with "Apply and restart".
        let previous = RuntimeManager.shared.selected
        task = RuntimeTask(title: "Installing Node.js \(r.version) system-wide…", success: nil, failureCommand: { RuntimeManager.shared.manualPkgInstallCommand(r) }) { log in
            let installed = try await RuntimeManager.shared.installSystemNode(r, log: log)
            if let previous { RuntimeManager.shared.use(previous) }
            return "Node.js \(installed.nodeVersion) installed in /usr/local/bin"
        }
    }

    private func installLocal() {
        let r = release()
        let previous = RuntimeManager.shared.selected
        task = RuntimeTask(title: "Installing Node.js \(r.version) for AWS Visualizer…", success: nil, failureCommand: { RuntimeManager.shared.manualNodeInstallCommand(r) }) { log in
            let installed = try await RuntimeManager.shared.installNode(r, log: log)
            if let previous { RuntimeManager.shared.use(previous) }
            return "Node.js \(installed.nodeVersion) installed for AWS Visualizer"
        }
    }
}

/// One Settings action with its terminal.
struct RuntimeTask: Identifiable {
    let id = UUID()
    let title: String
    var success: String?
    var failureCommand: (() -> String)?
    /// Returns the success title (overrides `success`), throws on failure.
    let run: (TaskLog) async throws -> String?

    init(title: String, success: String?, failureCommand: (() -> String)? = nil, run: @escaping (TaskLog) async throws -> String?) {
        self.title = title
        self.success = success
        self.failureCommand = failureCommand
        self.run = run
    }

    init(title: String, success: String, run: @escaping (TaskLog) async throws -> Void) {
        self.init(title: title, success: success) { log in
            try await run(log)
            return nil
        }
    }
}

struct RuntimeTaskSheet: View {
    let task: RuntimeTask
    var onClose: () -> Void

    @State private var log = TaskLog()
    @State private var successTitle: String?

    var body: some View {
        VStack(spacing: 14) {
            InstallProgressPanel(title: task.title, steps: log.steps, isRunning: log.isRunning, noun: "steps", successTitle: successTitle) { _ in
                Task { await run() }
            }
            HStack {
                Spacer()
                SecondaryButton(log.isRunning ? "Running…" : "Close", isDisabled: log.isRunning, action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 600)
        .task { await run() }
    }

    private func run() async {
        log.reset()
        successTitle = nil
        do {
            let title = try await task.run(log)
            successTitle = title ?? task.success
            log.done()
        } catch {
            log.fail(error.localizedDescription, command: task.failureCommand?())
        }
    }
}
