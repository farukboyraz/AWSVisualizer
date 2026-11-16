import SwiftUI

struct CodeCommitBranchesView: View {
    let repositoryName: String
    let defaultBranch: String
    var onOpenCommits: (String) -> Void = { _ in }

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var branchesState: LoadState<[CodeCommitBranch]> = .loading
    @State private var baseBranch = ""
    @State private var compareBranch = ""
    @State private var showCompare = false
    @State private var showNewBranch = false
    @State private var showMerge = false
    @State private var branchPendingDelete: CodeCommitBranch?
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(branchesState, retry: { Task { await loadBranches() } }, emptyMessage: "No branches") { branches in
                VStack(alignment: .leading, spacing: 0) {
                    header
                    compareBar(branches)
                    if let deleteError {
                        Text(deleteError).font(.caption).foregroundStyle(.red).padding(.horizontal)
                    }

                    Divider()

                    BranchTreeView(
                        branches: branches,
                        defaultBranch: defaultBranch,
                        onDoubleClick: { branch in onOpenCommits(branch.name) },
                        onDelete: { branch in branchPendingDelete = branch }
                    )
                }
            }
        }
        .task {
            await loadBranches()
        }
        .sheet(isPresented: $showCompare) {
            CodeCommitChangesView(
                repositoryName: repositoryName,
                before: baseBranch,
                after: compareBranch,
                title: "Comparing branches",
                subtitle: "\(baseBranch)...\(compareBranch)"
            )
        }
        .sheet(isPresented: $showNewBranch) {
            if case .loaded(let branches) = branchesState {
                NewBranchSheet(repositoryName: repositoryName, branches: branches, defaultBranch: defaultBranch) {
                    showNewBranch = false
                    Task { await loadBranches() }
                }
            }
        }
        .sheet(isPresented: $showMerge) {
            BranchMergeSheet(repositoryName: repositoryName, sourceBranch: compareBranch, destinationBranch: baseBranch) {
                showMerge = false
                Task { await loadBranches() }
            }
        }
        .confirmationDialog(
            branchPendingDelete.map { "Delete branch \"\($0.name)\"? This can't be undone." } ?? "",
            isPresented: Binding(get: { branchPendingDelete != nil }, set: { if !$0 { branchPendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Branch", role: .destructive) {
                if let branch = branchPendingDelete { Task { await deleteBranch(branch) } }
            }
            Button("Cancel", role: .cancel) { branchPendingDelete = nil }
        }
    }

    private var header: some View {
        HStack {
            Text("Branches")
                .font(.headline)
            Spacer()
            NewButton("New Branch") {
                showNewBranch = true
            }
        }
        .padding([.horizontal, .top])
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func compareBar(_ branches: [CodeCommitBranch]) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Base")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                BranchPickerField(branches: branches, defaultBranch: defaultBranch, selection: $baseBranch)
                    .frame(width: 180)
            }
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                BranchPickerField(branches: branches, defaultBranch: defaultBranch, selection: $compareBranch)
                    .frame(width: 180)
            }
            Spacer()
            ConfirmButton("Merge…", isDisabled: baseBranch.isEmpty || compareBranch.isEmpty || baseBranch == compareBranch) {
                showMerge = true
            }
            RunButton("Compare Branches", systemImage: "arrow.left.arrow.right") {
                showCompare = true
            }
            .disabled(baseBranch.isEmpty || compareBranch.isEmpty || baseBranch == compareBranch)
        }
        .padding()
    }

    private func loadBranches() async {
        branchesState = .loading
        do {
            let branches = try await api.getCodeCommitBranches(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName)
            branchesState = branches.isEmpty ? .empty : .loaded(branches)
            if baseBranch.isEmpty {
                baseBranch = branches.first { $0.name == defaultBranch }?.name ?? branches.first?.name ?? ""
            }
            if compareBranch.isEmpty {
                compareBranch = branches.first { $0.name != baseBranch }?.name ?? branches.first?.name ?? ""
            }
        } catch {
            branchesState = .failed(error.friendlyMessage)
        }
    }

    private func deleteBranch(_ branch: CodeCommitBranch) async {
        deleteError = nil
        do {
            try await api.deleteCodeCommitBranch(profile: appState.currentProfile, region: appState.currentRegion, repositoryName: repositoryName, branchName: branch.name)
            branchPendingDelete = nil
            await loadBranches()
        } catch {
            deleteError = error.friendlyMessage
            branchPendingDelete = nil
        }
    }
}

private struct NewBranchSheet: View {
    let repositoryName: String
    let branches: [CodeCommitBranch]
    let defaultBranch: String
    var onCreated: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var branchName = ""
    @State private var sourceBranch: String
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(repositoryName: String, branches: [CodeCommitBranch], defaultBranch: String, onCreated: @escaping () -> Void) {
        self.repositoryName = repositoryName
        self.branches = branches
        self.defaultBranch = defaultBranch
        self.onCreated = onCreated
        self._sourceBranch = State(initialValue: branches.first { $0.name == defaultBranch }?.name ?? branches.first?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New Branch")
                    .font(.title2.bold())
                Spacer()
                SecondaryButton("Cancel") { dismiss() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Branch Name").font(.caption).foregroundStyle(.secondary)
                TextField("my-feature", text: $branchName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Source Branch").font(.caption).foregroundStyle(.secondary)
                BranchPickerField(branches: branches, defaultBranch: defaultBranch, selection: $sourceBranch)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                NewButton("Create Branch", isLoading: isCreating, isDisabled: branchName.trimmingCharacters(in: .whitespaces).isEmpty || sourceBranch.isEmpty) {
                    Task { await create() }
                }
            }
        }
        .padding(24)
        .frame(width: 380, height: 220)
    }

    private func create() async {
        guard let commitId = branches.first(where: { $0.name == sourceBranch })?.commitId else {
            errorMessage = "Couldn't resolve the source branch's commit"
            return
        }
        isCreating = true
        errorMessage = nil
        do {
            try await api.createCodeCommitBranch(profile: appState.currentProfile, region: appState.currentRegion, repositoryName: repositoryName, branchName: branchName.trimmingCharacters(in: .whitespaces), commitId: commitId)
            onCreated()
        } catch {
            errorMessage = error.friendlyMessage
        }
        isCreating = false
    }
}

/// Merges two branches directly - the console's "Compare and merge"
/// action outside a pull request. Same strategy picker + conflict pre-check
/// UX as the PR merge panel (`CodeCommitPullRequestDetailView`'s
/// `MergePanel`), just standalone since there's no PR/diff already on
/// screen to attach to.
private struct BranchMergeSheet: View {
    let repositoryName: String
    let sourceBranch: String
    let destinationBranch: String
    var onMerged: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var mergeOption: CodeCommitMergeOption = .fastForward
    @State private var checkState: LoadState<CodeCommitMergeCheck> = .loading
    @State private var commitMessage = ""
    @State private var isMerging = false
    @State private var mergeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Merge Branches")
                    .font(.title2.bold())
                Spacer()
                SecondaryButton("Cancel") { dismiss() }
            }
            Text("\(sourceBranch) → \(destinationBranch)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Picker("Strategy", selection: $mergeOption) {
                ForEach(CodeCommitMergeOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if mergeOption != .fastForward {
                TextField("Commit message (optional)", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
            }

            mergeabilityView

            if let mergeError {
                Text(mergeError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                ConfirmButton("Merge", isLoading: isMerging, isDisabled: !isMergeable) {
                    Task { await merge() }
                }
            }
        }
        .padding(24)
        .frame(width: 460, height: 320)
        .task(id: mergeOption) {
            await checkMergeability()
        }
    }

    private var isMergeable: Bool {
        if case .loaded(let check) = checkState { return check.mergeable }
        return false
    }

    @ViewBuilder
    private var mergeabilityView: some View {
        switch checkState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking whether this can be merged…").font(.caption).foregroundStyle(.secondary)
            }
        case .loaded(let check):
            if check.mergeable {
                Label("These branches can be merged automatically.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("There are conflicts that must be resolved.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if !check.conflictedFilePaths.isEmpty {
                        Text(check.conflictedFilePaths.prefix(10).joined(separator: ", "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        case .empty, .failed:
            EmptyView()
        }
    }

    private func checkMergeability() async {
        checkState = .loading
        do {
            let check = try await api.checkCodeCommitMergeConflicts(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                name: repositoryName,
                destination: destinationBranch,
                source: sourceBranch,
                mergeOption: mergeOption
            )
            checkState = .loaded(check)
        } catch {
            checkState = .failed(error.friendlyMessage)
        }
    }

    private func merge() async {
        isMerging = true
        mergeError = nil
        do {
            try await api.mergeCodeCommitBranches(
                profile: appState.currentProfile,
                region: appState.currentRegion,
                repositoryName: repositoryName,
                sourceBranch: sourceBranch,
                destinationBranch: destinationBranch,
                mergeOption: mergeOption,
                commitMessage: commitMessage.isEmpty ? nil : commitMessage
            )
            onMerged()
        } catch {
            mergeError = error.friendlyMessage
        }
        isMerging = false
    }
}
