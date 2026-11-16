import SwiftUI

private struct RepoPathSegment {
    let name: String
    let path: String
    let depth: Int
}

/// A folder to show the history popup for - `Identifiable` so it can drive
/// `.sheet(item:)` directly, letting each right-clicked folder (not just
/// whichever one happens to be "current") open its own history.
private struct FolderHistoryTarget: Identifiable {
    let path: String
    let displayName: String
    var id: String { path }
}

/// One repository search result (file or folder).
private struct RepoSearchHit: Identifiable {
    let path: String
    let isFolder: Bool
    var id: String { (isFolder ? "d:" : "f:") + path }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// Path with a leading slash - the form the folder browser uses.
    var slashPath: String { path.hasPrefix("/") ? path : "/" + path }
    var parentDisplay: String {
        let parts = slashPath.split(separator: "/").dropLast()
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }
    var entry: CodeCommitFolderEntry { CodeCommitFolderEntry(name: name, path: path, isFolder: isFolder) }

    /// Folders first (they're fewer and usually what a name search is after).
    static func hits(from page: CodeCommitFileSearchPage) -> [RepoSearchHit] {
        (page.folders ?? []).map { RepoSearchHit(path: $0, isFolder: true) } + page.paths.map { RepoSearchHit(path: $0, isFolder: false) }
    }
}

struct CodeCommitFilesView: View {
    let repositoryName: String
    let defaultBranch: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var currentPath = "/"
    @State private var listState: LoadState<CodeCommitFolderListing> = .loading
    @State private var selectedFile: CodeCommitFolderEntry?
    @State private var listTask: Task<Void, Never>?
    @State private var showFileHistory = false
    @State private var folderHistoryTarget: FolderHistoryTarget?
    @State private var showQuickSwitcher = false
    @State private var pinnedFiles: [CodeCommitFolderEntry] = []

    // Repository-wide search (files + folders) shown in the left panel.
    @State private var searchQuery = ""
    @State private var searchResults: [RepoSearchHit] = []
    @State private var searchCursor: String?
    @State private var searchActive = false
    @State private var isSearching = false
    @State private var isLoadingMoreResults = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumbBar
            if !pinnedFiles.isEmpty {
                pinnedFilesBar
            }
            Divider()
            ResizableSplitView(initialWidth: 280, minWidth: 200, maxWidth: 500) {
                if searchActive {
                    searchResultsList
                } else {
                    LoadableContent(listState, retry: { navigate(to: currentPath) }, cancel: cancelList) { listing in
                        List {
                            ForEach(listing.entries) { entry in
                                fileRow(entry)
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            } right: {
                CodeCommitFilePreviewPane(
                    repositoryName: repositoryName,
                    branchName: defaultBranch,
                    entry: selectedFile,
                    isPinned: selectedFile.map(isPinned) ?? false,
                    onTogglePin: selectedFile.map { entry in { togglePin(entry) } },
                    showHistory: $showFileHistory,
                    onFileChanged: { navigate(to: currentPath) }
                )
            }
        }
        .task(id: defaultBranch) {
            navigate(to: "/")
        }
        .sheet(item: $folderHistoryTarget) { target in
            CodeCommitPathHistoryView(
                repositoryName: repositoryName,
                commitSpecifier: defaultBranch,
                path: target.path.hasPrefix("/") ? String(target.path.dropFirst()) : target.path,
                displayName: target.displayName
            )
        }
        .sheet(isPresented: $showQuickSwitcher) {
            CodeCommitQuickFileSwitcher(repositoryName: repositoryName, commitSpecifier: defaultBranch) { path in
                showQuickSwitcher = false
                open(CodeCommitFolderEntry(name: path.split(separator: "/").last.map(String.init) ?? path, path: path, isFolder: false))
            }
        }
        .background {
            Button("") { showQuickSwitcher = true }
                .keyboardShortcut("p", modifiers: .command)
                .opacity(0)
        }
    }

    /// Spans the full width, above both panels - not just the file list -
    /// so it doubles as "where am I" for whatever file is open on the
    /// right, not only for folder browsing on the left. When a file is
    /// selected its name is appended as a final, non-navigable segment
    /// (small, bold) so the extension is always legible regardless of how
    /// deep the folder path above it is; every folder segment before it is
    /// still a live jump to that folder, skipping however many levels sit
    /// in between in one click. Scrolls horizontally rather than crowding
    /// out the action icons on the right when the path runs long.
    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    breadcrumbButton(label: repositoryName, isCurrent: currentPath == "/" && selectedFile == nil) {
                        navigate(to: "/")
                    }
                    ForEach(Array(pathSegments.enumerated()), id: \.offset) { index, segment in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        breadcrumbButton(label: segment.name, isCurrent: selectedFile == nil && index == pathSegments.count - 1) {
                            navigate(to: segment.path)
                        }
                    }
                    if let selectedFile {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(selectedFile.name)
                            .font(.caption.bold())
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            searchField
            Button {
                folderHistoryTarget = FolderHistoryTarget(path: currentPath, displayName: pathSegments.last?.name ?? repositoryName)
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Commits that touched this folder")
        }
        .padding(8)
    }

    /// Files the user explicitly pinned (right-click a file, or the pin
    /// button in the preview toolbar) - not an auto-tracked "recently
    /// viewed" list, so it only ever contains what was deliberately kept.
    private var pinnedFilesBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pinnedFiles) { entry in
                    HStack(spacing: 4) {
                        Text(entry.name)
                            .font(.caption2)
                            .lineLimit(1)
                        Button {
                            togglePin(entry)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Unpin")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(entry.path == selectedFile?.path ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                    .onTapGesture {
                        open(entry)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }

    private func fileRow(_ entry: CodeCommitFolderEntry) -> some View {
        HStack(spacing: 6) {
            FileIcon(name: entry.name, isFolder: entry.isFolder)
            Text(entry.name)
            if !entry.isFolder, isPinned(entry) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(entry.path == selectedFile?.path ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.isFolder {
                open(entry)
            } else {
                open(entry, showingHistory: true)
            }
        }
        .onTapGesture {
            open(entry)
        }
        .contextMenu {
            if entry.isFolder {
                Button("Show History") {
                    folderHistoryTarget = FolderHistoryTarget(path: entry.path, displayName: entry.name)
                }
            } else {
                Button(isPinned(entry) ? "Unpin" : "Pin") {
                    togglePin(entry)
                }
                Button("View History") {
                    open(entry, showingHistory: true)
                }
            }
        }
    }

    // MARK: - Repository search

    /// Searches every file and folder in the repository (Enter). CodeCommit
    /// has no search API, so the server walks the folder tree a page at a
    /// time; more results load as the list is scrolled.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search repository", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 180)
                .onSubmit { startSearch() }
                .help("Search all files and folders - Enter to search (⌘P jumps to a file)")
            if searchActive || !searchQuery.isEmpty {
                Button { clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if isSearching {
            BrandedLoader(message: "Searching the repository…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let searchError {
            ErrorStateView(message: searchError, retry: { startSearch() })
        } else if searchResults.isEmpty {
            EmptyStateView(message: "Nothing in the repository matches \"\(searchQuery)\"")
        } else {
            List {
                ForEach(searchResults) { hit in
                    searchRow(hit)
                        .onAppear {
                            if hit.id == searchResults.last?.id { Task { await loadMoreResults() } }
                        }
                }
                if searchCursor != nil {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .padding(.vertical, 8)
                }
            }
            .listStyle(.plain)
        }
    }

    private func searchRow(_ hit: RepoSearchHit) -> some View {
        HStack(spacing: 6) {
            FileIcon(name: hit.name, isFolder: hit.isFolder)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.name).lineLimit(1)
                Text(hit.parentDisplay)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(!hit.isFolder && hit.slashPath == selectedFile?.path ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            if hit.isFolder {
                goToLocation(hit, into: true)
            } else {
                open(hit.entry)
            }
        }
        .contextMenu {
            Button(hit.isFolder ? "Go to Folder Location" : "Go to File Location") {
                goToLocation(hit, into: false)
            }
            if hit.isFolder {
                Button("Open Folder") { goToLocation(hit, into: true) }
                Button("Show History") {
                    folderHistoryTarget = FolderHistoryTarget(path: hit.slashPath, displayName: hit.name)
                }
            } else {
                Button("Open") { open(hit.entry) }
                Button("View History") { open(hit.entry, showingHistory: true) }
                Button(isPinned(hit.entry) ? "Unpin" : "Pin") { togglePin(hit.entry) }
            }
        }
    }

    /// Leaves the search and shows the item where it lives: a file opens
    /// with its folder listed beside it; a folder shows its parent with
    /// the folder in it (or, `into: true`, the folder's own contents).
    private func goToLocation(_ hit: RepoSearchHit, into: Bool) {
        searchTask?.cancel()
        searchActive = false
        if hit.isFolder {
            navigate(to: into ? hit.slashPath : parentFolder(of: hit.slashPath))
        } else {
            // `open` lists the file's folder (if it isn't already) and selects it.
            open(hit.entry)
        }
    }

    private func startSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { clearSearch(); return }
        searchTask?.cancel()
        searchActive = true
        isSearching = true
        searchError = nil
        searchResults = []
        searchCursor = nil
        searchTask = Task {
            do {
                let page = try await api.searchCodeCommitFiles(profile: appState.currentProfile, region: appState.currentRegion, repositoryName: repositoryName, commitSpecifier: defaultBranch, query: query, cursor: nil, limit: 30)
                guard !Task.isCancelled else { return }
                searchResults = RepoSearchHit.hits(from: page)
                searchCursor = page.nextCursor
            } catch {
                guard !Task.isCancelled else { return }
                searchError = error.friendlyMessage
            }
            isSearching = false
        }
    }

    private func loadMoreResults() async {
        guard let cursor = searchCursor, !isLoadingMoreResults, searchActive else { return }
        isLoadingMoreResults = true
        defer { isLoadingMoreResults = false }
        do {
            let page = try await api.searchCodeCommitFiles(profile: appState.currentProfile, region: appState.currentRegion, repositoryName: repositoryName, commitSpecifier: defaultBranch, query: searchQuery.trimmingCharacters(in: .whitespaces), cursor: cursor, limit: 30)
            let known = Set(searchResults.map(\.id))
            searchResults += RepoSearchHit.hits(from: page).filter { !known.contains($0.id) }
            searchCursor = page.nextCursor
        } catch {
            searchError = error.friendlyMessage
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchActive = false
        isSearching = false
        searchResults = []
        searchCursor = nil
        searchError = nil
    }

    private func breadcrumbButton(label: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(isCurrent ? .bold : .regular)
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }

    private var pathSegments: [RepoPathSegment] {
        let trimmed = currentPath.hasPrefix("/") ? String(currentPath.dropFirst()) : currentPath
        let parts = trimmed.split(separator: "/").map(String.init)
        var result: [RepoPathSegment] = []
        var cumulative = ""
        for (index, part) in parts.enumerated() {
            cumulative += "/" + part
            result.append(RepoPathSegment(name: part, path: cumulative, depth: index + 1))
        }
        return result
    }

    private func isPinned(_ entry: CodeCommitFolderEntry) -> Bool {
        pinnedFiles.contains { $0.path == entry.path }
    }

    private func togglePin(_ entry: CodeCommitFolderEntry) {
        if isPinned(entry) {
            pinnedFiles.removeAll { $0.path == entry.path }
        } else {
            pinnedFiles.append(entry)
        }
    }

    /// Opens a file, navigating the folder browser to wherever it actually
    /// lives if it isn't already showing that folder - so jumping to a file
    /// from the quick switcher or the pin bar always leaves you able to see
    /// its neighbors, not just its preview. `showingHistory` is explicit on
    /// every call site (default false) rather than something the preview
    /// pane resets on its own, since resetting it automatically whenever
    /// the selected file changes would stomp on the "open this file already
    /// showing its history" case (double-click, "View History") the moment
    /// after it's set.
    private func open(_ entry: CodeCommitFolderEntry, showingHistory: Bool = false) {
        guard !entry.isFolder else {
            navigate(to: entry.path)
            return
        }
        selectedFile = entry
        showFileHistory = showingHistory
        let parent = parentFolder(of: entry.path)
        if parent != currentPath {
            navigate(to: parent, keepSelection: true)
        }
    }

    private func parentFolder(of path: String) -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let parts = trimmed.split(separator: "/").dropLast()
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    private func navigate(to path: String, keepSelection: Bool = false) {
        currentPath = path
        if !keepSelection {
            selectedFile = nil
        }
        listTask?.cancel()
        listState = .loading
        listTask = Task {
            do {
                let listing = try await api.getCodeCommitFolder(
                    profile: appState.currentProfile,
                    region: appState.currentRegion,
                    name: repositoryName,
                    path: path,
                    commit: defaultBranch
                )
                guard !Task.isCancelled else { return }
                listState = listing.entries.isEmpty ? .empty : .loaded(listing)
            } catch {
                guard !Task.isCancelled else { return }
                listState = .failed(error.friendlyMessage)
            }
        }
    }

    private func cancelList() {
        listTask?.cancel()
        listTask = nil
        listState = .empty
    }
}

/// Cmd+P-style jump to any file in the repository. CodeCommit has no
/// recursive listing or search API, so a match means walking the folder
/// tree by hand (`GetFolder`, breadth-first) - doing that for the *whole*
/// repo on every keystroke is what was timing out large repos. Instead:
/// search only runs when explicitly submitted (Enter or the search
/// button), the server stops as soon as it has a page of matches instead
/// of walking everything, and scrolling near the bottom of the results
/// quietly fetches the next page (10 at a time) instead of a "Load More"
/// button. Matching is case-insensitive on both ends.
private struct CodeCommitQuickFileSwitcher: View {
    let repositoryName: String
    let commitSpecifier: String
    var onSelect: (String) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    private static let pageSize = 10

    @State private var query = ""
    @State private var results: [String] = []
    @State private var nextCursor: String?
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var isLoadingMore = false
    @State private var searchError: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Go to file…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { Task { await search() } }
                Button {
                    Task { await search() }
                } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isSearching)
                .help("Search")
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            }
            .padding()

            Divider()

            resultsArea
        }
        .frame(width: 560)
        .task {
            searchFocused = true
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if isSearching {
            BrandedLoader().frame(minHeight: 240)
        } else if let searchError {
            ErrorStateView(message: searchError, retry: { Task { await search() } })
                .frame(minHeight: 240)
        } else if !hasSearched {
            EmptyStateView(message: "Type a file name and press Enter")
                .frame(minHeight: 240)
        } else if results.isEmpty {
            EmptyStateView(message: "No files match \"\(query)\"")
                .frame(minHeight: 240)
        } else {
            List {
                ForEach(results, id: \.self) { path in
                    Button {
                        onSelect(path)
                    } label: {
                        Text(path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if path == results.last {
                            Task { await loadMore() }
                        }
                    }
                }
                if nextCursor != nil {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 240, maxHeight: 420)
        }
    }

    private func search() async {
        isSearching = true
        searchError = nil
        do {
            let page = try await api.searchCodeCommitFiles(profile: appState.currentProfile, region: appState.currentRegion, repositoryName: repositoryName, commitSpecifier: commitSpecifier, query: query, cursor: nil, limit: Self.pageSize)
            results = page.paths
            nextCursor = page.nextCursor
            hasSearched = true
        } catch {
            searchError = error.friendlyMessage
        }
        isSearching = false
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let page = try await api.searchCodeCommitFiles(profile: appState.currentProfile, region: appState.currentRegion, repositoryName: repositoryName, commitSpecifier: commitSpecifier, query: query, cursor: cursor, limit: Self.pageSize)
            results += page.paths
            nextCursor = page.nextCursor
        } catch {
            searchError = error.friendlyMessage
        }
        isLoadingMore = false
    }
}
