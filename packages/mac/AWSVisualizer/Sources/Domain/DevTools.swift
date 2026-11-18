import Foundation

struct CustomDevTool: Codable, Equatable, Hashable, Identifiable {
    let id: String
    var name: String
    var command: String
    var icon: String
}

/// `~/.awsvisualizer`'s `devTools`: enabled tool ids in panel order plus
/// user-defined tools.
struct DevToolsConfig: Codable, Equatable {
    var enabled: [String]
    var custom: [CustomDevTool]

    static let empty = DevToolsConfig(enabled: [], custom: [])
}

/// A tool the right-edge panel can open in a terminal tab.
struct DevTool: Identifiable, Hashable {
    enum Category: String, CaseIterable {
        case shell = "Shell"
        case ai = "AI assistants"
        case utility = "Utilities"
        case custom = "Custom"
    }

    let id: String
    let name: String
    /// Command line run in a login shell; nil = the shell itself.
    let command: String?
    let icon: String
    let category: Category
    let summary: String
    var installURL: URL?
    /// Other commands that start the same tool, tried in order when the
    /// main command's binary isn't installed (e.g. Amazon Q's `q`, which
    /// the Kiro CLI replaced).
    var alternatives: [String] = []

    /// First word of the command - the program that has to be installed.
    var binary: String? {
        command.flatMap(DevTool.program)
    }

    /// The main command first, then the alternatives.
    var candidateCommands: [String] {
        (command.map { [$0] } ?? []) + alternatives
    }

    /// Every program that can start this tool.
    var binaries: [String] {
        candidateCommands.compactMap(DevTool.program)
    }

    static func program(of command: String) -> String? {
        command.split(separator: " ").first.map(String.init)
    }

    var isCustom: Bool { category == .custom }
}

enum DevToolCatalog {
    static let builtIn: [DevTool] = [
        DevTool(id: "terminal", name: "Terminal", command: nil, icon: "terminal", category: .shell,
                summary: "Your login shell ($SHELL -l)."),

        DevTool(id: "kiro-cli", name: "Kiro CLI", command: "kiro-cli chat", icon: "sparkles", category: .ai,
                summary: "AWS Kiro agent in the terminal.", installURL: URL(string: "https://kiro.dev/downloads/")),
        DevTool(id: "amazon-q", name: "Amazon Q Developer", command: "q chat", icon: "questionmark.bubble", category: .ai,
                summary: "Amazon Q Developer CLI chat. It is now the Kiro CLI, so kiro-cli is used when q isn't installed.",
                installURL: URL(string: "https://kiro.dev/downloads/"), alternatives: ["kiro-cli chat"]),
        DevTool(id: "claude-code", name: "Claude Code", command: "claude", icon: "asterisk", category: .ai,
                summary: "Anthropic's coding agent.", installURL: URL(string: "https://claude.com/product/claude-code")),
        DevTool(id: "gemini-cli", name: "Gemini CLI", command: "gemini", icon: "diamond", category: .ai,
                summary: "Google's Gemini agent.", installURL: URL(string: "https://github.com/google-gemini/gemini-cli")),
        DevTool(id: "codex", name: "Codex CLI", command: "codex", icon: "circle.hexagongrid", category: .ai,
                summary: "OpenAI's coding agent.", installURL: URL(string: "https://github.com/openai/codex")),
        DevTool(id: "copilot", name: "GitHub Copilot CLI", command: "copilot", icon: "person.2.wave.2", category: .ai,
                summary: "GitHub Copilot in the terminal.", installURL: URL(string: "https://github.com/github/copilot-cli")),
        DevTool(id: "cursor-agent", name: "Cursor CLI", command: "cursor-agent", icon: "cursorarrow.rays", category: .ai,
                summary: "Cursor's agent in the terminal.", installURL: URL(string: "https://cursor.com/cli")),
        DevTool(id: "aider", name: "Aider", command: "aider", icon: "wand.and.stars", category: .ai,
                summary: "AI pair programming with your git repo.", installURL: URL(string: "https://aider.chat")),
        DevTool(id: "opencode", name: "OpenCode", command: "opencode", icon: "curlybraces", category: .ai,
                summary: "Open-source coding agent.", installURL: URL(string: "https://opencode.ai")),
        DevTool(id: "ollama", name: "Ollama", command: "ollama run llama3.2", icon: "cube", category: .ai,
                summary: "Local models (edit the model in a custom tool if needed).", installURL: URL(string: "https://ollama.com")),

        DevTool(id: "lazygit", name: "lazygit", command: "lazygit", icon: "arrow.triangle.branch", category: .utility,
                summary: "Git UI in the terminal.", installURL: URL(string: "https://github.com/jesseduffield/lazygit")),
        DevTool(id: "k9s", name: "k9s", command: "k9s", icon: "helm", category: .utility,
                summary: "Kubernetes (EKS) cluster UI.", installURL: URL(string: "https://k9scli.io")),
        DevTool(id: "htop", name: "htop", command: "htop", icon: "gauge.with.dots.needle.bottom.50percent", category: .utility,
                summary: "Process monitor.", installURL: URL(string: "https://htop.dev")),
        DevTool(id: "python", name: "Python", command: "python3", icon: "chevron.left.forwardslash.chevron.right", category: .utility,
                summary: "Python REPL."),
        DevTool(id: "node", name: "Node.js", command: "node", icon: "hexagon", category: .utility,
                summary: "Node.js REPL.", installURL: URL(string: "https://nodejs.org")),
    ]

    /// Icons offered for custom tools.
    static let customIcons = ["terminal", "sparkles", "brain", "wand.and.stars", "bolt", "cpu", "server.rack", "hammer", "gearshape", "bubble.left.and.bubble.right"]

    static func all(custom: [CustomDevTool]) -> [DevTool] {
        builtIn + custom.map {
            DevTool(id: $0.id, name: $0.name, command: $0.command, icon: $0.icon, category: .custom, summary: $0.command)
        }
    }

    /// Enabled tools in their configured order (unknown ids dropped).
    static func enabled(in config: DevToolsConfig) -> [DevTool] {
        let tools = all(custom: config.custom)
        return config.enabled.compactMap { id in tools.first { $0.id == id } }
    }
}

/// Finds which tools are installed and how to start them.
///
/// A GUI app doesn't inherit the shell's PATH, and a login shell alone
/// misses what `~/.zshrc` / `~/.bashrc` add (nvm, npm-global, Claude's
/// `~/.claude/local`, ...). So the search uses the PATH of an interactive
/// login shell (the user's real shell, from the user account - an app
/// opened from Finder often has no `$SHELL`), then the usual install
/// folders. A tool found outside the login shell's PATH still starts: the
/// panel runs it by full path with its folder put first on PATH.
enum DevToolLocator {
    /// The user's login shell (account database), else `$SHELL`, else zsh.
    static var shell: String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let path = String(cString: raw)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Program name -> full path, for the given names that are installed.
    /// `fresh` skips the folder cache (the "Check again" buttons).
    static func locate(_ binaries: [String], fresh: Bool = false) async -> [String: String] {
        let names = Array(Set(binaries.filter(isSafeName)))
        guard !names.isEmpty else { return [:] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let dirs = cachedSearchDirectories(fresh: fresh)
                var found: [String: String] = [:]
                for name in names {
                    for dir in dirs {
                        let path = (dir as NSString).appendingPathComponent(name)
                        var isDirectory: ObjCBool = false
                        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                           FileManager.default.isExecutableFile(atPath: path) {
                            found[name] = path
                            break
                        }
                    }
                }
                continuation.resume(returning: found)
            }
        }
    }

    /// The first of the tool's commands whose program is installed.
    static func resolve(_ tool: DevTool, in found: [String: String]) -> (command: String, path: String)? {
        for command in tool.candidateCommands {
            if let program = DevTool.program(of: command), let path = found[program] { return (command, path) }
        }
        return nil
    }

    /// Shell arguments that start the tool in a login shell PTY - by full
    /// path, so it runs even if only an rc file puts it on PATH.
    static func launchArguments(for tool: DevTool, in found: [String: String]) -> [String] {
        guard tool.command != nil else { return ["-l"] }
        guard let (command, path) = resolve(tool, in: found) else { return ["-l", "-c", tool.command ?? ""] }
        let rest = command.split(separator: " ", maxSplits: 1).dropFirst().first.map { " " + $0 } ?? ""
        return ["-l", "-c", "exec \(doubleQuoted(path))\(rest)"]
    }

    /// The PTY environment: the terminal defaults with the tool's folder
    /// first on PATH (an nvm-installed CLI needs its `node` next to it).
    static func launchEnvironment(for tool: DevTool, in found: [String: String], base: [String]) -> [String] {
        guard let (_, path) = resolve(tool, in: found) else { return base }
        let dir = (path as NSString).deletingLastPathComponent
        var env = base.filter { !$0.hasPrefix("PATH=") }
        let current = base.first { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) } ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env.append("PATH=\(dir):\(current)")
        return env
    }

    // MARK: Search folders

    private static func isSafeName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil
    }

    private static func doubleQuoted(_ value: String) -> String {
        var escaped = ""
        for ch in value {
            if "\\\"$`".contains(ch) { escaped.append("\\") }
            escaped.append(ch)
        }
        return "\"\(escaped)\""
    }

    /// Starting the user's shell takes seconds with nvm & co., and the
    /// Settings page, the panel and app activation all ask - so the folder
    /// list is reused for a minute. Files are still checked every time.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (dirs: [String], at: Date)?

    private static func cachedSearchDirectories(fresh: Bool) -> [String] {
        cacheLock.lock()
        if !fresh, let cache, Date().timeIntervalSince(cache.at) < 60 {
            defer { cacheLock.unlock() }
            return cache.dirs
        }
        cacheLock.unlock()
        let dirs = searchDirectories()
        cacheLock.lock()
        cache = (dirs, Date())
        cacheLock.unlock()
        return dirs
    }

    /// Shell PATH (interactive login, else login) followed by the usual
    /// install folders, without duplicates.
    static func searchDirectories() -> [String] {
        let home = NSHomeDirectory()
        var dirs = shellPATH(interactive: true) ?? shellPATH(interactive: false) ?? []
        dirs += [
            "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/bin",
            "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.deno/bin", "\(home)/.cargo/bin",
            "\(home)/.volta/bin", "\(home)/Library/pnpm", "\(home)/.asdf/shims", "\(home)/.local/share/mise/shims",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "\(home)/Library/Application Support/AWSVisualizer/node/bin",
        ]
        dirs += nvmBinDirectories(home: home)
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `~/.nvm/versions/node/*/bin`, newest version first.
    private static func nvmBinDirectories(home: String) -> [String] {
        let root = "\(home)/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(root)/\($0)/bin" }
    }

    /// The PATH the user's shell ends up with. Interactive shells read the
    /// rc files too; their output is ignored (only the marked PATH is
    /// read), stdin is closed and a slow profile is cut off after 6 s.
    private static func shellPATH(interactive: Bool) -> [String]? {
        let start = "__AWSVIS_PATH__", end = "__AWSVIS_END__"
        let value = shell.hasSuffix("fish") ? "(string join : $PATH)" : "\"$PATH\""
        let script = "printf '\(start)%s\(end)' \(value)"
        guard let output = run(shell, arguments: (interactive ? ["-l", "-i", "-c"] : ["-l", "-c"]) + [script], timeout: 6),
              let regex = try? NSRegularExpression(pattern: "\(start)(.*?)\(end)", options: .dotMatchesLineSeparators) else { return nil }
        let ns = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
        guard let match = matches.last else { return nil }
        let dirs = ns.substring(with: match.range(at: 1)).split(separator: ":").map(String.init)
        return dirs.isEmpty ? nil : dirs
    }

    private static func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        var data = Data()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        // Something the profile started in the background may keep the pipe open.
        guard read.wait(timeout: .now() + 1) == .success else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
