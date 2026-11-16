import SwiftUI

/// A searchable branch list rendered as a folder tree - "features/asd" shows
/// as a closed "features" folder containing the "asd" branch, same
/// convention as CodeCommit's diff file trees (`PathTree.swift`), except
/// branch folders start **collapsed** since the branch name itself is
/// usually what you're scanning for, not the grouping. Typing in the search
/// box filters by branch name and force-expands every folder so matches
/// aren't hidden behind a closed one.
struct BranchTreeView: View {
    let branches: [CodeCommitBranch]
    let defaultBranch: String
    /// When set, the branch this list is picking a value *for* - that row
    /// is highlighted, and tapping a row calls back instead of doing
    /// nothing (used by `BranchPickerField`; leave both nil for a
    /// display-only list like the Branches tab).
    var selectedBranchName: String? = nil
    var onSelect: ((CodeCommitBranch) -> Void)? = nil
    /// Double-clicking a branch name - used by the Branches tab to jump to
    /// Commits with that branch preselected. Left nil in picker mode
    /// (`BranchPickerField`), where double-clicking to navigate away mid-pick
    /// wouldn't make sense.
    var onDoubleClick: ((CodeCommitBranch) -> Void)? = nil
    /// Right-click "Delete Branch" - left nil in picker mode, same reasoning
    /// as `onDoubleClick`.
    var onDelete: ((CodeCommitBranch) -> Void)? = nil

    @State private var searchText = ""
    @State private var expandedIDs: Set<String> = []

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var filteredBranches: [CodeCommitBranch] {
        guard !trimmedSearch.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearch) }
    }

    private var tree: [PathTreeNode<CodeCommitBranch>] {
        buildPathTree(filteredBranches, path: { $0.name })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            Divider()
            if filteredBranches.isEmpty {
                EmptyStateView(message: trimmedSearch.isEmpty ? "No branches" : "No branches match \"\(trimmedSearch)\"")
            } else {
                List {
                    PathTreeView(
                        nodes: tree,
                        initiallyExpanded: false,
                        forceExpanded: !trimmedSearch.isEmpty,
                        expandedIDs: $expandedIDs
                    ) { branch in
                        branchRow(branch)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search branches", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 14)
            Button {
                expandedIDs = allPathTreeFolderIDs(in: tree)
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Expand All")
            Button {
                expandedIDs = []
            } label: {
                Image(systemName: "chevron.up.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Collapse All")
        }
        .padding(8)
    }

    private func branchRow(_ branch: CodeCommitBranch) -> some View {
        HStack {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            Text(branchLeafName(branch.name))
                .font(.caption)
            if branch.name == defaultBranch {
                Text("default")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            if branch.name == selectedBranchName {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(Color.accentColor)
            } else if let commitId = branch.commitId {
                Text(String(commitId.prefix(8)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(branch.name == selectedBranchName ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleClick?(branch)
        }
        .onTapGesture {
            onSelect?(branch)
        }
        .contextMenu {
            if let onDelete, branch.name != defaultBranch {
                Button("Delete Branch", role: .destructive) {
                    onDelete(branch)
                }
            }
        }
    }

    private func branchLeafName(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }
}
