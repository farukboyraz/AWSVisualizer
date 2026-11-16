import SwiftUI
import SwiftTerm
import AppKit

/// AppKit bridge for SwiftTerm's `LocalProcessTerminalView` - a real
/// PTY-backed terminal (proper VT100/xterm parsing, colors, cursor control,
/// interactive programs like vim/less/sudo all work), not a plain
/// "run a command, show the text output" panel. `AWSVisualizer.entitlements`
/// already has the App Sandbox off, which this needs - a sandboxed process
/// would barely be able to touch the filesystem.
struct PTYTerminalView: NSViewRepresentable {
    let executablePath: String
    let arguments: [String]
    let currentDirectory: String
    var onProcessTerminated: (Int32?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProcessTerminated: onProcessTerminated)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        view.startProcess(executable: executablePath, args: arguments, currentDirectory: currentDirectory)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // The terminal owns its own state after setup; nothing to push down
        // from SwiftUI on re-render.
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onProcessTerminated: (Int32?) -> Void

        init(onProcessTerminated: @escaping (Int32?) -> Void) {
            self.onProcessTerminated = onProcessTerminated
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onProcessTerminated(exitCode)
        }
    }
}

/// Lays out its children left-to-right, wrapping to a new row whenever the
/// next child would overflow the available width - the tab strip's chips
/// need to wrap onto a second row instead of scrolling once there are more
/// of them than fit on one line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if index > 0, x + spacing + size.width > maxWidth {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            } else if index > 0 {
                x += spacing
            }
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if index > 0, x + spacing + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            } else if index > 0 {
                x += spacing
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct DevToolsTabItem: Identifiable {
    let id: UUID
    let tool: DevTool
    var title: String
    var ptySessionID = UUID()
    var ended = false
    var exitCode: Int32?
}

/// The collapsible right-edge panel. Every enabled tool (Settings ›
/// Developer: Terminal, AI CLIs like Kiro / Claude Code / Gemini / Codex,
/// utilities, custom commands) can be opened as tabs via "+"; tabs can be
/// renamed and closed. The collapsed strip has one icon per tool.
///
/// Every open tab's PTY stays in the view tree (only opacity/hit-testing
/// follows the active tab), so switching tabs or collapsing never kills a
/// running session.
struct DevToolsPanelView: View {
    @Binding var isCollapsed: Bool
    let collapsedWidth: CGFloat
    let expandedWidth: CGFloat
    let tools: [DevTool]

    private let maxTabs = 8

    @Environment(\.colorScheme) private var colorScheme
    @State private var tabs: [DevToolsTabItem]
    @State private var activeTabID: UUID?
    @State private var counters: [String: Int] = [:]
    @State private var installed: Set<String>?
    @State private var renamingTabID: UUID?
    @State private var renameText = ""

    init(isCollapsed: Binding<Bool>, collapsedWidth: CGFloat, expandedWidth: CGFloat, tools: [DevTool]) {
        self._isCollapsed = isCollapsed
        self.collapsedWidth = collapsedWidth
        self.expandedWidth = expandedWidth
        self.tools = tools
        if let first = tools.first {
            let tab = DevToolsTabItem(id: UUID(), tool: first, title: first.name)
            self._tabs = State(initialValue: [tab])
            self._activeTabID = State(initialValue: tab.id)
            self._counters = State(initialValue: [first.id: 1])
        } else {
            self._tabs = State(initialValue: [])
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                ZStack {
                    ForEach(tabs) { tab in
                        content(for: tab)
                            .opacity(activeTabID == tab.id ? 1 : 0)
                            .allowsHitTesting(activeTabID == tab.id)
                    }
                    if tabs.isEmpty {
                        emptyState
                    }
                }
            }
            .frame(width: expandedWidth)

            if isCollapsed {
                collapsedStrip
                    .frame(width: collapsedWidth)
                    .background(Theme.sidebarBackground(colorScheme))
            }
        }
        .frame(width: isCollapsed ? collapsedWidth : expandedWidth, alignment: .leading)
        .clipped()
        .background(Theme.sidebarPanelBackground(colorScheme))
        .task {
            installed = await DevToolLocator.installed(tools.compactMap(\.binary))
        }
        .alert("Rename Session", isPresented: Binding(
            get: { renamingTabID != nil },
            set: { if !$0 { renamingTabID = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renamingTabID, !renameText.isEmpty {
                    updateTab(id) { $0.title = renameText }
                }
                renamingTabID = nil
            }
            Button("Cancel", role: .cancel) { renamingTabID = nil }
        }
    }

    private func isInstalled(_ tool: DevTool) -> Bool? {
        guard let binary = tool.binary else { return true }
        return installed.map { $0.contains(binary) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            FlowLayout(spacing: 4, rowSpacing: 4) {
                ForEach(tabs) { tab in
                    tabChip(tab)
                }
                if tabs.count < maxTabs {
                    addTabMenu
                }
            }
            Spacer(minLength: 4)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = true }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Color.secondary.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Collapse")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var addTabMenu: some View {
        Menu {
            ForEach(DevTool.Category.allCases, id: \.self) { category in
                let group = tools.filter { $0.category == category }
                if !group.isEmpty {
                    Section(category.rawValue) {
                        ForEach(group) { tool in
                            Button {
                                open(tool)
                            } label: {
                                Label(isInstalled(tool) == false ? "\(tool.name) (not installed)" : tool.name, systemImage: tool.icon)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help("New session")
    }

    private func tabChip(_ tab: DevToolsTabItem) -> some View {
        let isActive = tab.id == activeTabID
        return HStack(spacing: 5) {
            Image(systemName: tab.tool.icon)
            Text(tab.title)
                .lineLimit(1)
            Button {
                closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 0.7 : 0.35)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(isActive ? Color.primary : Color.secondary)
        .background(
            isActive ? Color.secondary.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            activeTabID = tab.id
        }
        .contextMenu {
            Button("Rename") {
                renameText = tab.title
                renamingTabID = tab.id
            }
            Button("Close", role: .destructive) { closeTab(tab) }
        }
    }

    private var collapsedStrip: some View {
        VStack(spacing: 10) {
            ForEach(tools) { tool in
                collapsedIconButton(icon: tool.icon, help: tool.name) {
                    if let existing = tabs.first(where: { $0.tool.id == tool.id }) {
                        activeTabID = existing.id
                    } else {
                        open(tool)
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 10)
        .frame(maxHeight: .infinity)
    }

    private func collapsedIconButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = false }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No open sessions").font(.callout).foregroundStyle(.secondary)
            FlowLayout(spacing: 8, rowSpacing: 8) {
                ForEach(tools) { tool in
                    SecondaryButton(tool.name, systemImage: tool.icon) { open(tool) }
                }
            }
            .frame(maxWidth: expandedWidth - 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground(colorScheme))
    }

    private func open(_ tool: DevTool) {
        guard tabs.count < maxTabs else { return }
        let number = (counters[tool.id] ?? 0) + 1
        counters[tool.id] = number
        let tab = DevToolsTabItem(id: UUID(), tool: tool, title: number == 1 ? tool.name : "\(tool.name) \(number)")
        tabs.append(tab)
        activeTabID = tab.id
    }

    private func closeTab(_ tab: DevToolsTabItem) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if activeTabID == tab.id {
            activeTabID = tabs.isEmpty ? nil : tabs[max(0, index - 1)].id
        }
    }

    private func updateTab(_ id: UUID, _ mutate: (inout DevToolsTabItem) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tabs[index])
    }

    @ViewBuilder
    private func content(for tab: DevToolsTabItem) -> some View {
        if isInstalled(tab.tool) == false {
            missingPlaceholder(tab.tool)
        } else if isInstalled(tab.tool) == true {
            ZStack {
                PTYTerminalView(
                    executablePath: DevToolLocator.shell,
                    arguments: DevToolLocator.launchArguments(for: tab.tool),
                    currentDirectory: NSHomeDirectory(),
                    onProcessTerminated: { code in
                        updateTab(tab.id) {
                            $0.exitCode = code
                            $0.ended = true
                        }
                    }
                )
                .id(tab.ptySessionID)

                if tab.ended {
                    endedOverlay(exitCode: tab.exitCode) {
                        updateTab(tab.id) {
                            $0.ended = false
                            $0.exitCode = nil
                            $0.ptySessionID = UUID()
                        }
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func missingPlaceholder(_ tool: DevTool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("\(tool.name) isn't installed")
                .font(.callout.bold())
            if let binary = tool.binary {
                Text("`\(binary)` wasn't found in your login shell's PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let url = tool.installURL {
                DownloadButton("Install \(tool.name)") {
                    NSWorkspace.shared.open(url)
                }
            }
            SecondaryButton("Check again") {
                Task { installed = await DevToolLocator.installed(tools.compactMap(\.binary)) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground(colorScheme))
    }

    private func endedOverlay(exitCode: Int32?, onRestart: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text("Session ended" + (exitCode.map { " (exit code \($0))" } ?? ""))
                .font(.callout)
                .foregroundStyle(.secondary)
            NewButton("New Session", action: onRestart)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground(colorScheme))
    }
}
