import SwiftUI

/// A generic path-segment tree, built by splitting each item's path on "/".
/// Used to render flat "a/b/c"-style names - file paths, branch names like
/// "features/cabin-remark" - as an actual folder/leaf hierarchy instead of
/// one long flat list.
struct PathTreeNode<T>: Identifiable {
    let id: String
    let name: String
    var children: [PathTreeNode<T>]
    let payload: T?

    var isLeaf: Bool { children.isEmpty }
}

private final class PathTreeBuilder<T> {
    let name: String
    var payload: T?
    var children: [String: PathTreeBuilder<T>] = [:]
    var order: [String] = []
    init(name: String) { self.name = name }
}

/// Folders always sort before leaves at each level, and within either group
/// names sort A-Z - the same convention as Finder/Xcode's file navigator.
func buildPathTree<T>(_ items: [T], path: (T) -> String) -> [PathTreeNode<T>] {
    let root = PathTreeBuilder<T>(name: "")

    for item in items {
        let segments = path(item).split(separator: "/").map(String.init)
        guard !segments.isEmpty else { continue }
        var current = root
        for (index, segment) in segments.enumerated() {
            if current.children[segment] == nil {
                current.children[segment] = PathTreeBuilder<T>(name: segment)
                current.order.append(segment)
            }
            current = current.children[segment]!
            if index == segments.count - 1 {
                current.payload = item
            }
        }
    }

    func convert(_ builder: PathTreeBuilder<T>, prefix: String) -> PathTreeNode<T> {
        let fullPath = prefix.isEmpty ? builder.name : "\(prefix)/\(builder.name)"
        let sortedKeys = builder.order.sorted { a, b in
            let childA = builder.children[a]!
            let childB = builder.children[b]!
            let aIsFolder = !childA.children.isEmpty
            let bIsFolder = !childB.children.isEmpty
            if aIsFolder != bIsFolder { return aIsFolder }
            return childA.name.localizedCaseInsensitiveCompare(childB.name) == .orderedAscending
        }
        let children = sortedKeys.map { convert(builder.children[$0]!, prefix: fullPath) }
        return PathTreeNode(id: fullPath, name: builder.name, children: children, payload: builder.payload)
    }

    return root.order
        .map { convert(root.children[$0]!, prefix: "") }
        .sorted { a, b in
            if a.isLeaf != b.isLeaf { return !a.isLeaf }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
}

/// Every folder id (non-leaf node) in a tree, recursively - for driving
/// "Expand All" (populate this whole set) / "Collapse All" (empty it).
func allPathTreeFolderIDs<T>(in nodes: [PathTreeNode<T>]) -> Set<String> {
    var result = Set<String>()
    for node in nodes where !node.isLeaf {
        result.insert(node.id)
        result.formUnion(allPathTreeFolderIDs(in: node.children))
    }
    return result
}

/// Renders a `PathTreeNode` list as collapsible folders with `rowContent`
/// for each leaf. `initiallyExpanded` controls whether folders start open
/// (the default, so a diff's file tree isn't hidden by surprise) or closed
/// (used for branch lists, where the interesting thing is the leaf names,
/// not the grouping) - ignored when `expandedIDs` is provided, see below.
/// `forceExpanded` overrides every folder open regardless of its own state
/// or the user's toggling - used while a search filter is narrowing the
/// tree, so matches stay visible.
///
/// Pass `expandedIDs` to move expand/collapse state out of each folder's
/// own private `@State` and into a shared set the caller owns - needed for
/// "Expand All"/"Collapse All" controls, since those need to see and flip
/// every folder's state at once. Leave it nil (the default) for the plain
/// self-contained behavior the diff/file trees use.
struct PathTreeView<T, RowContent: View>: View {
    let nodes: [PathTreeNode<T>]
    var initiallyExpanded: Bool = true
    var forceExpanded: Bool = false
    var expandedIDs: Binding<Set<String>>? = nil
    @ViewBuilder var rowContent: (T) -> RowContent

    var body: some View {
        ForEach(nodes) { node in
            if node.isLeaf, let payload = node.payload {
                rowContent(payload)
            } else {
                PathTreeFolder(node: node, initiallyExpanded: initiallyExpanded, forceExpanded: forceExpanded, expandedIDs: expandedIDs, rowContent: rowContent)
            }
        }
    }
}

private struct PathTreeFolder<T, RowContent: View>: View {
    let node: PathTreeNode<T>
    let initiallyExpanded: Bool
    let forceExpanded: Bool
    let expandedIDs: Binding<Set<String>>?
    @ViewBuilder var rowContent: (T) -> RowContent

    @State private var localExpanded: Bool

    init(node: PathTreeNode<T>, initiallyExpanded: Bool, forceExpanded: Bool, expandedIDs: Binding<Set<String>>?, @ViewBuilder rowContent: @escaping (T) -> RowContent) {
        self.node = node
        self.initiallyExpanded = initiallyExpanded
        self.forceExpanded = forceExpanded
        self.expandedIDs = expandedIDs
        self.rowContent = rowContent
        self._localExpanded = State(initialValue: initiallyExpanded)
    }

    private var isExpanded: Bool {
        if forceExpanded { return true }
        if let expandedIDs { return expandedIDs.wrappedValue.contains(node.id) }
        return localExpanded
    }

    private func toggle() {
        guard !forceExpanded else { return }
        if let expandedIDs {
            if expandedIDs.wrappedValue.contains(node.id) {
                expandedIDs.wrappedValue.remove(node.id)
            } else {
                expandedIDs.wrappedValue.insert(node.id)
            }
        } else {
            localExpanded.toggle()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A plain-style Button, not `.onTapGesture` on a bare VStack -
            // this row can sit inside a `List(selection:)` (the PR/commit
            // diff file tree does), where an untagged row with only a tap
            // gesture gets its click stolen by the List's own native row-
            // selection handling instead of toggling the folder. A Button
            // captures the click itself, so it never reaches that layer.
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    FileIcon(name: node.name, isFolder: true)
                    Text(node.name)
                        .font(.caption.bold())
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                PathTreeView(nodes: node.children, initiallyExpanded: initiallyExpanded, forceExpanded: forceExpanded, expandedIDs: expandedIDs, rowContent: rowContent)
                    .padding(.leading, 14)
            }
        }
    }
}
