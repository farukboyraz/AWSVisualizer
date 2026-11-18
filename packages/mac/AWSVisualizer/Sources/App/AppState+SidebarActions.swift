import Foundation

/// What the sidebar's service right-click menu does (`SidebarServiceMenu`).
/// Each change is saved to ~/.awsvisualizer right away, like the favorite
/// stars in Select Services; on failure the old state is put back.
extension AppState {
    /// A tab of its own, even when the service is already open in one
    /// (plain `openInNewTab` switches to that tab instead).
    func openInAdditionalTab(_ serviceID: String) {
        guard maxTabs > 1 else {
            selectedService = serviceID
            return
        }
        guard tabs.count < maxTabs else {
            tabLimitWarningVisible = true
            return
        }
        let tab = WorkspaceTab(serviceID: serviceID)
        tabs.append(tab)
        activeTabID = tab.id
    }

    @MainActor
    func setFavorite(_ serviceID: String, _ isFavorite: Bool, using api: APIService) async throws {
        let previous = favoriteServiceIDs
        var favorites = previous
        if isFavorite { favorites.insert(serviceID) } else { favorites.remove(serviceID) }
        favoriteServiceIDs = favorites
        do {
            try await api.setFavoriteServices(Array(favorites))
        } catch {
            favoriteServiceIDs = previous
            throw error
        }
    }

    /// Takes the service off the sidebar list and closes only its tabs
    /// (Settings' bulk save goes back to Dashboard instead). The last
    /// selected service stays - an empty sidebar would reopen onboarding.
    @MainActor
    func removeFromSidebar(_ serviceID: String, using api: APIService) async throws {
        guard selectedServiceIDs.count > 1 else { return }
        let previous = selectedServiceIDs
        let remaining = previous.filter { $0 != serviceID }
        selectedServiceIDs = remaining
        do {
            try await api.setSelectedServices(remaining)
        } catch {
            selectedServiceIDs = previous
            throw error
        }
        if favoriteServiceIDs.contains(serviceID) {
            try? await setFavorite(serviceID, false, using: api)
        }
        closeTabs(of: serviceID)
    }

    /// Closes every tab showing the service; the last tab goes to Dashboard.
    func closeTabs(of serviceID: String) {
        let kept = tabs.filter { $0.serviceID != serviceID }
        if kept.isEmpty {
            resetToDashboard()
            return
        }
        let activeWasClosed = !kept.contains { $0.id == activeTabID }
        tabs = kept
        if activeWasClosed, let last = kept.last { activeTabID = last.id }
    }

    /// Appends a card to the dashboard and saves it (same as adding one on
    /// the dashboard; the sidecar fills in its kind / icon).
    @MainActor
    func addDashboardCard(_ card: DashboardCard, using api: APIService) async throws {
        let previous = dashboardPrefs
        var updated = previous
        updated.cards.append(card)
        dashboardPrefs = updated
        do {
            let saved = try await api.updateDashboardPrefs(updated)
            if let prefs = saved.dashboard { dashboardPrefs = prefs }
        } catch {
            dashboardPrefs = previous
            throw error
        }
    }
}
