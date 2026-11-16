import SwiftUI

struct LambdaView: View {
    /// Filters the list; a dashboard card's search lands here (ScreenFilterField).
    @State private var filter = ""
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[LambdaFunction]> = .loading
    @State private var selectedFunction: LambdaFunction?
    @State private var showCreateSheet = false

    var body: some View {
        AuthGuardedView {
            Group {
                if let name = selectedFunction?.functionName {
                    // Matches the console's own navigation: opening a
                    // function replaces the list entirely rather than
                    // sitting beside it in a permanent split (unlike KMS/
                    // EC2/SQS's list-plus-detail panels) - see
                    // LambdaFunctionDetailView's doc comment.
                    LambdaFunctionDetailView(
                        functionName: name,
                        onBack: { selectedFunction = nil },
                        onDeleted: {
                            selectedFunction = nil
                            Task { await loadData() }
                        }
                    )
                    .id(name)
                } else {
                    functionListPanel
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadData()
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateLambdaFunctionSheet {
                showCreateSheet = false
                Task { await loadData() }
            }
        }
    }

    private var functionListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenFilterField(text: $filter)
            LoadableContent(state, retry: { Task { await loadData() } }, emptyMessage: "No functions") { unfilteredFunctions in
                let functions = unfilteredFunctions.matching(filter)
                List(functions, selection: Binding(
                    get: { selectedFunction?.id },
                    set: { id in selectedFunction = functions.first { $0.id == id } }
                )) { fn in
                    functionRow(fn)
                        .tag(fn.id)
                }
                .listStyle(.sidebar)
            }
            header
        }
    }

    /// Bottom action bar of the function list.
    private var header: some View {
        PanelActionBar {
            ScreenTitle("Lambda Functions")
            NewButton("Create Function") { showCreateSheet = true }
            RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadData() } }
        } trailing: {
            if case .loaded(let functions) = state {
                Text("\(functions.count) functions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func functionRow(_ fn: LambdaFunction) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(fn.functionName ?? "-")
                    .font(.body.bold())
                Text("\(fn.runtime ?? "-") · \(fn.memorySize.map { "\($0) MB" } ?? "-") · \(Formatters.formatDate(fn.lastModified))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let state = fn.state {
                StatusBadge(state)
            }
        }
        .padding(.vertical, 2)
    }

    private func loadData() async {
        state = .loading
        selectedFunction = nil
        do {
            let response = try await api.getLambdaFunctions(profile: appState.currentProfile, region: appState.currentRegion)
            state = response.loadState()
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private let lambdaRuntimes = ["nodejs20.x", "nodejs18.x", "python3.13", "python3.12", "python3.11"]

private let defaultLambdaNodeCode = """
exports.handler = async (event) => {
  return { statusCode: 200, body: JSON.stringify({ message: "Hello from Lambda!" }) };
};
"""

private let defaultLambdaPythonCode = """
def lambda_handler(event, context):
    return {"statusCode": 200, "body": "Hello from Lambda!"}
"""

/// "Author from scratch" analog to the console's inline code editor - there's
/// no local checkout to zip (unlike CodeCommit's Workspace), so a single
/// pasted source file is zipped in-memory server-side (`jszip`, already used
/// for S3's archive browsing) and sent as `CreateFunction`'s deployment
/// package. Deliberately minimal, like EC2's Launch Instance sheet: no
/// blueprint gallery, no multi-file project, no container image support -
/// for anything past a single-file function, deploy through the usual
/// pipeline (SAM/CDK/CLI) and manage it here afterward.
private struct CreateLambdaFunctionSheet: View {
    var onCreated: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var functionName = ""
    @State private var runtime = "nodejs20.x"
    @State private var handler = "index.handler"
    @State private var roleArn = ""
    @State private var memorySize = "128"
    @State private var timeout = "3"
    @State private var description = ""
    @State private var code = defaultLambdaNodeCode
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Create Function")
                    .font(.title2.bold())
                Spacer()
                SecondaryButton("Cancel") { dismiss() }
            }
            Text("Author from scratch - a minimal single-file function, zipped and deployed with CreateFunction.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Function name") {
                        TextField("my-function", text: $functionName)
                            .textFieldStyle(.roundedBorder)
                    }
                    field("Runtime") {
                        Picker("", selection: $runtime) {
                            ForEach(lambdaRuntimes, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .onChange(of: runtime) { _, newValue in
                            handler = newValue.hasPrefix("python") ? "lambda_function.lambda_handler" : "index.handler"
                            code = newValue.hasPrefix("python") ? defaultLambdaPythonCode : defaultLambdaNodeCode
                        }
                    }
                    field("Handler") {
                        TextField("index.handler", text: $handler)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    field("Execution role ARN") {
                        TextField("arn:aws:iam::123456789012:role/my-lambda-role", text: $roleArn)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack(spacing: 12) {
                        field("Memory (MB)") {
                            TextField("128", text: $memorySize)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                        field("Timeout (s)") {
                            TextField("3", text: $timeout)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                    }
                    field("Description (optional)") {
                        TextField("", text: $description)
                            .textFieldStyle(.roundedBorder)
                    }
                    field("Code") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Saved as \(codeFileName) inside the deployment zip.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $code)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 160, maxHeight: 240)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                NewButton("Create Function", isLoading: isCreating, isDisabled: !isFormValid) {
                    Task { await create() }
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 680)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var codeFileName: String {
        let moduleName = handler.split(separator: ".").first.map(String.init) ?? "index"
        let ext = runtime.hasPrefix("python") ? ".py" : ".js"
        return moduleName + ext
    }

    private var isFormValid: Bool {
        !functionName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !handler.trimmingCharacters(in: .whitespaces).isEmpty &&
        !roleArn.trimmingCharacters(in: .whitespaces).isEmpty &&
        !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        do {
            _ = try await api.createLambdaFunction(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                functionName: functionName.trimmingCharacters(in: .whitespaces),
                runtime: runtime,
                handler: handler.trimmingCharacters(in: .whitespaces),
                role: roleArn.trimmingCharacters(in: .whitespaces),
                code: code,
                memorySize: Int(memorySize),
                timeout: Int(timeout),
                description: description.trimmingCharacters(in: .whitespaces).isEmpty ? nil : description
            )
            dismiss()
            onCreated()
        } catch {
            errorMessage = error.friendlyMessage
        }
        isCreating = false
    }
}
