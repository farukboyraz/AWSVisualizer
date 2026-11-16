import SwiftUI
import AppKit

/// Mirrors a function's page in the Lambda console - both its tab order
/// (Code, Test, Monitor, Configuration, Aliases, Versions) and its
/// navigation model: opening a function replaces the list entirely (no
/// permanent list-plus-detail split like KMS/EC2/SQS use), matching how the
/// console itself has no "all functions" panel once you're on one
/// function's page. `onBack` returns to `LambdaView`'s list.
struct LambdaFunctionDetailView: View {
    let functionName: String
    var onBack: () -> Void
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    private enum DetailTab: String, CaseIterable {
        case code = "Code"
        case test = "Test"
        case monitor = "Monitor"
        case configuration = "Configuration"
        case aliases = "Aliases"
        case versions = "Versions"
    }

    @State private var tab: DetailTab = .code
    @State private var detailState: LoadState<LambdaFunctionDetail> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Button {
                            onBack()
                        } label: {
                            Label("Functions", systemImage: "chevron.left")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Divider().frame(height: 16)

                        Text(detail.functionName)
                            .font(.title2.bold())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let state = detail.state {
                            StatusBadge(state)
                        }
                    }
                    .padding([.horizontal, .top])
                    .padding(.bottom, 4)

                    TabBar(selection: $tab)
                    .padding(.bottom, 8)

                    Group {
                        switch tab {
                        case .code:
                            LambdaCodeView(detail: detail)
                        case .test:
                            LambdaTestView(functionName: functionName)
                        case .monitor:
                            LambdaMonitorView(functionName: functionName)
                        case .configuration:
                            LambdaConfigurationView(detail: detail, onUpdated: { detailState = .loaded($0) }, onDeleted: onDeleted)
                        case .aliases:
                            LambdaAliasesView(functionName: functionName)
                        case .versions:
                            LambdaVersionsView(functionName: functionName)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: functionName) {
            await loadDetail()
        }
    }

    private func loadDetail() async {
        detailState = .loading
        do {
            let detail = try await api.getLambdaFunctionDetail(profile: appState.currentProfile, region: appState.currentRegion, functionName: functionName)
            detailState = .loaded(detail)
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

private func lambdaReadOnlyRow(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        Text(value)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

// MARK: - Code

/// Read-only source browser - viewing in place is supported (unzips the
/// same deployment package the console's "Download" button links to, see
/// `loadCodeZip`/`getCodeEntryContent` in `lambda.ts`), but *editing* isn't:
/// there's no `UpdateFunctionCode` call anywhere here. Deploy through the
/// usual pipeline (SAM/CDK/CLI/an IDE) and use the other tabs to manage
/// this function's configuration, triggers, and versions.
///
/// **"Open in <IDE>"** (`OpenInIDEControl`, `Components/IDELauncher.swift`)
/// exists because the in-app preview is plain text - no per-language syntax
/// highlighting - and can't show anything for binary entries (compiled
/// `.dll`/`.class`/etc., see `getCodeEntryContent`'s binary check). Rather
/// than building a multi-language highlighter from scratch, the backend
/// unzips the deployment package to a local temp folder
/// (`exportCodeToLocalDirectory`, `lambda.ts` - sidecar and Swift app share
/// the same Mac, so a plain filesystem path is all that's needed) and the
/// chosen IDE opens that folder directly - the same thing the console's own
/// "Open in Visual Studio Code" button does, just not limited to VS Code.
/// **This doesn't make compiled languages any more readable in any IDE** -
/// a .NET function's package contains compiled `.dll` assemblies, never the
/// original C# source (AWS's own console can't show source for compiled
/// runtimes either, only Node.js/Python/Ruby get inline editing) - whatever
/// IDE opens it will show the same "binary, not displayed" as this app's
/// own preview for those files, just with the rest of the tree browsable
/// around them.
private struct LambdaCodeView: View {
    let detail: LambdaFunctionDetail

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var entriesState: LoadState<[ZipEntry]> = .loading
    @State private var selectedEntry: ZipEntry?
    @State private var contentState: LoadState<ZipEntryContent> = .empty
    @State private var openError: String?

    var body: some View {
        ResizableSplitView(initialWidth: 260, minWidth: 200, maxWidth: 420) {
            fileTreePanel
        } right: {
            if let selectedEntry {
                previewPanel(selectedEntry)
                    .id(selectedEntry.id)
            } else {
                EmptyStateView(message: "Select a file")
            }
        }
        .task(id: detail.functionName) {
            await loadEntries()
        }
    }

    private var fileTreePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Files")
                    .font(.subheadline.bold())
                Spacer()
                OpenInIDEControl(action: { ide in await openInIDE(ide) }, help: "Extract this function's code to a local folder and open it in the selected IDE")

                if let codeLocation = detail.codeLocation, let url = URL(string: codeLocation) {
                    DownloadButton(help: "Download deployment package (.zip)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(10)

            if let openError {
                Text(openError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            LoadableContent(entriesState, retry: { Task { await loadEntries() } }, emptyMessage: "No files") { entries in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        PathTreeView(nodes: buildPathTree(entries.filter { !$0.isDirectory }, path: { $0.path }), initiallyExpanded: false) { entry in
                            fileRow(entry)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func fileRow(_ entry: ZipEntry) -> some View {
        let fileName = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
        return Button {
            select(entry)
        } label: {
            HStack(spacing: 6) {
                FileIcon(name: fileName)
                    .font(.caption2)
                Text(fileName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(selectedEntry?.id == entry.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func previewPanel(_ entry: ZipEntry) -> some View {
        LoadableContent(contentState, retry: { Task { await loadContent(entry) } }) { content in
            StructuredContentView(text: content.content, kind: StructuredKind.classify(path: entry.path))
        }
    }

    private func select(_ entry: ZipEntry) {
        selectedEntry = entry
        Task { await loadContent(entry) }
    }

    private func openInIDE(_ ide: IDEDescriptor) async {
        openError = nil
        do {
            let localPath = try await api.exportLambdaCodeToLocalDirectory(profile: appState.currentProfile, region: appState.currentRegion, functionName: detail.functionName)
            guard let appURL = IDERegistry.resolvedURL(for: ide) else {
                openError = "\(ide.name) is no longer available."
                return
            }
            _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: localPath)], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            openError = error.friendlyMessage
        }
    }

    private func loadEntries() async {
        entriesState = .loading
        selectedEntry = nil
        contentState = .empty
        do {
            let entries = try await api.getLambdaCodeEntries(profile: appState.currentProfile, region: appState.currentRegion, functionName: detail.functionName)
            entriesState = entries.isEmpty ? .empty : .loaded(entries)
        } catch {
            entriesState = .failed(error.friendlyMessage)
        }
    }

    private func loadContent(_ entry: ZipEntry) async {
        contentState = .loading
        do {
            let content = try await api.getLambdaCodeEntryContent(profile: appState.currentProfile, region: appState.currentRegion, functionName: detail.functionName, path: entry.path)
            contentState = .loaded(content)
        } catch {
            contentState = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Test / Invoke

private struct LambdaTestView: View {
    let functionName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var payload = "{}"
    @State private var isInvoking = false
    @State private var result: LambdaInvokeResult?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test event")
                .font(.headline)
            Text("Invokes the function synchronously with this JSON payload and shows the response and execution logs - the same as the console's Test tab.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $payload)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 140, maxHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))

            HStack {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                ConfirmButton("Invoke", isLoading: isInvoking) {
                    Task { await invoke() }
                }
            }

            if let result {
                Divider()
                resultView(result)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func resultView(_ result: LambdaInvokeResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if let statusCode = result.statusCode {
                        Label("Status \(statusCode)", systemImage: result.functionError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(result.functionError == nil ? .green : .red)
                    }
                    if let functionError = result.functionError {
                        Text(functionError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let executedVersion = result.executedVersion {
                        Text("Version \(executedVersion)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let payload = result.payload {
                    Text("Response")
                        .font(.caption.bold())
                    Text(payload)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }

                if let logResult = result.logResult {
                    Text("Logs")
                        .font(.caption.bold())
                    Text(logResult)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .frame(maxHeight: 320)
    }

    private func invoke() async {
        isInvoking = true
        error = nil
        do {
            result = try await api.invokeLambdaFunction(profile: appState.currentProfile, region: appState.currentRegion, functionName: functionName, payload: payload)
        } catch {
            self.error = error.friendlyMessage
        }
        isInvoking = false
    }
}

// MARK: - Monitor

private struct LambdaMonitorView: View {
    let functionName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<LambdaMetricsSummary> = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Monitor")
                    .font(.headline)
                MetricChartGrid(charts: charts, reloadKey: functionName)

                Text("Last 24 hours")
                    .font(.subheadline.bold())
                    .padding(.top, 8)
                LoadableContent(state, retry: { Task { await load() } }) { summary in
                    HStack(spacing: 12) {
                        metricTile("Invocations", "\(Int(summary.invocations))")
                        metricTile("Errors", "\(Int(summary.errors))")
                        metricTile("Throttles", "\(Int(summary.throttles))")
                        metricTile("Avg Duration", String(format: "%.0f ms", summary.averageDurationMs))
                    }

                    Divider()
                        .padding(.top, 16)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Logs")
                            .font(.subheadline.bold())
                            .padding(.top, 12)
                        Text(summary.logGroupName)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text("Open this function's log group from the CloudWatch tab → Log Groups to browse streams and events.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1200, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: functionName) {
            await load()
        }
    }

    /// The console's Monitor graphs (AWS/Lambda, per function).
    private var charts: [MetricChartSpec] {
        let dims = ["FunctionName": functionName]
        return [
            MetricChartSpec("Invocations", namespace: "AWS/Lambda", dimensions: dims, [("Invocations", "Sum", nil)]),
            MetricChartSpec("Duration", unit: "ms", namespace: "AWS/Lambda", dimensions: dims, [("Duration", "Average", "Average"), ("Duration", "Maximum", "Maximum")]),
            MetricChartSpec("Errors and throttles", namespace: "AWS/Lambda", dimensions: dims, [("Errors", "Sum", nil), ("Throttles", "Sum", nil)]),
            MetricChartSpec("Concurrent executions", namespace: "AWS/Lambda", dimensions: dims, [("ConcurrentExecutions", "Maximum", nil)]),
        ]
    }

    private func metricTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3.bold())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 110, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func load() async {
        state = .loading
        do {
            let summary = try await api.getLambdaMetrics(profile: appState.currentProfile, region: appState.currentRegion, functionName: functionName)
            state = .loaded(summary)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - Configuration
//
// AWS's own Configuration tab has its own left-hand list of sub-sections
// (General configuration / Triggers / Permissions / Environment variables /
// Tags / ...) - deliberately not mirrored here (no nested list-inside-a-tab)
// since the whole point of dropping the outer function list was one level
// of list navigation being enough. Instead every sub-section is stacked in
// one scrollable tab, the same pattern CloudFormation's "Info" tab already
// uses for termination protection + parameters + tags + delete together.

private struct LambdaConfigurationView: View {
    let detail: LambdaFunctionDetail
    var onUpdated: (LambdaFunctionDetail) -> Void
    var onDeleted: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LambdaGeneralSection(detail: detail, onUpdated: onUpdated)
                Divider()
                LambdaConcurrencySection(detail: detail, onUpdated: onUpdated)
                Divider()
                LambdaEnvironmentSection(detail: detail, onUpdated: onUpdated)
                Divider()
                LambdaTriggersSection(functionName: detail.functionName)
                Divider()
                LambdaTagsSection(detail: detail, onUpdated: onUpdated)
                Divider()
                LambdaDangerZoneSection(detail: detail, onDeleted: onDeleted)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct LambdaGeneralSection: View {
    let detail: LambdaFunctionDetail
    var onUpdated: (LambdaFunctionDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var memorySize = ""
    @State private var timeout = ""
    @State private var description = ""
    @State private var savingField: String?
    @State private var errors: [String: String] = [:]
    @State private var saved: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General configuration")
                .font(.headline)

            SettingsFieldRow(label: "Memory (MB, 128–10240)", isSaving: savingField == "memorySize", error: errors["memorySize"], saved: saved.contains("memorySize"), save: { Task { await save(field: "memorySize") } }) {
                TextField("", text: $memorySize).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            SettingsFieldRow(label: "Timeout (seconds, 1–900)", isSaving: savingField == "timeout", error: errors["timeout"], saved: saved.contains("timeout"), save: { Task { await save(field: "timeout") } }) {
                TextField("", text: $timeout).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            SettingsFieldRow(label: "Description", isSaving: savingField == "description", error: errors["description"], saved: saved.contains("description"), save: { Task { await save(field: "description") } }) {
                TextField("", text: $description).textFieldStyle(.roundedBorder).frame(width: 320)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Details")
                    .font(.subheadline.bold())
                lambdaReadOnlyRow("Function ARN", detail.functionArn)
                if let role = detail.role { lambdaReadOnlyRow("Execution role", role) }
                if let architectures = detail.architectures, !architectures.isEmpty { lambdaReadOnlyRow("Architecture", architectures.joined(separator: ", ")) }
                if let stateReason = detail.stateReason, !stateReason.isEmpty { lambdaReadOnlyRow("State reason", stateReason) }
            }
        }
        .task(id: detail.functionName) {
            resetFields()
        }
    }

    private func resetFields() {
        memorySize = "\(detail.memorySize)"
        timeout = "\(detail.timeout)"
        description = detail.description ?? ""
        errors = [:]
        saved = []
    }

    private func save(field: String) async {
        savingField = field
        errors[field] = nil
        saved.remove(field)
        do {
            let updated: LambdaFunctionDetail
            switch field {
            case "memorySize":
                guard let value = Int(memorySize.trimmingCharacters(in: .whitespaces)) else {
                    errors[field] = "Enter a whole number of MB."
                    savingField = nil
                    return
                }
                updated = try await api.updateLambdaFunctionConfig(profile: appState.currentProfile, region: appState.currentRegion, functionName: detail.functionName, memorySize: value, timeout: nil, description: nil)
            case "timeout":
                guard let value = Int(timeout.trimmingCharacters(in: .whitespaces)) else {
                    errors[field] = "Enter a whole number of seconds."
                    savingField = nil
                    return
                }
                updated = try await api.updateLambdaFunctionConfig(profile: appState.currentProfile, region: appState.currentRegion, functionName: detail.functionName, memorySize: nil, timeout: value, description: nil)
            default:
                updated = try await api.updateLambdaFunctionConfig(profile: appState.currentProfile, region: appState.currentRegion, functionName: detail.functionName, memorySize: nil, timeout: nil, description: description)
            }
            onUpdated(updated)
            saved.insert(field)
        } catch {
            errors[field] = error.friendlyMessage
        }
        savingField = nil
    }
}

private struct LambdaConcurrencySection: View {
    let detail: LambdaFunctionDetail
    var onUpdated: (LambdaFunctionDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var reserveConcurrency = false
    @State private var concurrencyValue = 1
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Concurrency")
                .font(.headline)
            Toggle("Reserve concurrency for this function", isOn: $reserveConcurrency)
            if reserveConcurrency {
                HStack(spacing: 8) {
                    Stepper("Reserved concurrent executions: \(concurrencyValue)", value: $concurrencyValue, in: 0...1000)
                    SaveButton("Save", isLoading: isSaving) {
                        Task { await saveConcurrency() }
                    }
                }
            } else if detail.reservedConcurrentExecutions != nil {
                SaveButton("Remove Reserved Concurrency", isLoading: isSaving) {
                    Task { await removeConcurrency() }
                }
            } else {
                Text("Unreserved - this function shares the account's pool of concurrent executions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: detail.functionName) {
            if let reserved = detail.reservedConcurrentExecutions {
                reserveConcurrency = true
                concurrencyValue = reserved
            } else {
                reserveConcurrency = false
                concurrencyValue = 1
            }
            error = nil
        }
    }

    private func saveConcurrency() async {
        isSaving = true
        error = nil
        do {
            let updated = try await api.setLambdaConcurrency(profile: appState.currentProfile, region: appState.currentRegion, functionName: detail.functionName, reservedConcurrentExecutions: concurrencyValue)
            onUpdated(updated)
        } catch {
            self.error = error.friendlyMessage
        }
        isSaving = false
    }

    private func removeConcurrency() async {
        isSaving = true
        error = nil
        do {
            let updated = try await api.removeLambdaConcurrency(profile: appState.currentProfile, region: appState.currentRegion, functionName: detail.functionName)
            onUpdated(updated)
        } catch {
            self.error = error.friendlyMessage
        }
        isSaving = false
    }
}

private struct LambdaEnvironmentSection: View {
    let detail: LambdaFunctionDetail
    var onUpdated: (LambdaFunctionDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    private struct EnvRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    @State private var rows: [EnvRow] = []
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Environment variables")
                .font(.headline)
            Text("Saved as the function's full environment variable set - UpdateFunctionConfiguration replaces it entirely, so removed rows here are actually removed on Save.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text("No environment variables.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach($rows) { $row in
                        HStack(spacing: 8) {
                            removeRowButton(row.id)
                            TextField("KEY", text: $row.key)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 220)
                            TextField("value", text: $row.value)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }

            NewButton("Add Variable") {
                rows.append(EnvRow(key: "", value: ""))
            }

            HStack {
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                }
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
                Spacer()
                SaveButton("Save", isLoading: isSaving) {
                    Task { await save() }
                }
            }
        }
        .task(id: detail.functionName) {
            resetRows()
        }
    }

    /// A plain icon button, not `DeleteButton` - these rows are draft state
    /// that only takes effect on Save, so a confirmation dialog per row
    /// would just be friction (same reasoning as the Filter Builder's
    /// condition-row remove button).
    private func removeRowButton(_ id: UUID) -> some View {
        Button {
            rows.removeAll { $0.id == id }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .background(Color.red.opacity(0.15), in: Circle())
    }

    private func resetRows() {
        rows = detail.environmentVariables
            .sorted { $0.key < $1.key }
            .map { EnvRow(key: $0.key, value: $0.value) }
        saveError = nil
        saved = false
    }

    private func save() async {
        isSaving = true
        saveError = nil
        saved = false
        var variables: [String: String] = [:]
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            variables[key] = row.value
        }
        do {
            let updated = try await api.updateLambdaEnvironmentVariables(profile: appState.currentProfile, region: appState.currentRegion, functionName: detail.functionName, variables: variables)
            onUpdated(updated)
            saved = true
        } catch {
            saveError = error.friendlyMessage
        }
        isSaving = false
    }
}

private struct LambdaTriggersSection: View {
    let functionName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[LambdaEventSourceMapping]> = .loading
    @State private var newEventSourceArn = ""
    @State private var newBatchSize = "10"
    @State private var newStartingPosition = "LATEST"
    @State private var isAdding = false
    @State private var togglingUuid: String?
    @State private var removingUuid: String?
    @State private var error: String?

    private let startingPositions = ["LATEST", "TRIM_HORIZON"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Triggers")
                .font(.headline)
            Text("Event source mappings that poll an SQS queue, DynamoDB stream, or Kinesis stream and invoke this function - push-based triggers (S3, API Gateway, EventBridge) are configured on the source service itself, not here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No triggers") { mappings in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(mappings) { mapping in
                        triggerRow(mapping)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Add Trigger")
                    .font(.subheadline.bold())
                TextField("Event source ARN (SQS queue / DynamoDB stream / Kinesis stream)", text: $newEventSourceArn)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                HStack(spacing: 12) {
                    TextField("Batch size", text: $newBatchSize)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Picker("", selection: $newStartingPosition) {
                        ForEach(startingPositions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    NewButton("Add Trigger", isLoading: isAdding, isDisabled: newEventSourceArn.trimmingCharacters(in: .whitespaces).isEmpty) {
                        Task { await add() }
                    }
                }
                Text("Starting position only applies to DynamoDB/Kinesis streams - SQS ignores it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: functionName) {
            await load()
        }
    }

    private func triggerRow(_ mapping: LambdaEventSourceMapping) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(mapping.eventSourceArn ?? mapping.uuid)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let state = mapping.state {
                        StatusBadge(state)
                    }
                    if let batchSize = mapping.batchSize {
                        Text("Batch size \(batchSize)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { mapping.state?.lowercased() == "enabled" },
                set: { newValue in Task { await setEnabled(mapping.uuid, newValue) } }
            ))
            .labelsHidden()
            .disabled(togglingUuid == mapping.uuid)
            DeleteButton(compactSize: 20, isLoading: removingUuid == mapping.uuid, help: "Remove Trigger") {
                Task { await remove(mapping.uuid) }
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        state = .loading
        do {
            let mappings = try await api.getLambdaTriggers(profile: appState.currentProfile, region: appState.currentRegion, functionName: functionName)
            state = mappings.isEmpty ? .empty : .loaded(mappings)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }

    private func add() async {
        let arn = newEventSourceArn.trimmingCharacters(in: .whitespaces)
        guard !arn.isEmpty else { return }
        isAdding = true
        error = nil
        do {
            let mappings = try await api.createLambdaTrigger(profile: appState.currentProfile, region: appState.currentRegion, functionName: functionName, eventSourceArn: arn, batchSize: Int(newBatchSize), startingPosition: newStartingPosition)
            state = .loaded(mappings)
            newEventSourceArn = ""
        } catch {
            self.error = error.friendlyMessage
        }
        isAdding = false
    }

    private func setEnabled(_ uuid: String, _ enabled: Bool) async {
        togglingUuid = uuid
        error = nil
        do {
            let mappings = try await api.setLambdaTriggerEnabled(profile: appState.currentProfile, region: appState.currentRegion, functionName: functionName, uuid: uuid, enabled: enabled)
            state = .loaded(mappings)
        } catch {
            self.error = error.friendlyMessage
        }
        togglingUuid = nil
    }

    private func remove(_ uuid: String) async {
        removingUuid = uuid
        error = nil
        do {
            let mappings = try await api.deleteLambdaTrigger(profile: appState.currentProfile, region: appState.currentRegion, functionName: functionName, uuid: uuid)
            state = mappings.isEmpty ? .empty : .loaded(mappings)
        } catch {
            self.error = error.friendlyMessage
        }
        removingUuid = nil
    }
}

private struct LambdaTagsSection: View {
    let detail: LambdaFunctionDetail
    var onUpdated: (LambdaFunctionDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var newKey = ""
    @State private var newValue = ""
    @State private var isAdding = false
    @State private var removingKey: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appState.language.tagsTitle)
                .font(.headline)

            if detail.tags.isEmpty {
                Text(appState.language.noTagsMessage(noun: "function"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(detail.tags) { tag in
                        HStack {
                            Text(tag.key)
                                .font(.caption.monospaced().bold())
                            Text(tag.value)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            DeleteButton(compactSize: 20, isLoading: removingKey == tag.key, isDisabled: removingKey != nil, help: appState.language.removeTagHelp) {
                                Task { await remove(tag.key) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField(appState.language.tagKeyPlaceholder, text: $newKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                TextField(appState.language.tagValuePlaceholder, text: $newValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                NewButton(appState.language.addTagButton, isLoading: isAdding, isDisabled: !TagRules.canAdd(key: newKey, value: newValue)) {
                    Task { await add() }
                }
            }
            TagInputWarning(key: newKey, value: newValue)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func add() async {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        guard TagRules.canAdd(key: newKey, value: newValue) else { return }
        isAdding = true
        error = nil
        do {
            let updated = try await api.addLambdaTag(profile: appState.currentProfile, region: appState.currentRegion, functionArn: detail.functionArn, functionName: detail.functionName, key: key, value: newValue)
            onUpdated(updated)
            newKey = ""
            newValue = ""
        } catch {
            self.error = error.friendlyMessage
        }
        isAdding = false
    }

    private func remove(_ key: String) async {
        removingKey = key
        error = nil
        do {
            let updated = try await api.removeLambdaTag(profile: appState.currentProfile, region: appState.currentRegion, functionArn: detail.functionArn, functionName: detail.functionName, key: key)
            onUpdated(updated)
        } catch {
            self.error = error.friendlyMessage
        }
        removingKey = nil
    }
}

private struct LambdaDangerZoneSection: View {
    let detail: LambdaFunctionDetail
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var isDeleting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Danger zone")
                .font(.headline)
                .foregroundStyle(.red)
            DeleteButton("Delete Function", isLoading: isDeleting) {
                Task { await delete() }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func delete() async {
        isDeleting = true
        error = nil
        do {
            try await api.deleteLambdaFunction(profile: appState.currentProfile, region: appState.currentRegion, functionName: detail.functionName)
            onDeleted()
        } catch {
            self.error = error.friendlyMessage
        }
        isDeleting = false
    }
}

// MARK: - Aliases

private struct LambdaAliasesView: View {
    let functionName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[LambdaAlias]> = .loading
    @State private var newAliasName = ""
    @State private var newAliasVersion = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var removingAlias: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Aliases")
                    .font(.headline)
                Text("A named, mutable pointer to a specific version (or $LATEST) - callers invoke the alias instead of a version number, so you can repoint it without changing every caller.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No aliases") { aliases in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(aliases) { alias in
                            HStack {
                                Text(alias.name)
                                    .font(.caption.bold())
                                Text("→ \(alias.functionVersion)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                DeleteButton(compactSize: 20, isLoading: removingAlias == alias.name, help: "Delete Alias") {
                                    Task { await remove(alias.name) }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Create Alias")
                        .font(.subheadline.bold())
                    HStack(spacing: 8) {
                        TextField("Alias name", text: $newAliasName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        TextField("Version (e.g. 3 or $LATEST)", text: $newAliasVersion)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        NewButton("Create Alias", isLoading: isAdding, isDisabled: newAliasName.trimmingCharacters(in: .whitespaces).isEmpty || newAliasVersion.trimmingCharacters(in: .whitespaces).isEmpty) {
                            Task { await add() }
                        }
                    }
                }
                if let addError {
                    Text(addError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: functionName) {
            await load()
        }
    }

    private func load() async {
        state = .loading
        do {
            let aliases = try await api.getLambdaAliases(profile: appState.currentProfile, region: appState.currentRegion, functionName: functionName)
            state = aliases.isEmpty ? .empty : .loaded(aliases)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }

    private func add() async {
        let name = newAliasName.trimmingCharacters(in: .whitespaces)
        let version = newAliasVersion.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !version.isEmpty else { return }
        isAdding = true
        addError = nil
        do {
            let aliases = try await api.createLambdaAlias(profile: appState.currentProfile, region: appState.currentRegion, functionName: functionName, name: name, functionVersion: version, description: nil)
            state = .loaded(aliases)
            newAliasName = ""
            newAliasVersion = ""
        } catch {
            addError = error.friendlyMessage
        }
        isAdding = false
    }

    private func remove(_ name: String) async {
        removingAlias = name
        addError = nil
        do {
            let aliases = try await api.deleteLambdaAlias(profile: appState.currentProfile, region: appState.currentRegion, functionName: functionName, name: name)
            state = aliases.isEmpty ? .empty : .loaded(aliases)
        } catch {
            addError = error.friendlyMessage
        }
        removingAlias = nil
    }
}

// MARK: - Versions

private struct LambdaVersionsView: View {
    let functionName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[LambdaVersion]> = .loading
    @State private var isPublishing = false
    @State private var publishError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Versions")
                        .font(.headline)
                    Spacer()
                    NewButton("Publish Version", isLoading: isPublishing) {
                        Task { await publish() }
                    }
                }
                Text("$LATEST always tracks the current code/config; publishing snapshots it into an immutable numbered version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No published versions yet") { versions in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(versions) { version in
                            HStack {
                                Text(version.version)
                                    .font(.caption.monospaced().bold())
                                if let description = version.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Formatters.formatDate(version.lastModified))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                if let publishError {
                    Text(publishError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: functionName) {
            await load()
        }
    }

    private func load() async {
        state = .loading
        do {
            let versions = try await api.getLambdaVersions(profile: appState.currentProfile, region: appState.currentRegion, functionName: functionName)
            state = versions.isEmpty ? .empty : .loaded(versions)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }

    private func publish() async {
        isPublishing = true
        publishError = nil
        do {
            _ = try await api.publishLambdaVersion(profile: appState.currentProfile, region: appState.currentRegion, functionName: functionName, description: nil)
            await load()
        } catch {
            publishError = error.friendlyMessage
        }
        isPublishing = false
    }
}
