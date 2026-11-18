import Foundation

extension AppState {
    /// Services the dashboard's sections need whose packages aren't
    /// installed (from the catalog, which carries each service's install state).
    var missingDashboardServices: Set<String> {
        let required = DashboardPrefs.requiredServices
        return Set(serviceCatalog.filter { required.contains($0.id) && $0.packagesInstalled == false }.map(\.id))
    }

    /// The display name of a catalog service ("Cost Explorer").
    func serviceName(_ id: String) -> String {
        serviceCatalog.first { $0.id == id }?.name ?? id
    }
}
