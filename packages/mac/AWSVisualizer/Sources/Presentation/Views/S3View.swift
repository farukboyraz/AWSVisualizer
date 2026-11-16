import SwiftUI
import AppKit

enum S3PreviewContent {
    case text(String)
    case json(String)
    case xml(String)
    case pdf(Data)
    case image(Data)
    case unsupported(reason: String)
}

private struct PathSegment {
    let name: String
    let prefix: String
    let depth: Int
}

/// Files the browser opens like a folder instead of previewing - zip and
/// everything built on it, gzip / tar. The server recognizes the real
/// format from the bytes; a `.dat` that turns out not to be an archive is
/// previewed as a file instead.
private func isArchiveLike(_ name: String) -> Bool {
    let lower = name.lowercased()
    if lower.hasSuffix(".tar.gz") { return true }
    let ext = lower.split(separator: ".").last.map(String.init) ?? ""
    return ["zip", "eff", "dat", "jar", "war", "ear", "apk", "aar", "nupkg", "vsix", "whl", "ipa", "epub", "gz", "tgz", "tar"].contains(ext)
}

private func isImageFile(_ name: String) -> Bool {
    FileKind(name: name, isFolder: false) == .image && !name.lowercased().hasSuffix(".svg")
}

/// An archive opened like a folder. Level 0 is the S3 object itself; each
/// deeper level is an archive entry inside the previous one (e.g. a .dat
/// inside a .eff). `folder` is the folder inside this level's archive.
private struct ArchiveLevel {
    let name: String
    let chain: [String]
    let entries: [ZipEntry]
    var folder: String = ""
}

/// The file shown in the preview.
private enum SelectedFile: Equatable {
    case object(key: String)
    /// `chain` = the archive level's chain + the entry path.
    case entry(chain: [String])

    var name: String {
        switch self {
        case .object(let key): key.components(separatedBy: "/").last ?? key
        case .entry(let chain): (chain.last ?? "").components(separatedBy: "/").last ?? ""
        }
    }
}

/// S3 browser: one location row on top - `Buckets / bucket / folder /
/// plan.eff / x.dat / file.xml`, every part clickable, Back and search on
/// the right - then one list (buckets, a folder, or the inside of an
/// archive) and the preview. Archives open in the list like folders, in
/// both layouts.
struct S3View: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var bucketsState: LoadState<[S3Bucket]> = .loading
    @State private var selectedBucket: S3Bucket?
    @State private var objectsState: LoadState<S3Objects> = .empty
    @State private var currentPrefix: String = ""

    /// S3 key of the outermost open archive (nil = browsing S3 itself).
    @State private var archiveKey: String?
    @State private var archiveLevels: [ArchiveLevel] = []
    @State private var archiveOpening: LoadState<Void> = .empty
    @State private var archiveTask: Task<Void, Never>?

    @State private var selectedFile: SelectedFile?
    @State private var previewState: LoadState<S3PreviewContent> = .empty
    @State private var previewTask: Task<Void, Never>?
    @State private var showFullscreenPreview = false

    private enum SearchScope: String, CaseIterable {
        case currentFolder = "This Folder"
        case wholeBucket = "Whole Bucket"

        var icon: String { self == .currentFolder ? "folder" : "externaldrive" }
        var help: String {
            self == .currentFolder
                ? "This Folder - search only the folder you're in (every page of it)"
                : "Whole Bucket - search every key in the bucket, all folders"
        }
    }

    @State private var searchQuery = ""
    @State private var searchScope: SearchScope = .currentFolder
    @State private var searchExpanded = false
    @State private var locationBarWidth: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @State private var bucketSearchState: LoadState<[S3Object]> = .empty
    @State private var bucketSearchTask: Task<Void, Never>?
    @State private var folderSearchState: LoadState<S3Objects> = .empty
    @State private var folderSearchTask: Task<Void, Never>?

    var body: some View {
        AuthGuardedView {
            VStack(spacing: 0) {
                ScreenTitle("S3")
                locationBar
                Divider()
                MasterDetailView(
                    initialWidth: 380, minWidth: 260, maxWidth: 640,
                    isDetailActive: selectedFile != nil,
                    onBack: closePreview,
                    backTitle: selectedBucket?.name ?? "Buckets",
                    showsBackBar: false
                ) {
                    browserList
                } detail: {
                    previewPanel
                }
            }
            .task(id: "\(appState.currentProfile)-\(appState.currentRegion)") {
                await loadBuckets()
            }
            .sheet(isPresented: $showFullscreenPreview) {
                fullscreenSheet
            }
        }
    }

    // MARK: - Location row

    private var locationBar: some View {
        PathBar(onBack: canGoBack ? goBack : nil, backAtEnd: true, crumbs: crumbs) {
            HStack(spacing: 6) {
                if selectedFile != nil {
                    Button { showFullscreenPreview = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.plain)
                        .help("Fullscreen preview")
                    Button { Task { await downloadSelected() } } label: { Image(systemName: "arrow.down.circle") }
                        .buttonStyle(.plain)
                        .help("Download")
                }
                if selectedBucket != nil { searchControl }
            }
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { locationBarWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, width in locationBarWidth = width }
        })
    }

    private var crumbs: [PathCrumb] {
        var list: [PathCrumb] = [PathCrumb(title: "Buckets", icon: AnyView(Image(systemName: "square.stack.3d.up")), action: selectedBucket == nil ? nil : { resetToBucketList() })]
        guard let bucket = selectedBucket else { return list }
        list.append(PathCrumb(title: bucket.name ?? "Bucket", icon: AnyView(Image(systemName: "externaldrive")), action: { go(to: "") }))
        for segment in pathAncestors {
            list.append(PathCrumb(title: segment.name, icon: AnyView(FileIcon(name: segment.name, isFolder: true)), action: { go(to: segment.prefix) }))
        }
        for (index, level) in archiveLevels.enumerated() {
            list.append(PathCrumb(title: level.name, icon: AnyView(FileIcon(name: level.name, isOpenArchive: true)), action: { openArchiveFolder(level: index, folder: "") }))
            var cumulative = ""
            for part in level.folder.split(separator: "/") {
                cumulative += part + "/"
                let target = cumulative
                list.append(PathCrumb(title: String(part), icon: AnyView(FileIcon(name: String(part), isFolder: true)), action: { openArchiveFolder(level: index, folder: target) }))
            }
        }
        if let selectedFile {
            list.append(PathCrumb(title: selectedFile.name, icon: AnyView(FileIcon(name: selectedFile.name))))
        }
        // The last part is where we are - not a link.
        if selectedFile == nil, !list.isEmpty { list[list.count - 1].action = nil }
        return list
    }

    private var canGoBack: Bool { selectedBucket != nil || selectedFile != nil }

    /// One level up: file → its folder → parent folder → … → bucket list.
    private func goBack() {
        if selectedFile != nil {
            closePreview()
        } else if var level = archiveLevels.last {
            if !level.folder.isEmpty {
                level.folder = parentFolder(level.folder)
                archiveLevels[archiveLevels.count - 1] = level
            } else {
                archiveLevels.removeLast()
                if archiveLevels.isEmpty { closeArchive() }
            }
        } else if !currentPrefix.isEmpty {
            go(to: parentFolder(currentPrefix))
        } else {
            resetToBucketList()
        }
    }

    /// Search: a field with This Folder / Whole Bucket icons when the row
    /// has room, otherwise a magnifier that expands to the left on click.
    /// Inside an archive it filters the archive's current folder.
    private var searchControl: some View {
        let roomy = locationBarWidth > 820
        let open = roomy || searchExpanded || !searchQuery.isEmpty
        return HStack(spacing: 4) {
            if open {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(archiveKey == nil ? "Search files and folders" : "Filter this folder", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .frame(width: 200)
                        .onSubmit { startSearch(debounced: false) }
                        .onChange(of: searchQuery) { _, newValue in
                            if newValue.isEmpty {
                                clearSearchResults()
                            } else {
                                startSearch(debounced: true)
                            }
                        }
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            clearSearchResults()
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .transition(.move(edge: .trailing).combined(with: .opacity))
                if archiveKey == nil {
                    ForEach(SearchScope.allCases, id: \.self) { scope in
                        Button {
                            searchScope = scope
                            if !searchQuery.isEmpty { startSearch(debounced: false) }
                        } label: {
                            Image(systemName: scope.icon)
                                .frame(width: 24, height: 22)
                                .foregroundStyle(searchScope == scope ? Color.white : Color.secondary)
                                .background(searchScope == scope ? Color.accentColor : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help(scope.help)
                    }
                }
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { searchExpanded = true }
                    searchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 24, height: 24)
                        .background(Color.secondary.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Search")
            }
        }
        .onChange(of: searchFocused) { _, focused in
            if !focused && searchQuery.isEmpty {
                withAnimation(.easeOut(duration: 0.18)) { searchExpanded = false }
            }
        }
    }

    // MARK: - Browser list

    @ViewBuilder
    private var browserList: some View {
        if selectedBucket == nil {
            bucketList
        } else if archiveKey != nil {
            archiveList
        } else if isShowingBucketSearchResults {
            bucketSearchResultsView
        } else if isShowingFolderSearchResults {
            LoadableContent(folderSearchState, retry: { startFolderSearch(debounced: false) }, emptyMessage: "No matches in this folder") { objects in
                folderListView(objects)
            }
        } else {
            LoadableContent(objectsState, retry: { Task { await loadObjects() } }, emptyMessage: "This folder is empty") { objects in
                folderListView(objects)
            }
        }
    }

    private var bucketList: some View {
        LoadableContent(bucketsState, retry: { Task { await loadBuckets() } }) { buckets in
            List(buckets) { bucket in
                Button {
                    selectedBucket = bucket
                    go(to: "")
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive").foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bucket.name ?? "Unknown")
                                .font(.body.bold())
                            if let date = bucket.creationDate {
                                Text(Formatters.formatDate(date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }

    private func folderRow(_ name: String, isOpenArchive: Bool = false, isFolder: Bool = true) -> some View {
        HStack(spacing: 8) {
            FileIcon(name: name, isFolder: isFolder, isOpenArchive: isOpenArchive)
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func fileRow(_ name: String, detail: String?, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            FileIcon(name: name)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1).truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func folderListView(_ objects: S3Objects) -> some View {
        List {
            if let prefixes = objects.prefixes {
                ForEach(prefixes, id: \.self) { prefix in
                    folderRow(folderName(prefix))
                        .onTapGesture { go(to: prefix) }
                }
            }
            if let items = objects.objects {
                ForEach(items) { obj in
                    let name = fileName(obj.key)
                    if isArchiveLike(name) {
                        folderRow(name, isFolder: false)
                            .onTapGesture { if let key = obj.key { openArchive(key: key) } }
                            .help("Open \(name) like a folder")
                    } else {
                        fileRow(name, detail: Formatters.formatBytes(obj.size), isSelected: selectedFile == .object(key: obj.key ?? ""))
                            .onTapGesture { if let key = obj.key { preview(.object(key: key)) } }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var bucketSearchResultsView: some View {
        LoadableContent(bucketSearchState, retry: { startBucketSearch(debounced: false) }, emptyMessage: "No matches in this bucket") { results in
            List(results) { obj in
                let name = fileName(obj.key)
                HStack(spacing: 8) {
                    FileIcon(name: name)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                        Text(obj.key ?? "")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { openSearchResult(obj) }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Archives

    /// What's directly inside the current archive folder: sub-folders
    /// (from the entry paths - tar files don't always list them) and files.
    private func archiveChildren(_ level: ArchiveLevel) -> (folders: [String], files: [ZipEntry]) {
        var folders = Set<String>()
        var files: [ZipEntry] = []
        for entry in level.entries where entry.path.hasPrefix(level.folder) {
            let rest = String(entry.path.dropFirst(level.folder.count))
            guard !rest.isEmpty else { continue }
            if let slash = rest.firstIndex(of: "/") {
                folders.insert(String(rest[..<slash]))
            } else if !entry.isDirectory {
                files.append(entry)
            }
        }
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        let matches: (String) -> Bool = { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        return (folders.filter(matches).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                files.filter { matches(entryName($0.path)) }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }

    @ViewBuilder
    private var archiveList: some View {
        switch archiveOpening {
        case .loading:
            BrandedLoader(message: "Opening archive…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                SecondaryButton("Back") { goBack() }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if let level = archiveLevels.last {
                let children = archiveChildren(level)
                if children.folders.isEmpty && children.files.isEmpty {
                    EmptyStateView(message: searchQuery.isEmpty ? "This folder of the archive is empty" : "No matches in this folder")
                } else {
                    List {
                        ForEach(children.folders, id: \.self) { folder in
                            folderRow(folder)
                                .onTapGesture { openArchiveFolder(level: archiveLevels.count - 1, folder: level.folder + folder + "/") }
                        }
                        ForEach(children.files) { entry in
                            let name = entryName(entry.path)
                            let chain = level.chain + [entry.path]
                            if isArchiveLike(name) {
                                folderRow(name, isFolder: false)
                                    .onTapGesture { openNestedArchive(entry: entry, in: level) }
                                    .help("Open \(name) like a folder")
                            } else {
                                fileRow(name, detail: nil, isSelected: selectedFile == .entry(chain: chain))
                                    .onTapGesture { preview(.entry(chain: chain)) }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
    }

    private func openArchive(key: String) {
        guard let bucket = selectedBucket?.name else { return }
        closePreview()
        clearSearch()
        archiveKey = key
        archiveLevels = []
        archiveTask?.cancel()
        archiveOpening = .loading
        archiveTask = Task {
            do {
                let list = try await api.getZipEntries(profile: appState.currentProfile, region: appState.currentRegion, bucket: bucket, key: key, path: [])
                guard !Task.isCancelled else { return }
                archiveLevels = [ArchiveLevel(name: fileName(key), chain: [], entries: list.entries)]
                archiveOpening = .empty
            } catch {
                guard !Task.isCancelled else { return }
                if key.lowercased().hasSuffix(".dat") {
                    // A .dat that isn't an archive: preview it as a file.
                    closeArchive()
                    preview(.object(key: key))
                } else {
                    archiveOpening = .failed(error.friendlyMessage)
                }
            }
        }
    }

    private func openNestedArchive(entry: ZipEntry, in level: ArchiveLevel) {
        guard let bucket = selectedBucket?.name, let key = archiveKey else { return }
        let chain = level.chain + [entry.path]
        closePreview()
        clearSearch()
        archiveTask?.cancel()
        archiveOpening = .loading
        archiveTask = Task {
            do {
                let list = try await api.getZipEntries(profile: appState.currentProfile, region: appState.currentRegion, bucket: bucket, key: key, path: chain)
                guard !Task.isCancelled else { return }
                archiveLevels.append(ArchiveLevel(name: entryName(entry.path), chain: chain, entries: list.entries))
                archiveOpening = .empty
            } catch {
                guard !Task.isCancelled else { return }
                // Not an archive after all (a plain .dat) - just show it.
                archiveOpening = .empty
                preview(.entry(chain: chain))
            }
        }
    }

    private func openArchiveFolder(level: Int, folder: String) {
        guard level < archiveLevels.count else { return }
        closePreview()
        clearSearch()
        if level + 1 < archiveLevels.count { archiveLevels.removeSubrange((level + 1)...) }
        archiveLevels[level].folder = folder
    }

    private func closeArchive() {
        archiveTask?.cancel()
        archiveKey = nil
        archiveLevels = []
        archiveOpening = .empty
    }

    private func entryName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.components(separatedBy: "/").last ?? path
    }

    // MARK: - Navigation

    private var pathAncestors: [PathSegment] {
        let trimmed = currentPrefix.hasSuffix("/") ? String(currentPrefix.dropLast()) : currentPrefix
        guard !trimmed.isEmpty else { return [] }
        var result: [PathSegment] = []
        var cumulative = ""
        for (index, part) in trimmed.components(separatedBy: "/").enumerated() {
            cumulative += part + "/"
            result.append(PathSegment(name: part, prefix: cumulative, depth: index + 1))
        }
        return result
    }

    private func parentFolder(_ prefix: String) -> String {
        var parts = prefix.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return "" }
        parts.removeLast()
        return parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
    }

    /// Opens `prefix` of the selected bucket ("" = its root).
    private func go(to prefix: String) {
        closeArchive()
        currentPrefix = prefix
        closePreview()
        clearSearch()
        Task { await loadObjects() }
    }

    private func resetToBucketList() {
        closeArchive()
        selectedBucket = nil
        currentPrefix = ""
        closePreview()
        objectsState = .empty
        clearSearch()
    }

    // MARK: - Search

    private var isShowingBucketSearchResults: Bool { archiveKey == nil && searchScope == .wholeBucket && !searchQuery.isEmpty }
    private var isShowingFolderSearchResults: Bool { archiveKey == nil && searchScope == .currentFolder && !searchQuery.isEmpty }

    private func clearSearchResults() {
        bucketSearchTask?.cancel()
        bucketSearchState = .empty
        folderSearchTask?.cancel()
        folderSearchState = .empty
    }

    private func clearSearch() {
        searchQuery = ""
        clearSearchResults()
    }

    private func startSearch(debounced: Bool) {
        // Inside an archive the list filters itself (`archiveChildren`).
        guard archiveKey == nil else { return }
        switch searchScope {
        case .wholeBucket: startBucketSearch(debounced: debounced)
        case .currentFolder: startFolderSearch(debounced: debounced)
        }
    }

    /// `debounced: true` waits briefly for more typing before calling the
    /// API; `false` runs immediately (Return, or switching scope).
    private func startBucketSearch(debounced: Bool) {
        guard let bucket = selectedBucket?.name, !searchQuery.isEmpty else { return }
        bucketSearchTask?.cancel()
        bucketSearchState = .loading
        let query = searchQuery
        bucketSearchTask = Task {
            if debounced {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
            }
            do {
                let results = try await api.searchS3Objects(profile: appState.currentProfile, region: appState.currentRegion, bucket: bucket, prefix: nil, query: query)
                guard !Task.isCancelled else { return }
                bucketSearchState = results.isEmpty ? .empty : .loaded(results)
            } catch {
                guard !Task.isCancelled else { return }
                bucketSearchState = .failed(error.localizedDescription)
            }
        }
    }

    /// "This Folder" - paginates the whole folder server-side, so a folder
    /// with more than one page (1000 keys) is searched in full.
    private func startFolderSearch(debounced: Bool) {
        guard let bucket = selectedBucket?.name, !searchQuery.isEmpty else { return }
        folderSearchTask?.cancel()
        folderSearchState = .loading
        let query = searchQuery
        let prefix = currentPrefix
        folderSearchTask = Task {
            if debounced {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
            }
            do {
                let results = try await api.searchS3FolderObjects(profile: appState.currentProfile, region: appState.currentRegion, bucket: bucket, prefix: prefix.isEmpty ? nil : prefix, query: query)
                guard !Task.isCancelled else { return }
                let isEmpty = (results.prefixes?.isEmpty ?? true) && (results.objects?.isEmpty ?? true)
                folderSearchState = isEmpty ? .empty : .loaded(results)
            } catch {
                guard !Task.isCancelled else { return }
                folderSearchState = .failed(error.localizedDescription)
            }
        }
    }

    private func openSearchResult(_ obj: S3Object) {
        guard let key = obj.key else { return }
        let parentPrefix: String
        if let slashRange = key.range(of: "/", options: .backwards) {
            parentPrefix = String(key[..<slashRange.upperBound])
        } else {
            parentPrefix = ""
        }
        clearSearch()
        currentPrefix = parentPrefix
        Task {
            await loadObjects()
            if isArchiveLike(fileName(key)) { openArchive(key: key) } else { preview(.object(key: key)) }
        }
    }

    // MARK: - Preview

    private var previewPanel: some View {
        LoadableContent(previewState, retry: retryPreview, cancel: closePreview, emptyMessage: "Select a file to preview") { content in
            FilePreviewBody(content: content)
        }
    }

    private var retryPreview: (() -> Void)? {
        guard let selectedFile else { return nil }
        return { preview(selectedFile) }
    }

    private func closePreview() {
        previewTask?.cancel()
        previewTask = nil
        selectedFile = nil
        previewState = .empty
    }

    private func preview(_ file: SelectedFile) {
        previewTask?.cancel()
        selectedFile = file
        previewState = .loading
        previewTask = Task { await loadPreview(file) }
    }

    private func loadPreview(_ file: SelectedFile) async {
        guard let bucket = selectedBucket?.name else { return }
        let name = file.name.lowercased()
        let profile = appState.currentProfile, region = appState.currentRegion
        do {
            let content: S3PreviewContent
            switch file {
            case .object(let key):
                if isImageFile(name) {
                    content = .image(try await api.downloadS3File(profile: profile, region: region, bucket: bucket, key: key))
                } else if name.hasSuffix(".pdf") {
                    content = .pdf(try await api.downloadS3File(profile: profile, region: region, bucket: bucket, key: key))
                } else {
                    let preview = try await api.getS3Object(profile: profile, region: region, bucket: bucket, key: key)
                    if preview.isText == true, let text = preview.content {
                        content = structured(text, path: name, contentType: preview.contentType)
                    } else {
                        content = .unsupported(reason: "Binary file - use Download to save it.")
                    }
                }
            case .entry(let chain):
                guard let key = archiveKey else { return }
                if isImageFile(name) {
                    content = .image(try await api.getZipEntryData(profile: profile, region: region, bucket: bucket, key: key, path: chain))
                } else if name.hasSuffix(".pdf") {
                    content = .pdf(try await api.getZipEntryData(profile: profile, region: region, bucket: bucket, key: key, path: chain))
                } else {
                    let entry = try await api.getZipEntryContent(profile: profile, region: region, bucket: bucket, key: key, path: chain)
                    content = structured(entry.content, path: name, contentType: nil)
                }
            }
            guard !Task.isCancelled else { return }
            previewState = .loaded(content)
        } catch {
            guard !Task.isCancelled else { return }
            previewState = .failed(error.friendlyMessage)
        }
    }

    private func structured(_ text: String, path: String, contentType: String?) -> S3PreviewContent {
        switch StructuredKind.classify(path: path, contentType: contentType) {
        case .json: .json(text)
        case .xml: .xml(text)
        case .plain: .text(text)
        }
    }

    private var fullscreenSheet: some View {
        VStack(spacing: 0) {
            HStack {
                if let selectedFile {
                    FileIcon(name: selectedFile.name)
                    Text(selectedFile.name).font(.headline)
                }
                Spacer()
                Button { Task { await downloadSelected() } } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.plain)
                    .help("Download")
                SheetMaximizeButton()
                SecondaryButton("Close") { showFullscreenPreview = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            LoadableContent(previewState, retry: retryPreview, cancel: closePreview, emptyMessage: "Nothing to preview") { content in
                FilePreviewBody(content: content)
            }
        }
        .frame(minWidth: 620, idealWidth: 820, maxWidth: .infinity, minHeight: 420, idealHeight: 620, maxHeight: .infinity)
        .resizableSheet(minWidth: 620, minHeight: 420)
    }

    // MARK: - Helpers

    private func folderName(_ prefix: String) -> String {
        let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return trimmed.components(separatedBy: "/").last ?? prefix
    }

    private func fileName(_ key: String?) -> String {
        guard let key else { return "-" }
        return key.components(separatedBy: "/").last ?? key
    }

    // MARK: - Data loading

    private func loadBuckets() async {
        resetToBucketList()
        bucketsState = .loading
        do {
            let buckets = try await api.getS3Buckets(profile: appState.currentProfile, region: appState.currentRegion)
            bucketsState = buckets.isEmpty ? .empty : .loaded(buckets)
            // A dashboard card asked for one bucket.
            if let link = appState.takeDeepLink(for: "s3"), let bucket = buckets.first(where: { $0.name == link.resource }) {
                selectedBucket = bucket
                go(to: link.prefix ?? "")
                // The card's "name contains" goes into the search field and runs in that folder.
                if let text = appState.takePendingFilter() {
                    searchScope = .currentFolder
                    searchQuery = text
                    startSearch(debounced: false)
                }
            }
        } catch {
            bucketsState = .failed(error.localizedDescription)
        }
    }

    private func loadObjects() async {
        guard let bucket = selectedBucket?.name else { return }
        objectsState = .loading
        do {
            let objects = try await api.getS3Objects(profile: appState.currentProfile, region: appState.currentRegion, bucket: bucket, prefix: currentPrefix)
            let isEmpty = (objects.prefixes?.isEmpty ?? true) && (objects.objects?.isEmpty ?? true)
            objectsState = isEmpty ? .empty : .loaded(objects)
        } catch {
            objectsState = .failed(error.localizedDescription)
        }
    }

    private func downloadSelected() async {
        guard let bucket = selectedBucket?.name, let selectedFile else { return }
        do {
            let data: Data
            switch selectedFile {
            case .object(let key):
                data = try await api.downloadS3File(profile: appState.currentProfile, region: appState.currentRegion, bucket: bucket, key: key)
            case .entry(let chain):
                guard let key = archiveKey else { return }
                data = try await api.getZipEntryData(profile: appState.currentProfile, region: appState.currentRegion, bucket: bucket, key: key, path: chain)
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = selectedFile.name
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
            }
        } catch {
            previewState = .failed(error.friendlyMessage)
        }
    }
}

// MARK: - File preview body

private struct FilePreviewBody: View {
    let content: S3PreviewContent

    var body: some View {
        switch content {
        case .text(let text):
            StructuredContentView(text: text, kind: .plain)
        case .json(let text):
            StructuredContentView(text: text, kind: .json)
        case .xml(let text):
            StructuredContentView(text: text, kind: .xml)
        case .pdf(let data):
            PDFPreviewView(data: data)
        case .image(let data):
            ImagePreviewView(data: data)
        case .unsupported(let reason):
            VStack(spacing: 8) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(reason)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
