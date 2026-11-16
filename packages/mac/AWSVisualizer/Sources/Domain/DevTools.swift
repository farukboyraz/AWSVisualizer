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

    /// First word of the command - what `command -v` looks for.
    var binary: String? {
        command?.split(separator: " ").first.map(String.init)
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
                summary: "Amazon Q Developer CLI chat.", installURL: URL(string: "https://aws.amazon.com/q/developer/")),
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

/// Finds which tools are installed. A GUI app doesn't inherit the shell's
/// PATH (nvm, Homebrew, ~/.local/bin...), so the check runs inside the
/// user's login shell - the same environment the panel launches tools in.
enum DevToolLocator {
    static var shell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    /// Binary name -> installed, checked in one shell run.
    static func installed(_ binaries: [String]) async -> Set<String> {
        let names = Array(Set(binaries.filter { $0.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil }))
        guard !names.isEmpty else { return [] }
        let script = names.map { "command -v \($0) >/dev/null 2>&1 && echo \($0)" }.joined(separator: "; ")
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-l", "-c", script]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: Set(output.split(separator: "\n").map(String.init)))
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Arguments that start the tool in a login shell PTY.
    static func launchArguments(for tool: DevTool) -> [String] {
        guard let command = tool.command else { return ["-l"] }
        return ["-l", "-c", command]
    }
}
