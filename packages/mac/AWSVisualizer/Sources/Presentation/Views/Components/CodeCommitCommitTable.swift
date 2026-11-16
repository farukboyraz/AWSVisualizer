import SwiftUI

/// The commit table + row selection + "View Changes"/"Compare Selected
/// Commits" actions - shared between the branch-wide Commits tab and any
/// path-scoped commit history (same interaction, just a different list of
/// commits feeding it).
struct CodeCommitCommitTable: View {
    let repositoryName: String
    let commits: [CodeCommitCommit]
    /// Draw the branch / merge graph from `parents` (the Commits tab, whose
    /// list follows every parent). Path-scoped histories skip commits, so
    /// lanes there would never close - they keep the simple rail.
    var showsGraph = false

    @State private var selectedCommitIDs: Set<String> = []
    /// Built once per commit list, not per row.
    @State private var graph: CommitGraph?
    @State private var scrollTarget: String?
    @State private var changesTarget: ChangesTarget?

    private struct ChangesTarget: Identifiable {
        let id = UUID()
        let before: String?
        let after: String
        let title: String
        let subtitle: String?
    }

    var body: some View {
        ScrollViewReader { proxy in
            table
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
                    scrollTarget = nil
                }
        }
        .onAppear { rebuildGraph() }
        .onChange(of: commits.map(\.id)) { _, _ in rebuildGraph() }
    }

    private func rebuildGraph() {
        graph = CommitGraph(commits: commits)
    }

    private var graphWidth: CGFloat { showsGraph ? max(24, graph?.width ?? 24) : 24 }

    private var table: some View {
        Table(commits, selection: $selectedCommitIDs) {
            // The graph rail - `getCommits` walks only each commit's first
            // parent (a single branch's linear history), so this can't draw
            // real multi-lane merge topology the way `git log --graph`
            // does across all branches. What it *can* show honestly: one
            // continuous lane connecting every commit in the list, with
            // merge commits (more than one parent) marked distinctly rather
            // than fabricating a second lane for a branch we never fetched.
            TableColumn("") { c in
                if showsGraph, let row = graph?.rows[c.commitId] {
                    CommitGraphCell(row: row, isSelected: selectedCommitIDs.contains(c.commitId))
                        .help(graphHelp(c))
                } else {
                    graphCell(c)
                }
            }
            .width(graphWidth)

            TableColumn("Commit") { c in
                Text(c.shortId)
                    .font(.caption.monospaced())
            }
            .width(min: 70, ideal: 90)

            TableColumn("Message") { c in
                Text(firstLine(of: c.message))
                    .lineLimit(1)
                    .help(c.message)
            }

            TableColumn("Author") { c in
                Text(c.authorName ?? "-")
            }
            .width(min: 100, ideal: 150)

            TableColumn("Date") { c in
                Text(Formatters.formatGitDate(c.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 160)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let commit = commits.first(where: { $0.id == ids.first }) {
                Button("View Changes") {
                    showChanges(for: commit)
                }
                Divider()
                relationMenu(title: "Go to Parent", ids: commit.parents, labels: { index in index == 0 ? "first parent" : "merged in" })
                relationMenu(title: "Go to Child", ids: graph?.children[commit.commitId] ?? [], labels: { _ in nil })
            } else if ids.count == 2 {
                Button("Compare Selected Commits") {
                    compareSelected()
                }
            }
        } primaryAction: { ids in
            if ids.count == 1, let commit = commits.first(where: { $0.id == ids.first }) {
                showChanges(for: commit)
            } else if ids.count == 2 {
                compareSelected()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selectedCommitIDs.isEmpty {
                selectionActionBar
            }
        }
        .sheet(item: $changesTarget) { target in
            CodeCommitChangesView(repositoryName: repositoryName, before: target.before, after: target.after, title: target.title, subtitle: target.subtitle)
        }
        .onChange(of: commits.map(\.id)) { _, _ in
            selectedCommitIDs = []
        }
    }


    /// "Go to Parent" / "Go to Child": one item when there's a single
    /// target, a submenu when there are several (merge parents, branch
    /// points). Commits outside the loaded list show disabled.
    @ViewBuilder
    private func relationMenu(title: String, ids: [String], labels: @escaping (Int) -> String?) -> some View {
        if ids.isEmpty {
            Button(title) {}.disabled(true)
        } else if ids.count == 1 {
            relationButton(title, id: ids[0])
        } else {
            Menu(title) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    relationButton(label(for: id, note: labels(index)), id: id)
                }
            }
        }
    }

    private func relationButton(_ title: String, id: String) -> some View {
        let loaded = commits.contains { $0.commitId == id }
        return Button(loaded ? title : "\(title) - \(id.prefix(8)) (not loaded)") { go(to: id) }
            .disabled(!loaded)
    }

    private func label(for id: String, note: String?) -> String {
        let commit = commits.first { $0.commitId == id }
        var text = String(id.prefix(8))
        if let commit { text += "  \(firstLine(of: commit.message))" }
        if let note { text += "  (\(note))" }
        return text
    }

    /// Selects that commit and scrolls it into view.
    private func go(to id: String) {
        selectedCommitIDs = [id]
        scrollTarget = id
    }

    private func graphHelp(_ commit: CodeCommitCommit) -> String {
        let parents = commit.parents.map { String($0.prefix(8)) }.joined(separator: ", ")
        let kids = (graph?.children[commit.commitId] ?? []).map { String($0.prefix(8)) }.joined(separator: ", ")
        var lines: [String] = []
        if commit.parents.count > 1 { lines.append("Merge commit") }
        if !parents.isEmpty { lines.append("Parents: \(parents)") }
        if !kids.isEmpty { lines.append("Children: \(kids)") }
        lines.append("Right-click → Go to Parent / Go to Child")
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var selectionActionBar: some View {
        HStack {
            Text("\(selectedCommitIDs.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if selectedCommitIDs.count == 1, let commit = commits.first(where: { $0.id == selectedCommitIDs.first }) {
                RunButton("View Changes", systemImage: "doc.text.magnifyingglass") { showChanges(for: commit) }
            } else if selectedCommitIDs.count == 2 {
                RunButton("Compare Selected Commits", systemImage: "arrow.left.arrow.right") { compareSelected() }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func showChanges(for commit: CodeCommitCommit) {
        changesTarget = ChangesTarget(
            before: commit.parents.first,
            after: commit.commitId,
            title: "Commit \(commit.shortId)",
            subtitle: firstLine(of: commit.message)
        )
    }

    private func compareSelected() {
        let selectedWithIndex = commits.enumerated().filter { selectedCommitIDs.contains($0.element.id) }
        guard selectedWithIndex.count == 2 else { return }
        // Commits are listed newest-first; the one with the larger index is older ("before").
        let sorted = selectedWithIndex.sorted { $0.offset < $1.offset }
        let after = sorted[0].element
        let before = sorted[1].element
        changesTarget = ChangesTarget(
            before: before.commitId,
            after: after.commitId,
            title: "Comparing \(before.shortId)...\(after.shortId)",
            subtitle: nil
        )
    }

    private func firstLine(of message: String) -> String {
        message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
    }

    @ViewBuilder
    private func graphCell(_ commit: CodeCommitCommit) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 2)
            if commit.parents.count > 1 {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.purple)
            } else {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 24)
        .help(mergeHelp(commit))
    }

    private func mergeHelp(_ commit: CodeCommitCommit) -> String {
        guard commit.parents.count > 1 else { return "" }
        let others = commit.parents.dropFirst().map { String($0.prefix(8)) }.joined(separator: ", ")
        return "Merge commit - also merged in: \(others)"
    }
}
