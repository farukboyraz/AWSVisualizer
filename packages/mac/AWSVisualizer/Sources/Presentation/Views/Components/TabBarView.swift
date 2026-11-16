import SwiftUI

struct TabBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    @State private var showCloseAllConfirmation = false

    var body: some View {
        HStack(spacing: 4) {
            if appState.tabs.count > 1 {
                closeAllButton
            }
            ForEach(appState.tabs) { tab in
                tabChip(tab)
            }
            Spacer(minLength: 8)
            Text("(\(appState.maxTabs) max tabs)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.tabBarBackground(colorScheme))
        .confirmationDialog(appState.language.closeAllTabsConfirmationTitle, isPresented: $showCloseAllConfirmation, titleVisibility: .visible) {
            Button(appState.language.closeAllTabsLabel, role: .destructive) {
                appState.resetToDashboard()
            }
            Button(appState.language.cancelButtonTitle, role: .cancel) {}
        } message: {
            Text(appState.language.closeAllTabsConfirmationMessage)
        }
    }

    /// Sits at the far left like an extra "tab" - closes every open tab at
    /// once (behind a confirmation, since it's the one tab action that
    /// can't be undone by reopening a single tab).
    private var closeAllButton: some View {
        Button {
            showCloseAllConfirmation = true
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help(appState.language.closeAllTabsLabel)
    }

    private func tabChip(_ tab: WorkspaceTab) -> some View {
        let isActive = tab.id == appState.activeTabID
        let name = tab.serviceID == dashboardServiceID
            ? "Dashboard"
            : (appState.serviceCatalog.first { $0.id == tab.serviceID }?.name ?? tab.serviceID)
        let entry = appState.serviceCatalog.first { $0.id == tab.serviceID }
        let icon = tab.serviceID == dashboardServiceID ? "square.grid.2x2" : (entry?.icon ?? "square")
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(entry?.tint ?? .secondary)
            Text(name)
                .font(.caption)
                .lineLimit(1)
            if appState.tabs.count > 1 {
                Button {
                    appState.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .opacity(isActive ? 0.7 : 0.35)
            }
        }
        .foregroundStyle(isActive ? Color.primary : Color.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.activateTab(tab.id)
        }
        .contextMenu {
            Button(appState.language.closeTabLabel) {
                appState.closeTab(tab.id)
            }
            .disabled(appState.tabs.count <= 1)

            Button(appState.language.closeOtherTabsLabel) {
                appState.closeOtherTabs(keeping: tab.id)
            }
            .disabled(appState.tabs.count <= 1)

            Button(appState.language.closeAllTabsLabel) {
                showCloseAllConfirmation = true
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}
