import Foundation

/// System-wide installs that every terminal and app can use: the official
/// nodejs.org .pkg (/usr/local) and nvm (~/.nvm, loaded from the shell
/// profile). The app-only install lives in RuntimeManager.installNode.
extension RuntimeManager {
    /// One nodejs.org release (Settings' version list).
    struct NodeReleaseInfo: Identifiable, Hashable {
        let version: String
        /// LTS codename ("Jod"), nil for Current releases.
        let lts: String?
        let date: String
        var id: String { version }
        var major: Int { SemVer(version)?.major ?? 0 }
    }

    /// Newest release of every major ≥ the minimum, newest first.
    func availableReleases() async throws -> [NodeReleaseInfo] {
        struct Entry: Decodable {
            let version: String
            let date: String
            let lts: LTSField
            struct LTSField: Decodable {
                let name: String?
                init(from decoder: Decoder) throws {
                    name = try? decoder.singleValueContainer().decode(String.self)
                }
            }
        }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://nodejs.org/dist/index.json")!)
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        var seen = Set<Int>()
        return entries.compactMap { e -> NodeReleaseInfo? in
            guard let v = SemVer(e.version), v >= Self.minimumNode, !seen.contains(v.major) else { return nil }
            seen.insert(v.major)
            return NodeReleaseInfo(version: e.version, lts: e.lts.name, date: e.date)
        }
    }

    // MARK: - Official .pkg (system-wide)

    func manualPkgInstallCommand(_ release: NodeRelease?) -> String {
        let version = release?.version ?? "v\(Self.installMajor).x.y"
        let pkg = "node-\(version).pkg"
        return """
        cd /tmp && curl -fLO https://nodejs.org/dist/\(version)/\(pkg) \\
          && curl -fsSL https://nodejs.org/dist/\(version)/SHASUMS256.txt | grep " \(pkg)$" | shasum -a 256 -c - \\
          && sudo installer -pkg \(pkg) -target / \\
          && /usr/local/bin/node -v && /usr/local/bin/npm -v
        """
    }

    /// Downloads and verifies the official installer, then opens it in the
    /// macOS Installer (the user approves it with their password there) and
    /// waits for it to close. Node lands in /usr/local/bin for every app.
    func installSystemNode(_ release: NodeRelease, log: TaskLog) async throws -> NodeRuntime {
        let fm = FileManager.default
        let pkg = "node-\(release.version).pkg"

        log.begin("checksum", "Fetch checksums")
        let sumsURL = URL(string: "https://nodejs.org/dist/\(release.version)/SHASUMS256.txt")!
        log.append("$ curl \(sumsURL.absoluteString)\n")
        let (sumsData, _) = try await URLSession.shared.data(from: sumsURL)
        guard let expected = String(decoding: sumsData, as: UTF8.self).split(separator: "\n").first(where: { $0.hasSuffix(" \(pkg)") })?.split(separator: " ").first.map(String.init) else {
            throw RuntimeError("\(pkg) is not listed in SHASUMS256.txt")
        }
        log.append("expected sha256 \(expected)\n")
        log.finish()

        log.begin("download", "Download \(pkg)")
        let url = URL(string: "https://nodejs.org/dist/\(release.version)/\(pkg)")!
        log.append("$ curl -O \(url.absoluteString)\n")
        var lastDecile = -1
        let downloaded = try await Downloader.download(url) { received, total in
            if total > 0 {
                let decile = Int(Double(received) / Double(total) * 10)
                if decile > lastDecile {
                    lastDecile = decile
                    log.append(String(format: "  %3d%%  %@ / %@\n", decile * 10, ByteCountFormatter.string(fromByteCount: received, countStyle: .file), ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))
                }
            }
            log.setProgress(total > 0 ? Double(received) / Double(total) : nil, detail: nil)
        }
        // The Installer wants a .pkg extension.
        let file = fm.temporaryDirectory.appendingPathComponent(pkg)
        try? fm.removeItem(at: file)
        try fm.moveItem(at: downloaded, to: file)
        defer { try? fm.removeItem(at: file) }
        log.finish()

        log.begin("verify", "Verify SHA-256")
        let actual = try Self.sha256(of: file)
        log.append("$ shasum -a 256 \(pkg)\n\(actual)  \(pkg)\n")
        guard actual == expected else { throw RuntimeError("Checksum mismatch: expected \(expected), got \(actual)") }
        log.append("OK\n")
        log.finish()

        log.begin("installer", "macOS Installer")
        log.append("$ open -W \(file.path)\n")
        log.append("The macOS Installer is open - follow its steps and enter your password there. Waiting for it to close…\n")
        let code = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/open"), ["-W", file.path]) { log.append($0) }
        guard code == 0 else { throw RuntimeError("The Installer could not be opened (exit \(code))") }
        log.append("Installer closed.\n")
        log.finish()

        log.begin("check", "Check node and npm")
        let bin = URL(fileURLWithPath: "/usr/local/bin")
        log.append("$ /usr/local/bin/node -v\n")
        guard let runtime = await probe(bin, source: .system), runtime.nodeVersion.description == SemVer(release.version)?.description else {
            throw RuntimeError("Node.js \(release.version) is not in /usr/local/bin - the Installer was closed before it finished, or it failed.")
        }
        log.append("v\(runtime.nodeVersion)\n$ /usr/local/bin/npm -v\n\(runtime.npmVersion.map(\.description) ?? "npm not found")\n")
        log.finish()
        use(runtime)
        return runtime
    }

    // MARK: - nvm

    /// `script` with nvm loaded (nvm is a shell function, not a binary).
    static func nvmScript(_ script: String) -> String {
        "export NVM_DIR=\"\(nvmDirectory.path)\"; . \"$NVM_DIR/nvm.sh\" --no-use; \(script)"
    }

    /// Plain system PATH (nvm prepends its own), plus Homebrew for git.
    static func nvmEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["NVM_DIR"] = nvmDirectory.path
        env["npm_config_update_notifier"] = "false"
        // nvm prints colors when it thinks it's a terminal.
        env["NO_COLOR"] = "1"
        env.removeValue(forKey: "NODE_PATH")
        return env
    }

    /// Runs `nvm <args>` (shown as a terminal command), streaming its output.
    func runNvm(_ command: String, log: TaskLog) async throws {
        log.append("$ nvm \(command)\n")
        let code = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/bash"), ["-c", Self.nvmScript("nvm \(command)")], environment: Self.nvmEnvironment()) { log.append($0) }
        guard code == 0 else { throw RuntimeError("nvm \(command) exited with code \(code)") }
    }

    func nvmVersion() async -> String? {
        guard Self.isNvmInstalled else { return nil }
        return try? await ProcessRunner.output(URL(fileURLWithPath: "/bin/bash"), ["-c", Self.nvmScript("nvm --version")], environment: Self.nvmEnvironment())
    }

    /// Versions under ~/.nvm/versions/node, newest first.
    func nvmInstalledVersions() -> [String] {
        let dir = Self.nvmDirectory.appendingPathComponent("versions/node")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries.filter { $0.hasPrefix("v") }.sorted { (SemVer($0) ?? SemVer(0)) > (SemVer($1) ?? SemVer(0)) }
    }

    func latestNvmTag() async throws -> String {
        struct Release: Decodable { let tag_name: String }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/nvm-sh/nvm/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Release.self, from: data).tag_name
    }

    func manualNvmInstallCommand(tag: String?, node: String? = nil) -> String {
        let t = tag ?? "v0.41.0"
        let node = node ?? "\(Self.installMajor)"
        return """
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/\(t)/install.sh | bash \\
          && export NVM_DIR="$HOME/.nvm" && . "$NVM_DIR/nvm.sh" \\
          && nvm install \(node) && nvm alias default \(node)
        """
    }

    /// The official nvm install script (latest release). It clones nvm into
    /// ~/.nvm and adds the loader lines to the shell profile (~/.zshrc …), so
    /// every new terminal has nvm. Installing again updates nvm.
    func installNvm(log: TaskLog) async throws -> String {
        log.begin("nvm-release", "Find the latest nvm release")
        log.append("$ curl https://api.github.com/repos/nvm-sh/nvm/releases/latest\n")
        let tag = try await latestNvmTag()
        log.append("\(tag)\n")
        log.finish()

        log.begin("nvm-install", "Install nvm \(tag)")
        let scriptURL = URL(string: "https://raw.githubusercontent.com/nvm-sh/nvm/\(tag)/install.sh")!
        log.append("$ curl -o- \(scriptURL.absoluteString) | bash\n")
        let (data, response) = try await URLSession.shared.data(from: scriptURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RuntimeError("Could not download the nvm install script") }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("nvm-install-\(tag).sh")
        try data.write(to: script)
        defer { try? FileManager.default.removeItem(at: script) }
        var env = Self.nvmEnvironment()
        // The script picks the profile from SHELL; a GUI app may not have it.
        if env["SHELL"]?.isEmpty ?? true { env["SHELL"] = "/bin/zsh" }
        env.removeValue(forKey: "NVM_DIR")
        let code = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/bash"), [script.path], environment: env) { log.append($0) }
        guard code == 0, Self.isNvmInstalled else { throw RuntimeError("The nvm install script failed (exit \(code))") }
        log.finish()
        return tag
    }

    /// `nvm install <version>`, optionally `nvm alias default <version>`; returns the runtime.
    func installNodeWithNvm(_ version: String, setDefault: Bool, log: TaskLog) async throws -> NodeRuntime {
        log.begin("nvm-node-\(version)", "nvm install \(version)")
        try await runNvm("install \(version)", log: log)
        log.finish()
        if setDefault {
            log.begin("nvm-default-\(version)", "nvm alias default \(version)")
            try await runNvm("alias default \(version)", log: log)
            log.finish()
        }
        log.begin("nvm-check-\(version)", "Check node and npm")
        let resolved = (try? await ProcessRunner.output(URL(fileURLWithPath: "/bin/bash"), ["-c", Self.nvmScript("nvm version \(version)")], environment: Self.nvmEnvironment())) ?? version
        let bin = Self.nvmDirectory.appendingPathComponent("versions/node/\(resolved)/bin")
        log.append("$ \(bin.path)/node -v\n")
        guard let runtime = await probe(bin, source: .nvm(isDefault: setDefault)) else { throw RuntimeError("Node.js \(version) is not under \(bin.path)") }
        log.append("v\(runtime.nodeVersion)\n$ \(bin.path)/npm -v\n\(runtime.npmVersion.map(\.description) ?? "npm not found")\n")
        log.finish()
        return runtime
    }

    func setNvmDefault(_ version: String, log: TaskLog) async throws {
        log.begin("nvm-default-\(version)", "nvm alias default \(version)")
        try await runNvm("alias default \(version)", log: log)
        log.finish()
    }

    func uninstallNvmVersion(_ version: String, log: TaskLog) async throws {
        log.begin("nvm-uninstall-\(version)", "nvm uninstall \(version)")
        try await runNvm("uninstall \(version)", log: log)
        log.finish()
    }

    /// Removes the app-only Node (other installs are not touched).
    func removeAppLocalNode() throws {
        let dir = Self.managedNodeDirectory
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }
}
