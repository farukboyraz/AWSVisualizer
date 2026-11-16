import Foundation
import Security

/// The per-launch secret that proves a request comes from this app. The
/// sidecar only listens on 127.0.0.1 and rejects any request without this
/// header (see packages/api/src/presentation/middleware/sidecar-token.ts),
/// so neither a web page nor another program can use the user's AWS
/// session through it.
enum SidecarAuth {
    static let header = "X-AWSVisualizer-Token"
    static let token: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()
    static let baseURL = "http://127.0.0.1:9000"
}

/// Launches and health-checks the local Node/Express API sidecar
/// (`packages/api`) that every AWS/SSO call goes through. The packaged app
/// used to require this to be started by hand in a terminal before login
/// would work at all; this makes the app self-sufficient on first launch.
@MainActor
final class SidecarManager {
    static let shared = SidecarManager()

    private var launchedProcess: Process?
    private let healthCheckURL = URL(string: "\(SidecarAuth.baseURL)/api/aws-status")!

    /// Why the last `ensureRunning` / `restart` failed, in the app's
    /// language, when there is something more specific than "Node.js".
    private(set) var lastFailure: String?

    private init() {}

    /// Ensures the sidecar is reachable, spawning it if it isn't already
    /// running. Returns once it responds, or after a timeout if it never
    /// comes up. `statusUpdate` is called with a user-facing message while
    /// the sidecar is being started (not called if it was already running).
    func ensureRunning(statusUpdate: (String) -> Void) async -> Bool {
        lastFailure = nil
        switch await probe() {
        case .ours:
            return true
        case .foreign:
            // A sidecar from an earlier launch (other token) or an old
            // build that still listens on every interface: replace it.
            NSLog("AWSVisualizer: port 9000 is held by a sidecar that doesn't accept this launch's token - restarting it")
            await stopListener()
        case .down:
            break
        }

        // Another program on :9000 (MinIO, Portainer, php-fpm…) is never
        // stopped - the user decides what to do with it.
        let others = await portHolders().filter { !$0.isOurs }
        if !others.isEmpty {
            let names = others.map { "\($0.name) (pid \($0.pid))" }.joined(separator: ", ")
            NSLog("AWSVisualizer: port 9000 is used by another program: \(names)")
            lastFailure = AppLanguage.current == .tr
                ? "9000 portunu başka bir program kullanıyor: \(names). Yerel API bu portta çalışıyor; o programı kapatıp tekrar dene."
                : "Port 9000 is used by another program: \(names). The local API runs on this port - quit that program, then retry."
            return false
        }

        guard let apiDirectory = Self.resolveApiDirectory() else {
            NSLog("AWSVisualizer: could not locate packages/api to start the sidecar")
            return false
        }

        statusUpdate("Starting local API service...")
        spawn(in: apiDirectory)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if await probe() == .ours {
                return true
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    /// Stops the sidecar (ours, or whatever listens on :9000) and starts it
    /// again on `RuntimeManager.shared.selected` - after picking another
    /// Node.js in Settings.
    func restart(statusUpdate: (String) -> Void) async -> Bool {
        statusUpdate("Stopping the local API…")
        await stopListener()
        return await ensureRunning(statusUpdate: statusUpdate)
    }

    /// Ends our process and any earlier copy of the sidecar on :9000 (npx →
    /// tsx → node: the listener itself has to go), then waits for the port.
    /// A listener that isn't the sidecar is left alone.
    private func stopListener() async {
        if let process = launchedProcess {
            process.terminate()
            launchedProcess = nil
        }
        let ours = await portHolders().filter(\.isOurs)
        for holder in ours { kill(holder.pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(8)
        while await !portHolders().filter(\.isOurs).isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private struct PortHolder {
        let pid: Int32
        let name: String
        /// Started from a `packages/api` folder - a sidecar of this app
        /// (this checkout or another one).
        let isOurs: Bool
    }

    /// Processes listening on :9000. `lsof -F pc` prints `p<pid>` and
    /// `c<command>` lines; the working directory tells the sidecar apart.
    private func portHolders() async -> [PortHolder] {
        let lsof = URL(fileURLWithPath: "/usr/sbin/lsof")
        guard let listing = try? await ProcessRunner.output(lsof, ["-nP", "-iTCP:9000", "-sTCP:LISTEN", "-Fpc"]) else { return [] }
        var holders: [PortHolder] = []
        var pid: Int32?
        for line in listing.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("c"), let current = pid {
                let cwd = (try? await ProcessRunner.output(lsof, ["-a", "-p", String(current), "-d", "cwd", "-Fn"])) ?? ""
                let isOurs = cwd.split(separator: "\n").contains { $0.hasPrefix("n") && $0.hasSuffix("/packages/api") }
                holders.append(PortHolder(pid: current, name: String(line.dropFirst()), isOurs: isOurs))
                pid = nil
            }
        }
        return holders
    }

    private enum Probe { case ours, foreign, down }

    /// `.ours` = our API (`X-AWSVisualizer-API` header) accepting this
    /// launch's token; `.foreign` = a sidecar of an earlier launch (403
    /// SidecarAuth), an old one without the header or only on IPv6 / every
    /// interface, or another program on :9000 - `ensureRunning` tells these
    /// apart by working directory and stops only sidecars.
    private func probe() async -> Probe {
        var request = URLRequest(url: healthCheckURL)
        request.timeoutInterval = 2
        request.setValue(SidecarAuth.token, forHTTPHeaderField: SidecarAuth.header)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .down }
            // Only our API sends this header; any other program answering on
            // :9000 (or a sidecar from before the header) is not ours.
            guard http.value(forHTTPHeaderField: "X-AWSVisualizer-API") != nil else { return .foreign }
            if http.statusCode == 403, String(data: data, encoding: .utf8)?.contains("\"SidecarAuth\"") == true {
                return .foreign
            }
            return .ours
        } catch {
            // 127.0.0.1 refused, but an old build may still hold *:9000 on IPv6.
            return await legacyListenerExists() ? .foreign : .down
        }
    }

    private func legacyListenerExists() async -> Bool {
        guard let pids = try? await ProcessRunner.output(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-nP", "-iTCP:9000", "-sTCP:LISTEN", "-t"]) else { return false }
        return !pids.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func spawn(in directory: URL) {
        guard launchedProcess == nil else { return }

        let process = Process()

        // The node / npm the pre-login check picked (RuntimeManager) -
        // a GUI-launched app's shell doesn't source ~/.zshrc, so PATH is
        // never trusted to find the right node. Plain `tsx`, not
        // `tsx watch`: restarts on source changes used to race for the
        // port (EADDRINUSE) and leave a dead sidecar behind.
        if let runtime = RuntimeManager.shared.selected {
            process.executableURL = runtime.binDirectory.appendingPathComponent("npx")
            process.arguments = ["tsx", "src/index.ts"]
            process.environment = RuntimeManager.environment(for: runtime.binDirectory).merging(["AWSVIS_TOKEN": SidecarAuth.token]) { $1 }
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "npx tsx src/index.ts"]
            process.environment = ProcessInfo.processInfo.environment.merging(["AWSVIS_TOKEN": SidecarAuth.token]) { $1 }
        }
        process.currentDirectoryURL = directory

        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("awsvisualizer-api.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
            launchedProcess = process
        } catch {
            NSLog("AWSVisualizer: failed to launch API sidecar: \(error)")
        }
    }

    /// The sidecar lives at `packages/api` of the repo the app was built
    /// from. The app is not a relocatable bundle - it sits at
    /// `<repo>/dist/mac/*.app`, or runs from `.build/` with `swift run` - so
    /// the repo is found by walking up from the app and from the executable.
    /// `AWSVIS_API_DIR` points somewhere else explicitly.
    static func resolveApiDirectory() -> URL? {
        let fm = FileManager.default
        let isApi = { (url: URL) in fm.fileExists(atPath: url.appendingPathComponent("package.json").path) && fm.fileExists(atPath: url.appendingPathComponent("src/index.ts").path) }
        if let explicit = ProcessInfo.processInfo.environment["AWSVIS_API_DIR"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if isApi(url) { return url }
        }
        var starts = [Bundle.main.bundleURL]
        if let executable = Bundle.main.executableURL { starts.append(executable) }
        for start in starts {
            var dir = start.deletingLastPathComponent()
            for _ in 0..<8 {
                let candidate = dir.appendingPathComponent("packages/api")
                if isApi(candidate) { return candidate }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }
}
