import Foundation

/// The app's version - Info.plist's CFBundleShortVersionString (kept equal
/// to packages/api/package.json and the root package.json).
enum AppVersion {
    static var short: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }

    /// The project's public page - set once it is published (shown in Settings › About).
    static let repositoryURL: URL? = nil

    /// "0.9.2" - the build only when it says something more.
    static var display: String { build.isEmpty || build == short ? short : "\(short) (\(build))" }
}
