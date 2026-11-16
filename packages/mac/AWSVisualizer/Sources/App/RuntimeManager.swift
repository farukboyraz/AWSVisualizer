import Foundation
import CryptoKit

/// `major.minor.patch` from `v22.23.2` / `10.9.8`.
struct SemVer: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        guard let major = parts.first else { return nil }
        self.major = major
        minor = parts.count > 1 ? parts[1] : 0
        patch = parts.count > 2 ? parts[2] : 0
    }

    init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// A node + npm pair found on disk.
struct NodeRuntime: Equatable {
    let binDirectory: URL
    let nodeVersion: SemVer
    let npmVersion: SemVer?
    let source: NodeSource

    var managedByApp: Bool { source == .appLocal }

    static func == (a: NodeRuntime, b: NodeRuntime) -> Bool { a.binDirectory == b.binDirectory }
}

/// Where a Node.js install came from.
enum NodeSource: Equatable {
    /// `~/Library/Application Support/AWSVisualizer/node` - only this app uses it.
    case appLocal
    /// `~/.nvm/versions/node/<v>`; `isDefault` = `nvm alias default` points at it.
    case nvm(isDefault: Bool)
    /// /usr/local/bin - the official nodejs.org .pkg installs here.
    case system
    case homebrew
    case other

    var label: String {
        switch self {
        case .appLocal: "AWS Visualizer only"
        case .nvm(let isDefault): isDefault ? "nvm (default)" : "nvm"
        case .system: "System (/usr/local)"
        case .homebrew: "Homebrew"
        case .other: "Other"
        }
    }
}

/// Outcome of the pre-login Node.js / npm check.
enum RuntimeCheck: Equatable {
    /// Node ≥ 22 and npm ≥ 10.
    case ok(NodeRuntime)
    /// Node 20-21 (runs, but out of support) or npm 9: usable, with a warning.
    case outdated(NodeRuntime)
    /// Node older than 20 or npm older than 9 - the sidecar can't run on it.
    case tooOld(NodeRuntime)
    case missing

    var runtime: NodeRuntime? {
        switch self {
        case .ok(let r), .outdated(let r), .tooOld(let r): r
        case .missing: nil
        }
    }
}

/// Finds, checks and (if needed) installs the Node.js the local API runs on,
/// and the sidecar's own (core) npm packages - all before the login screen.
///
/// Version policy (Nov 2026): the dependencies need Node ≥ 20
/// (`@aws-sdk/util-locate-window`, tsx/esbuild ≥ 18), but Node 20 left
/// support on 2026-04-30, so 22 (LTS until 2027-04-30) is required and 20-21
/// only warns. npm ≥ 9 is needed for `--omit` / workspaces; 10 ships with 22.
@MainActor
final class RuntimeManager {
    static let shared = RuntimeManager()

    static let minimumNode = SemVer(20)
    static let recommendedNode = SemVer(22)
    static let minimumNpm = SemVer(9)
    static let recommendedNpm = SemVer(10)
    /// The major the app installs from nodejs.org.
    static let installMajor = 22

    /// The runtime the sidecar is started with (set by `check()` / `use(_:)`).
    private(set) var selected: NodeRuntime?

    private init() {}

    static var appSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AWSVisualizer")
    }

    /// Where an app-installed Node lives (`…/node/bin/node`). `AWSVIS_NODE_DIR`
    /// moves it (testing the install screen without touching the real one).
    static var managedNodeDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["AWSVIS_NODE_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return appSupportDirectory.appendingPathComponent("node")
    }

    /// Test hook: `AWSVIS_RUNTIME_TEST=missing|old|outdated` makes the check
    /// report that result, so the Node.js screens can be tried on a machine
    /// that already has a good Node. Unset in normal use.
    private static var simulatedResult: String? {
        let value = ProcessInfo.processInfo.environment["AWSVIS_RUNTIME_TEST"]
        return value?.isEmpty == false ? value : nil
    }

    func use(_ runtime: NodeRuntime) { selected = runtime }

    // MARK: - Detection

    static var nvmDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["NVM_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm")
    }

    static var isNvmInstalled: Bool { FileManager.default.fileExists(atPath: nvmDirectory.appendingPathComponent("nvm.sh").path) }

    /// The bin directory picked in Settings (`runtime.preferredNodeBin` in
    /// ~/.awsvisualizer, read directly - the sidecar isn't running yet).
    static var preferredBinDirectory: URL? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".awsvisualizer")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtime = json["runtime"] as? [String: Any],
              let path = runtime["preferredNodeBin"] as? String, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// `nvm version default` (e.g. v22.23.2), nil without nvm or a default.
    func nvmDefaultVersion() async -> String? {
        guard Self.isNvmInstalled, let out = try? await ProcessRunner.output(URL(fileURLWithPath: "/bin/bash"), ["-c", Self.nvmScript("nvm version default")], environment: Self.nvmEnvironment()) else { return nil }
        return out.hasPrefix("v") ? out : nil
    }

    /// Every bin directory with a node, best first: the Settings choice, nvm's
    /// default, the app's own install, /usr/local (.pkg), Homebrew, the other
    /// nvm versions (newest first), /usr/bin.
    private func candidateBinDirectories() async -> [(URL, NodeSource)] {
        let fm = FileManager.default
        let nvmVersions = Self.nvmDirectory.appendingPathComponent("versions/node")
        let defaultVersion = await nvmDefaultVersion()
        var dirs: [(URL, NodeSource)] = []
        func source(of bin: URL) -> NodeSource {
            if bin == Self.managedNodeDirectory.appendingPathComponent("bin") { return .appLocal }
            if bin.path.hasPrefix(nvmVersions.path) { return .nvm(isDefault: bin.deletingLastPathComponent().lastPathComponent == defaultVersion) }
            if bin.path == "/usr/local/bin" { return .system }
            if bin.path == "/opt/homebrew/bin" { return .homebrew }
            return .other
        }
        if let preferred = Self.preferredBinDirectory { dirs.append((preferred, source(of: preferred))) }
        if let defaultVersion { dirs.append((nvmVersions.appendingPathComponent("\(defaultVersion)/bin"), .nvm(isDefault: true))) }
        dirs.append((Self.managedNodeDirectory.appendingPathComponent("bin"), .appLocal))
        dirs.append((URL(fileURLWithPath: "/usr/local/bin"), .system))
        dirs.append((URL(fileURLWithPath: "/opt/homebrew/bin"), .homebrew))
        if let entries = try? fm.contentsOfDirectory(at: nvmVersions, includingPropertiesForKeys: nil) {
            let sorted = entries.sorted { (SemVer($0.lastPathComponent) ?? SemVer(0)) > (SemVer($1.lastPathComponent) ?? SemVer(0)) }
            dirs += sorted.map { bin in let b = bin.appendingPathComponent("bin"); return (b, source(of: b)) }
        }
        dirs.append((URL(fileURLWithPath: "/usr/bin"), .other))
        var seen = Set<String>()
        return dirs.filter { dir in
            guard fm.isExecutableFile(atPath: dir.0.appendingPathComponent("node").path) else { return false }
            return seen.insert(dir.0.standardizedFileURL.path).inserted
        }
    }

    func probe(_ bin: URL, source: NodeSource) async -> NodeRuntime? {
        let env = Self.environment(for: bin)
        guard let nodeOut = try? await ProcessRunner.output(bin.appendingPathComponent("node"), ["-v"], environment: env),
              let node = SemVer(nodeOut) else { return nil }
        let npmURL = bin.appendingPathComponent("npm")
        var npm: SemVer?
        if FileManager.default.isExecutableFile(atPath: npmURL.path), let out = try? await ProcessRunner.output(npmURL, ["-v"], environment: env) {
            npm = SemVer(out)
        }
        return NodeRuntime(binDirectory: bin, nodeVersion: node, npmVersion: npm, source: source)
    }

    static func classify(_ r: NodeRuntime) -> RuntimeCheck {
        guard let npm = r.npmVersion, npm >= minimumNpm, r.nodeVersion >= minimumNode else { return .tooOld(r) }
        if r.nodeVersion >= recommendedNode && npm >= recommendedNpm { return .ok(r) }
        return .outdated(r)
    }

    /// Every Node.js found, in preference order (Settings list).
    func detectAll() async -> [NodeRuntime] {
        var found: [NodeRuntime] = []
        for (dir, source) in await candidateBinDirectories() {
            if let r = await probe(dir, source: source) { found.append(r) }
        }
        return found
    }

    /// Picks the first candidate that meets the recommendation, else the
    /// first usable one (warning), else reports the first too-old one.
    func check() async -> RuntimeCheck {
        let found = await detectAll()
        if let simulated = Self.simulatedResult {
            let base = found.first
            let fake = { (node: SemVer, npm: SemVer) in base.map { NodeRuntime(binDirectory: $0.binDirectory, nodeVersion: node, npmVersion: npm, source: $0.source) } }
            switch simulated {
            case "old": if let r = fake(SemVer(18, 20, 8), SemVer(10, 8, 2)) { return .tooOld(r) }
            case "outdated":
                if let r = fake(SemVer(20, 19, 0), SemVer(10, 8, 2)) {
                    // "Continue" runs on the real node behind the fake version.
                    selected = base
                    return .outdated(r)
                }
            default: break
            }
            return .missing
        }
        let results = found.map(Self.classify)
        let best = results.first { if case .ok = $0 { true } else { false } }
            ?? results.first { if case .outdated = $0 { true } else { false } }
            ?? results.first
            ?? .missing
        if case .ok(let r) = best { selected = r }
        if case .outdated(let r) = best { selected = r }
        return best
    }

    /// PATH for anything run with `bin`'s node (npm's `#!/usr/bin/env node`
    /// needs it) plus Homebrew / /usr/local for the `aws` CLI. A GUI app
    /// inherits a bare system PATH and no shell profile.
    static func environment(for bin: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = ([bin.path, "/opt/homebrew/bin", "/usr/local/bin"] + [inherited]).joined(separator: ":")
        env["npm_config_update_notifier"] = "false"
        return env
    }

    // MARK: - Node install (nodejs.org)

    struct NodeRelease {
        let version: String
        let tarball: String
        var url: URL { URL(string: "https://nodejs.org/dist/\(version)/\(tarball)")! }
    }

    static var platformArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    /// Latest LTS release of `installMajor` from nodejs.org's release index.
    func latestRelease() async throws -> NodeRelease {
        struct Entry: Decodable {
            let version: String
            let lts: LTS
            enum LTS: Decodable {
                case name(String), no
                init(from decoder: Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    self = (try? c.decode(String.self)).map(LTS.name) ?? .no
                }
            }
        }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://nodejs.org/dist/index.json")!)
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        guard let entry = entries.first(where: { e in
            if case .name = e.lts, SemVer(e.version)?.major == Self.installMajor { return true }
            return false
        }) else {
            throw RuntimeError("No Node.js \(Self.installMajor) LTS release found on nodejs.org")
        }
        return NodeRelease(version: entry.version, tarball: "node-\(entry.version)-darwin-\(Self.platformArch).tar.gz")
    }

    /// The terminal equivalent of `installNode`, for the error screen.
    func manualNodeInstallCommand(_ release: NodeRelease?) -> String {
        let version = release?.version ?? "v\(Self.installMajor).x.y"
        let tarball = release?.tarball ?? "node-\(version)-darwin-\(Self.platformArch).tar.gz"
        let dir = Self.managedNodeDirectory.path
        return """
        cd /tmp && curl -fLO https://nodejs.org/dist/\(version)/\(tarball) \\
          && curl -fsSL https://nodejs.org/dist/\(version)/SHASUMS256.txt | grep " \(tarball)$" | shasum -a 256 -c - \\
          && mkdir -p "\(dir)" && tar -xzf \(tarball) -C "\(dir)" --strip-components 1 \\
          && "\(dir)/bin/node" -v
        """
    }

    /// Downloads the release, checks it against SHASUMS256.txt, unpacks it
    /// into `managedNodeDirectory` (replacing an older app install) and
    /// returns the new runtime. Only the app's own folder is touched.
    func installNode(_ release: NodeRelease, log: TaskLog) async throws -> NodeRuntime {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.appSupportDirectory, withIntermediateDirectories: true)

        log.begin("checksum", "Fetch checksums")
        let sumsURL = URL(string: "https://nodejs.org/dist/\(release.version)/SHASUMS256.txt")!
        log.append("$ curl \(sumsURL.absoluteString)\n")
        let (sumsData, _) = try await URLSession.shared.data(from: sumsURL)
        let sums = String(decoding: sumsData, as: UTF8.self)
        guard let expected = sums.split(separator: "\n").first(where: { $0.hasSuffix(" \(release.tarball)") })?.split(separator: " ").first.map(String.init) else {
            throw RuntimeError("\(release.tarball) is not listed in SHASUMS256.txt")
        }
        log.append("expected sha256 \(expected)\n")
        log.finish()

        log.begin("download", "Download \(release.tarball)")
        log.append("$ curl -O \(release.url.absoluteString)\n")
        var lastDecile = -1
        let file = try await Downloader.download(release.url) { received, total in
            if total > 0 {
                let decile = Int(Double(received) / Double(total) * 10)
                if decile > lastDecile {
                    lastDecile = decile
                    log.append(String(format: "  %3d%%  %@ / %@\n", decile * 10, ByteCountFormatter.string(fromByteCount: received, countStyle: .file), ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))
                }
            }
            log.setProgress(total > 0 ? Double(received) / Double(total) : nil, detail: ByteCountFormatter.string(fromByteCount: received, countStyle: .file) + (total > 0 ? " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : ""))
        }
        defer { try? fm.removeItem(at: file) }
        log.append("saved to \(file.path)\n")
        log.finish()

        log.begin("verify", "Verify SHA-256")
        let actual = try Self.sha256(of: file)
        log.append("$ shasum -a 256 \(release.tarball)\n\(actual)  \(release.tarball)\n")
        guard actual == expected else { throw RuntimeError("Checksum mismatch: expected \(expected), got \(actual)") }
        log.append("OK\n")
        log.finish()

        log.begin("extract", "Extract into Application Support")
        let target = Self.managedNodeDirectory
        // Unpack next to the target so the final move is a rename on the same volume.
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent("\(target.lastPathComponent)-staging")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        let args = ["-xzvf", file.path, "-C", staging.path, "--strip-components", "1"]
        log.append("$ tar \(args.joined(separator: " "))\n")
        let code = try await ProcessRunner.run(tar, args) { log.append($0) }
        guard code == 0 else { throw RuntimeError("tar exited with code \(code)") }
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        log.append("$ mv \"\(staging.path)\" \"\(target.path)\"\n")
        try fm.moveItem(at: staging, to: target)
        log.append("installed to \(target.path)\n")
        log.finish()

        log.begin("check", "Check node and npm")
        let bin = target.appendingPathComponent("bin")
        log.append("$ \(bin.path)/node -v\n")
        guard let runtime = await probe(bin, source: .appLocal) else { throw RuntimeError("The installed node does not run") }
        log.append("v\(runtime.nodeVersion)\n$ \(bin.path)/npm -v\n\(runtime.npmVersion.map(\.description) ?? "npm not found")\n")
        log.finish()
        selected = runtime
        return runtime
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Core packages (packages/api dependencies)

    /// `packages/api` `dependencies` that aren't on disk (repo or api node_modules).
    func missingCorePackages(apiDirectory: URL) -> [String] {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: apiDirectory.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deps = json["dependencies"] as? [String: Any] else { return [] }
        let roots = [apiDirectory.appendingPathComponent("node_modules"), apiDirectory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("node_modules")]
        return deps.keys.sorted().filter { name in
            !roots.contains { fm.fileExists(atPath: $0.appendingPathComponent(name).appendingPathComponent("package.json").path) }
        }
    }

    /// Runs from the repo root (npm workspace); only runtime dependencies.
    func coreInstallCommand(apiDirectory: URL) -> (cwd: URL, args: [String], display: String) {
        let root = apiDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let args = ["install", "--omit=dev", "--no-audit", "--no-fund", "--loglevel=http"]
        return (root, args, "cd \"\(root.path)\" && npm install --omit=dev --no-audit --no-fund")
    }

    func installCorePackages(apiDirectory: URL, log: TaskLog) async throws {
        guard let runtime = selected else { throw RuntimeError("Node.js is not selected") }
        let cmd = coreInstallCommand(apiDirectory: apiDirectory)
        log.begin("core", "npm install (core packages)")
        log.append("$ \(cmd.display)\n")
        let code = try await ProcessRunner.run(runtime.binDirectory.appendingPathComponent("npm"), cmd.args, cwd: cmd.cwd, environment: Self.environment(for: runtime.binDirectory)) { log.append($0) }
        guard code == 0 else { throw RuntimeError(TaskLog.npmErrorSummary(log.currentOutput) ?? "npm exited with code \(code)") }
        let still = missingCorePackages(apiDirectory: apiDirectory)
        guard still.isEmpty else { throw RuntimeError("Still missing after npm install: \(still.joined(separator: ", "))") }
        log.finish()
    }
}

struct RuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Runs a process and streams its stdout + stderr.
enum ProcessRunner {
    static func run(_ executable: URL, _ arguments: [String], cwd: URL? = nil, environment: [String: String]? = nil, onOutput: @escaping @MainActor (String) -> Void) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in onOutput(text) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty {
                    let text = String(decoding: rest, as: UTF8.self)
                    Task { @MainActor in onOutput(text) }
                }
                continuation.resume(returning: p.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Stdout of a short command (version probes).
    static func output(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            process.terminationHandler = { p in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                if p.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    continuation.resume(throwing: RuntimeError("\(executable.lastPathComponent) exited with \(p.terminationStatus)"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// URLSession download with byte progress.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: @MainActor (Int64, Int64) -> Void

    private init(onProgress: @escaping @MainActor (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    static func download(_ url: URL, onProgress: @escaping @MainActor (Int64, Int64) -> Void) async throws -> URL {
        let delegate = Downloader(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let cb = onProgress
        Task { @MainActor in cb(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns - move it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("awsvisualizer-\(UUID().uuidString).tar.gz")
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            continuation?.resume(throwing: RuntimeError("Download failed: HTTP \(http.statusCode)"))
        } else {
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                continuation?.resume(returning: kept)
            } catch {
                continuation?.resume(throwing: error)
            }
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
