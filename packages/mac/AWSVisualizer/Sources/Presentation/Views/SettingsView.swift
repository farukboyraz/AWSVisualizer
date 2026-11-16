import SwiftUI

/// Everything in this sheet edits a local draft - nothing reaches
/// `appState` or `~/.awsvisualizer` until "Save Changes" is pressed
/// (`saveAll()`). The corner close button (`ConfirmingCloseButton`) warns
/// before discarding a dirty draft, the same pattern the Filter Builder
/// popup uses.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var page: SettingsPage

    init(initialPage: SettingsPage = .general) {
        _page = State(initialValue: initialPage)
    }
    @State private var expandedGroups: Set<SettingsPage> = [.display, .services]
    @State private var showRawConfig = false
    @State private var workspaceEntries: [WorkspaceEntry] = []

    // AWS SSO - `awsConfig` is the editable draft, `loadedAwsConfig` the
    // last-saved baseline `isDirty` compares it against.
    @State private var awsConfig: AwsConfigSection?
    @State private var loadedAwsConfig: AwsConfigSection?

    // Draft copies of every other "live" setting - bound to by the controls
    // below instead of `appState` directly.
    @State private var draftMaxTabs = 7
    @State private var draftDevTools = DevToolsConfig.empty
    @State private var draftDynamoDbAutoColumnWidth = true
    @State private var draftDynamoDbItemView: DynamoItemViewMode = .json
    @State private var draftCodeTheme: CodeThemeID = .vscode
    @State private var draftLayoutMode: LayoutMode = .sideBySide
    @State private var draftWordWrap = false
    @State private var draftFileIconTheme: FileIconTheme = .colorful
    @State private var draftHistoryLayout: LayoutMode = .singlePage
    @State private var draftButtonColors = ButtonColorConfig.defaults
    @State private var draftDefaultIDEBundleIdentifier = ""
    @State private var draftSelectedServices: Set<String> = []
    @State private var draftDashboard = DashboardPrefs.defaults
    @State private var draftDefaultServices: Set<String> = []
    /// Default services saved whose packages are missing - offered for install.
    @State private var installAfterSave: InstallAfterSave?

    private struct InstallAfterSave: Identifiable {
        let id = UUID()
        let services: [String]
    }

    @State private var isSaving = false
    @State private var saveError: String?
    @State private var justSaved = false

    private var isDirty: Bool {
        draftMaxTabs != appState.maxTabs
            || draftDevTools != appState.devTools
            || draftDynamoDbAutoColumnWidth != appState.dynamoDbAutoColumnWidth
            || draftDynamoDbItemView != appState.dynamoDbItemView
            || draftCodeTheme != appState.codeTheme
            || draftLayoutMode != appState.layoutMode
            || draftWordWrap != appState.wordWrapDefault
            || draftFileIconTheme != appState.fileIconTheme
            || draftHistoryLayout != appState.historyLayout
            || draftButtonColors != appState.buttonColors
            || draftDefaultIDEBundleIdentifier != appState.defaultIDEBundleIdentifier
            || draftSelectedServices != Set(appState.selectedServiceIDs)
            || draftDashboard.normalized != appState.dashboardPrefs.normalized
            || draftDefaultServices != Set(appState.userDefaultServiceIDs)
            || (awsConfig != nil && awsConfig != loadedAwsConfig)
    }

    private var dirtyPages: Set<SettingsPage> {
        var pages = Set<SettingsPage>()
        if draftMaxTabs != appState.maxTabs { pages.insert(.general) }
        if awsConfig != nil && awsConfig != loadedAwsConfig { pages.insert(.platforms) }
        if draftLayoutMode != appState.layoutMode || draftWordWrap != appState.wordWrapDefault
            || draftFileIconTheme != appState.fileIconTheme
            || draftCodeTheme != appState.codeTheme { pages.insert(.display) }
        if draftHistoryLayout != appState.historyLayout { pages.insert(.displayCodeCommit) }
        if draftDashboard.normalized != appState.dashboardPrefs.normalized { pages.insert(.dashboard) }
        if draftDefaultServices != Set(appState.userDefaultServiceIDs) { pages.insert(.defaultServices) }
        if draftButtonColors != appState.buttonColors { pages.insert(.buttons) }
        if draftSelectedServices != Set(appState.selectedServiceIDs) { pages.insert(.services) }
        if draftDynamoDbAutoColumnWidth != appState.dynamoDbAutoColumnWidth || draftDynamoDbItemView != appState.dynamoDbItemView { pages.insert(.dynamoDb) }
        if draftDevTools != appState.devTools
            || draftDefaultIDEBundleIdentifier != appState.defaultIDEBundleIdentifier { pages.insert(.developer) }
        return pages
    }

    private func menuRow(_ item: SettingsPage) -> some View {
        HStack(spacing: 8) {
            Label(item.title, systemImage: item.systemImage)
            Spacer(minLength: 4)
            if dirtyPages.contains(item) || item.children.contains(where: dirtyPages.contains) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
        }
        .tag(item)
    }

    @ViewBuilder
    private var currentPage: some View {
        switch page {
        case .general: generalPage
        case .platforms: platformsPage
        case .display: displayPage
        case .displayCodeCommit: displayCodeCommitPage
        case .dashboard: DashboardSettingsPage(prefs: $draftDashboard)
        case .buttons: buttonsPage
        case .services: servicesPage
        case .defaultServices: defaultServicesPage
        case .dynamoDb: dynamoDbPage
        case .codeCommit: codeCommitPage
        case .runtime: RuntimeSettingsPage { page = .services }
        case .about: AboutPage(onOpenPage: { page = $0 }, onShowRawConfig: { showRawConfig = true })
        case .developer: developerPage
        }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            AccountInfoSection()

            Divider()

            HStack(alignment: .top, spacing: 32) {
                ProfilePicker()
                RegionPicker()
            }

            HStack(alignment: .top, spacing: 32) {
                LanguagePicker()
                AppearancePicker()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Number of screens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(value: $draftMaxTabs, in: 1...10) {
                    Text("\(draftMaxTabs) tab\(draftMaxTabs == 1 ? "" : "s") open at once")
                }
                Text("Each screen keeps its own view and can be switched independently, like browser tabs.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
    private var platformsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            awsConfigSection

            Divider()

            AccessibleEnvironmentsSection(environments: appState.accessibleEnvironments, allowsEditing: true)
        }
    }
    private var displayPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Layout")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("List and details")
                    Spacer()
                    MultiSwitchBox(
                        selection: $draftLayoutMode,
                        options: LayoutMode.allCases.map { ($0, $0.label) }
                    )
                }
                Text("Side by side: the list (tables, buckets, functions…) on the left, the selected one on the right. Single page: the list fills the window, opening an item replaces it and Back returns to the list.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                LabeledSwitchBox(title: "Word Wrap", isOn: $draftWordWrap)
                Text("Long lines in every text / code viewer wrap to the width instead of scrolling sideways. View → Word Wrap (⌥Z) turns it on or off on the spot.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                HStack {
                    Text("File icons")
                    Spacer()
                    MultiSwitchBox(
                        selection: $draftFileIconTheme,
                        options: FileIconTheme.allCases.map { ($0, $0.label) }
                    )
                }
                // Live preview of the picked theme.
                HStack(spacing: 14) {
                    ForEach(["Reports/", "plan.eff", "config.json", "Program.cs", "layout.xml", "README.md", "logo.png", "notes.txt"], id: \.self) { name in
                        HStack(spacing: 4) {
                            FileIcon(name: name, isFolder: name.hasSuffix("/"))
                            Text(name.hasSuffix("/") ? String(name.dropLast()) : name).font(.caption)
                        }
                    }
                }
                .environment(\.fileIconTheme, draftFileIconTheme)
                Text("How files and folders look in S3, archives, CodeCommit, Lambda's code and diff file lists.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            codeThemeSection
        }
    }
    /// Display › CodeCommit: how CodeCommit screens are laid out.
    private var displayCodeCommitPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("File history")
                Spacer()
                MultiSwitchBox(
                    selection: $draftHistoryLayout,
                    options: LayoutMode.allCases.map { ($0, $0.label) }
                )
            }
            Text("CodeCommit → Files → History: Single page opens it over the file (Content switches back); Side by side splits the pane - code left, history right, drag the divider to resize.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var buttonsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            buttonColorsSection
        }
    }
    /// Fills the page height (no outer scroll) so the list itself scrolls.
    private var servicesPage: some View {
        ServiceSelectionList(mode: .settings, selection: $draftSelectedServices)
    }

    /// Services › Select Default Services: the first-sign-in picks.
    private var defaultServicesPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appState.language.defaultsNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ServiceSelectionList(mode: .onboarding, selection: $draftDefaultServices)
        }
    }

    private var dynamoDbPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledSwitchBox(title: "Auto Column Width", isOn: $draftDynamoDbAutoColumnWidth)
            Text("Sizes each column in the scan results grid to fit its longest value instead of splitting the available width evenly.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Text("Item view")
                Spacer()
                MultiSwitchBox(
                    selection: $draftDynamoDbItemView,
                    options: DynamoItemViewMode.allCases.map { ($0, $0.label) }
                )
            }
            Text("Which view an item opens in: plain JSON, typed DynamoDB JSON ({\"S\": ...}), or the console-style attribute form. You can still switch inside the item popup.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var codeCommitPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspaces")
                .font(.caption)
                .foregroundStyle(.secondary)
            if workspaceEntries.isEmpty {
                Text("No repositories matched or cloned yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(workspaceEntries) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(entry.repositoryName).font(.caption.monospaced().bold())
                            Text(entry.localPath).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            Text("A workspace links a CodeCommit repository to its local clone (Workspace tab, Compare Workspace).")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var developerPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Dev Tools panel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DevToolsSettings(config: $draftDevTools)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Code editor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $draftDefaultIDEBundleIdentifier) {
                    Text("No preference").tag("")
                    ForEach(IDERegistry.installed()) { ide in
                        Text(ide.name).tag(ide.bundleIdentifier)
                    }
                }
                .labelsHidden()
                Text("Which IDE \"Open in <IDE>\" (e.g. Lambda's Code tab) preselects. \"No preference\" falls back to the first installed one found.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                Spacer()
                ConfirmingCloseButton(
                    requiresConfirmation: isDirty,
                    confirmationTitle: appState.language.discardChangesTitle,
                    confirmationMessage: appState.language.discardChangesMessage,
                    confirmButtonTitle: appState.language.yesButtonTitle,
                    cancelButtonTitle: appState.language.noButtonTitle,
                    action: { dismiss() }
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                List(selection: Binding(get: { page }, set: { if let value = $0 { page = value } })) {
                    ForEach(SettingsPage.topLevel) { item in
                        if item.children.isEmpty {
                            menuRow(item)
                        } else {
                            DisclosureGroup(isExpanded: Binding(
                                get: { expandedGroups.contains(item) },
                                set: { isOn in if isOn { expandedGroups.insert(item) } else { expandedGroups.remove(item) } }
                            )) {
                                ForEach(item.children) { child in
                                    menuRow(child)
                                }
                            } label: {
                                menuRow(item)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 220)

                Divider()

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let parent = page.parent {
                            Text(parent.title.uppercased()).font(.caption2.bold()).foregroundStyle(.tertiary)
                        }
                        Text(page.title).font(.title3.bold())
                        Text(page.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    if page.fillsHeight {
                        currentPage
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        ScrollView {
                            currentPage
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 8)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(page)
            }

            Divider()

            HStack {
                Button {
                    showRawConfig = true
                } label: {
                    Label("View ~/.awsvisualizer", systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                if justSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                SaveButton("Save Changes", isLoading: isSaving, isDisabled: !isDirty) {
                    Task { await saveAll() }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 860, idealWidth: 960, maxWidth: .infinity, minHeight: 620, idealHeight: 720, maxHeight: .infinity)
        .resizableSheet(minWidth: 860, minHeight: 620)
        .task {
            draftMaxTabs = appState.maxTabs
            draftDevTools = appState.devTools
            draftDynamoDbAutoColumnWidth = appState.dynamoDbAutoColumnWidth
            draftDynamoDbItemView = appState.dynamoDbItemView
            draftCodeTheme = appState.codeTheme
            draftLayoutMode = appState.layoutMode
            draftWordWrap = appState.wordWrapDefault
            draftFileIconTheme = appState.fileIconTheme
            draftHistoryLayout = appState.historyLayout
            draftDashboard = appState.dashboardPrefs
            draftDefaultServices = Set(appState.userDefaultServiceIDs)
            draftButtonColors = appState.buttonColors
            draftDefaultIDEBundleIdentifier = appState.defaultIDEBundleIdentifier
            draftSelectedServices = appState.selectedServiceIDs.isEmpty
                ? Set(appState.serviceCatalog.filter(\.implemented).map(\.id))
                : Set(appState.selectedServiceIDs)
            await loadAccessibleEnvironments()
            await loadAwsConfig()
            await loadWorkspaces()
        }
        .sheet(isPresented: $showRawConfig) {
            RawConfigFileView()
        }
        .sheet(item: $installAfterSave) { request in
            PackageInstallSheet(services: request.services) { installAfterSave = nil }
        }
    }

    /// Every dirty field is pushed to the backend and `appState` together -
    /// only the fields that actually changed make a request. `appState`
    /// only updates *after* its matching request succeeds, so a failed
    /// save leaves both the live app and the draft's "what's actually
    /// saved" baseline untouched (the draft itself, still showing the
    /// user's edits, is left alone either way).
    private func saveAll() async {
        isSaving = true
        saveError = nil
        justSaved = false
        do {
            if draftMaxTabs != appState.maxTabs {
                _ = try await api.updateMaxTabs(draftMaxTabs)
                appState.maxTabs = draftMaxTabs
            }
            if draftDevTools != appState.devTools {
                try await api.updateDevTools(draftDevTools)
                appState.devTools = draftDevTools
            }
            if draftDynamoDbAutoColumnWidth != appState.dynamoDbAutoColumnWidth {
                _ = try await api.updateDynamoDbAutoColumnWidth(draftDynamoDbAutoColumnWidth)
                appState.dynamoDbAutoColumnWidth = draftDynamoDbAutoColumnWidth
            }
            if draftDynamoDbItemView != appState.dynamoDbItemView {
                _ = try await api.updateDynamoDbItemView(draftDynamoDbItemView)
                appState.dynamoDbItemView = draftDynamoDbItemView
            }
            if draftCodeTheme != appState.codeTheme {
                _ = try await api.updateCodeTheme(draftCodeTheme)
                appState.codeTheme = draftCodeTheme
            }
            if draftLayoutMode != appState.layoutMode || draftWordWrap != appState.wordWrapDefault || draftFileIconTheme != appState.fileIconTheme || draftHistoryLayout != appState.historyLayout {
                _ = try await api.updateViewPreferences(layoutMode: draftLayoutMode, wordWrap: draftWordWrap, fileIconTheme: draftFileIconTheme, historyLayout: draftHistoryLayout)
                appState.historyLayout = draftHistoryLayout
                appState.fileIconTheme = draftFileIconTheme
                appState.layoutMode = draftLayoutMode
                if draftWordWrap != appState.wordWrapDefault { appState.wordWrap = draftWordWrap }
                appState.wordWrapDefault = draftWordWrap
            }
            if draftDashboard.normalized != appState.dashboardPrefs.normalized {
                let saved = try await api.updateDashboardPrefs(draftDashboard)
                appState.dashboardPrefs = saved.dashboard ?? draftDashboard.normalized
                draftDashboard = appState.dashboardPrefs
            }
            if draftDefaultServices != Set(appState.userDefaultServiceIDs) {
                let added = draftDefaultServices.subtracting(appState.userDefaultServiceIDs)
                // Catalog order, so the saved list is stable.
                let ordered = appState.serviceCatalog.map(\.id).filter(draftDefaultServices.contains)
                try await api.setUserDefaultServices(ordered)
                appState.userDefaultServiceIDs = ordered
                let missing = appState.serviceCatalog.filter { added.contains($0.id) && $0.needsPackageInstall }.map(\.id)
                if !missing.isEmpty { installAfterSave = InstallAfterSave(services: missing) }
            }
            if draftButtonColors != appState.buttonColors {
                _ = try await api.updateButtonColors(draftButtonColors)
                appState.buttonColors = draftButtonColors
            }
            if draftDefaultIDEBundleIdentifier != appState.defaultIDEBundleIdentifier {
                _ = try await api.updateDefaultIDE(draftDefaultIDEBundleIdentifier)
                appState.defaultIDEBundleIdentifier = draftDefaultIDEBundleIdentifier
            }
            if draftSelectedServices != Set(appState.selectedServiceIDs) {
                try await appState.saveSelectedServices(draftSelectedServices, using: api)
            }
            if let awsConfig, awsConfig.defaultRegion != loadedAwsConfig?.defaultRegion {
                let updated = try await api.updateDefaultRegion(awsConfig.defaultRegion)
                self.awsConfig = updated.aws
                loadedAwsConfig = updated.aws
            }
            justSaved = true
        } catch {
            saveError = error.friendlyMessage
        }
        isSaving = false
    }

    // MARK: - Code theme

    private static let previewCode = """
    using System.Text.Json;

    // Reads the app settings
    public class SettingsLoader {
        public async Task<Settings> LoadAsync(string path) {
            if (!File.Exists(path)) return Settings.Default;
            var json = await File.ReadAllTextAsync(path);
            return JsonSerializer.Deserialize<Settings>(json) ?? new Settings { Retries = 3 };
        }
    }
    """

    private var codeThemeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Code")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("Syntax theme")
                Spacer()
                Picker("", selection: $draftCodeTheme) {
                    ForEach(CodeThemeID.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 260)
            }
            let theme = draftCodeTheme.theme
            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.highlightForText(Self.previewCode, language: .csharp, theme: theme, fontSize: 11.5))
                    .lineSpacing(2)
                    .fixedSize()
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.swiftUIBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            Text("Colors for every code / file viewer (CodeCommit files, Markdown code blocks). \"VS Code\" matches VS Code's default Light+ / Dark+ themes and follows the app's light/dark mode.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Button Colors

    private var buttonColorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Button Colors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if AppButtonKind.allCases.contains(where: { draftButtonColors[$0].caseInsensitiveCompare($0.defaultHex) != .orderedSame }) {
                    Button("Reset all") {
                        for kind in AppButtonKind.allCases { draftButtonColors[kind] = kind.defaultHex }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(AppButtonKind.allCases) { kind in
                    ButtonColorCard(
                        kind: kind,
                        hex: Binding(get: { draftButtonColors[kind] }, set: { draftButtonColors[kind] = $0 })
                    )
                }
            }
            Text("Filled kinds pick black or white text automatically for contrast; tinted kinds (Secondary, Clear, Stop) use the color for a soft background and the text. Previews show the unsaved choice - Save Changes applies it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - AWS platforms

    @ViewBuilder
    private var awsConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlatformsSection()
            Divider()
            PersonalAccountsSection()
            if let config = Binding($awsConfig) {
                LabeledField(label: "Default region") {
                    TextField("eu-west-1", text: config.defaultRegion)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
        }
    }

    private func loadAccessibleEnvironments() async {
        if let environments = try? await api.getAccessibleEnvironments() {
            appState.accessibleEnvironments = environments
        }
    }

    private func loadAwsConfig() async {
        if let config = try? await api.getAppConfig() {
            awsConfig = config.aws
            loadedAwsConfig = config.aws
        }
    }

    private func loadWorkspaces() async {
        if let entries = try? await api.listWorkspaces() {
            workspaceEntries = entries
        }
    }
}

/// Read-only popup showing exactly what's on disk at `~/.awsvisualizer` -
/// reuses `StructuredContentView` (Formatted/Tree JSON toggle, syntax
/// highlight) rather than a plain `TextEditor`, since the file is JSON and
/// this component already exists for exactly that.
private struct RawConfigFileView: View {
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var rawText: String?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("~/.awsvisualizer")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            content
                .padding(.horizontal)
                .padding(.bottom)
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 480, idealHeight: 600)
        .task {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let rawText {
            StructuredContentView(text: rawText, kind: .json)
        } else if let loadError {
            VStack(spacing: 8) {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                RefreshButton("Retry") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            BrandedLoader(message: "Loading config file…")
        }
    }

    private func load() async {
        loadError = nil
        do {
            rawText = try await api.getRawConfigFile()
        } catch {
            loadError = error.friendlyMessage
        }
    }
}

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One button kind's color editor: live preview, preset palette, custom
/// color picker and hex field, Reset when it differs from the default.
private struct ButtonColorCard: View {
    let kind: AppButtonKind
    @Binding var hex: String

    @State private var hexText = ""
    @State private var isHovering = false

    private var isDefault: Bool { hex.caseInsensitiveCompare(kind.defaultHex) == .orderedSame }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(kind.displayName)
                    .font(.callout.bold())
                Spacer()
                if !isDefault {
                    Button {
                        hex = kind.defaultHex
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to default (\(kind.defaultHex))")
                }
            }

            HStack {
                preview
                Spacer()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 8), alignment: .leading, spacing: 6) {
                ForEach(AppButtonKind.presetColors, id: \.self) { preset in
                    swatch(preset)
                }
            }

            HStack(spacing: 8) {
                ColorPicker("", selection: Binding(
                    get: { Color(hex: hex) },
                    set: { hex = $0.hexString }
                ))
                .labelsHidden()
                .help("Custom color")
                TextField("#RRGGBB", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .frame(width: 90)
                    .onSubmit(applyHexText)
                if isDefault {
                    Text("Default")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(isHovering ? 0.10 : 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
        .onHover { isHovering = $0 }
        .onAppear { hexText = hex.uppercased() }
        .onChange(of: hex) { _, newValue in hexText = newValue.uppercased() }
    }

    private var preview: some View {
        let icon = kind.defaultSystemImage
        return HStack(spacing: 10) {
            Button {} label: {
                HStack(spacing: 5) {
                    if !icon.isEmpty { Image(systemName: icon) }
                    Text(kind == .newItem ? "New" : kind.displayName.components(separatedBy: " ").first ?? kind.displayName)
                }
            }
            .buttonStyle(AppButtonStyle(color: Color(hex: hex), variant: kind.variant, isCompact: false))
            if !icon.isEmpty {
                Button {} label: { Image(systemName: icon) }
                    .buttonStyle(AppButtonStyle(color: Color(hex: hex), variant: kind.variant, isCompact: true))
            }
        }
        .allowsHitTesting(false)
    }

    private func swatch(_ preset: String) -> some View {
        let isSelected = hex.caseInsensitiveCompare(preset) == .orderedSame
        let color = Color(hex: preset)
        return ZStack {
            Circle().fill(color)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color.contrastingContentColor)
            }
        }
        .frame(width: 22, height: 22)
        .overlay(Circle().stroke(Color.primary.opacity(isSelected ? 0.8 : 0.12), lineWidth: isSelected ? 2 : 1))
        .contentShape(Circle())
        .onTapGesture { hex = preset }
        .help(preset)
    }

    private func applyHexText() {
        var value = hexText.trimmingCharacters(in: .whitespaces).uppercased()
        if !value.hasPrefix("#") { value = "#" + value }
        let digits = value.dropFirst()
        if digits.count == 6, digits.allSatisfy(\.isHexDigit) {
            hex = value
        } else {
            hexText = hex.uppercased()
        }
    }
}

/// Left-hand menu of the Settings window. Pages with a `parent` show as a
/// sub-list under it (Services › DynamoDB, ...).
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general, platforms, display, displayCodeCommit, dashboard, buttons, services, defaultServices, dynamoDb, codeCommit, runtime, developer, about

    var id: String { rawValue }

    var parent: SettingsPage? {
        switch self {
        case .defaultServices, .dynamoDb, .codeCommit: return .services
        case .displayCodeCommit, .dashboard: return .display
        default: return nil
        }
    }

    var children: [SettingsPage] { Self.allCases.filter { $0.parent == self } }

    static var topLevel: [SettingsPage] { allCases.filter { $0.parent == nil } }

    /// Pages whose content scrolls by itself (a List) instead of in the page.
    var fillsHeight: Bool { self == .services || self == .defaultServices }

    var title: String {
        switch self {
        case .general: return "General"
        case .platforms: return "Platforms & Accounts"
        case .display: return "Display"
        case .displayCodeCommit: return "CodeCommit"
        case .dashboard: return "Dashboard"
        case .buttons: return "Button Colors"
        case .services: return "Services"
        case .defaultServices: return "Select Default Services"
        case .dynamoDb: return "DynamoDB"
        case .codeCommit: return "CodeCommit"
        case .runtime: return "Node.js & Packages"
        case .developer: return "Developer"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Account, profile, region, language, appearance and tabs."
        case .platforms: return "AWS access portals you sign in to and the profiles of their accounts."
        case .display: return "Layout, word wrap, file icons and code colors."
        case .displayCodeCommit: return "How CodeCommit's screens are laid out."
        case .dashboard: return "Which sections the dashboard shows, its cost view and colors. Hidden sections send no AWS requests."
        case .buttons: return "Colors of every button kind in the app."
        case .services: return "Which services appear in the sidebar. Stars mark favorites (saved right away); the selection is saved with Save Changes."
        case .defaultServices: return "The services picked on first sign-in; \"Select default\" selects these."
        case .dynamoDb: return "Results grid and item popup."
        case .codeCommit: return "Repositories linked to a local clone."
        case .runtime: return "The Node.js the app runs on, nvm and its versions, and the AWS SDK packages. Changes apply right away."
        case .developer: return "Dev Tools panel and the IDE for \"Open in\"."
        case .about: return "Version, privacy, what the app does and doesn't do, and where its files are."
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .platforms: return "person.2.badge.key"
        case .display: return "paintbrush"
        case .displayCodeCommit: return "chevron.left.forwardslash.chevron.right"
        case .dashboard: return "rectangle.3.group"
        case .buttons: return "paintpalette"
        case .services: return "square.grid.2x2"
        case .defaultServices: return "checklist"
        case .dynamoDb: return "tablecells"
        case .codeCommit: return "chevron.left.forwardslash.chevron.right"
        case .runtime: return "shippingbox"
        case .developer: return "hammer"
        case .about: return "info.circle"
        }
    }
}
