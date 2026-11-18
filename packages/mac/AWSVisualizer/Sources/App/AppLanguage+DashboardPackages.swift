import Foundation

/// Text of the dashboard's "install the packages a section needs" prompt and buttons.
extension AppLanguage {
    var dashPackagesTitle: String { self == .tr ? "Dashboard için paket gerekli" : "The dashboard needs a package" }

    func dashPackagesMessage(services: [String], sections: [String]) -> String {
        let s = sections.joined(separator: ", ")
        let p = services.joined(separator: ", ")
        return self == .tr
            ? "\(s) bölümleri için \(p) paketi gerekiyor. Şimdi yüklensin mi?\n\nHayır derseniz bu bölümler kapanır; daha sonra Bölümler menüsünden ya da Settings › Display › Dashboard'dan yükleyip açabilirsiniz."
            : "The \(s) sections need the \(p) package. Install it now?\n\nIf you say no, these sections are turned off; you can install and turn them on later from the Sections menu or Settings › Display › Dashboard."
    }

    var dashPackagesInstall: String { self == .tr ? "Yükle" : "Install" }

    func dashPackagesInstallHelp(_ service: String) -> String {
        self == .tr ? "\(service) paketini yükle; bitince bölüm açılır" : "Install the \(service) package; the section turns on when it's done"
    }

    func dashPackagesMissing(_ service: String) -> String {
        self == .tr ? "\(service) paketi yüklü değil" : "\(service) package not installed"
    }
}
