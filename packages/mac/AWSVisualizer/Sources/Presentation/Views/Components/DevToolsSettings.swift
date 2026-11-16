import SwiftUI

/// Settings › Developer: pick which tools the right-edge panel offers
/// (built-in shell / AI CLIs / utilities, plus custom commands), see which
/// are installed, and add your own.
struct DevToolsSettings: View {
    @Binding var config: DevToolsConfig

    @State private var installed: Set<String>?
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var newIcon = "terminal"

    private var allTools: [DevTool] { DevToolCatalog.all(custom: config.custom) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enabled tools get a \"+\" entry and an icon in the collapsible panel on the right edge. Each opens in a real terminal using your login shell, so PATH, nvm and API keys from your shell profile work.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(DevTool.Category.allCases, id: \.self) { category in
                let group = allTools.filter { $0.category == category }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category.rawValue.uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)
                        VStack(spacing: 0) {
                            ForEach(group) { tool in
                                row(tool)
                                if tool.id != group.last?.id { Divider() }
                            }
                        }
                        .padding(.horizontal, 10)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            addCustomForm
        }
        .task { await check() }
    }

    private func row(_ tool: DevTool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tool.icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name).font(.body.bold())
                    status(tool)
                }
                Text(tool.command ?? tool.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if tool.command != nil && !tool.isCustom {
                    Text(tool.summary).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if tool.isCustom {
                DeleteButton(compactSize: 22, help: "Remove tool") {
                    config.custom.removeAll { $0.id == tool.id }
                    config.enabled.removeAll { $0 == tool.id }
                }
            }
            Toggle("", isOn: Binding(
                get: { config.enabled.contains(tool.id) },
                set: { isOn in
                    if isOn {
                        if !config.enabled.contains(tool.id) { config.enabled.append(tool.id) }
                    } else {
                        config.enabled.removeAll { $0 == tool.id }
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func status(_ tool: DevTool) -> some View {
        if let binary = tool.binary, let installed {
            if installed.contains(binary) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help("\(binary) found")
            } else if let url = tool.installURL {
                Button("Install") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("\(binary) wasn't found - open the install page")
            } else {
                Text("not found").font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var addCustomForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD YOUR OWN").font(.caption2.bold()).foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Menu {
                    ForEach(DevToolCatalog.customIcons, id: \.self) { icon in
                        Button { newIcon = icon } label: { Label(icon, systemImage: icon) }
                    }
                } label: {
                    Image(systemName: newIcon)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Icon")
                TextField("Name (e.g. My agent)", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                TextField("Command (e.g. ollama run qwen2.5-coder)", text: $newCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                NewButton("Add", isDisabled: newName.trimmingCharacters(in: .whitespaces).isEmpty || newCommand.trimmingCharacters(in: .whitespaces).isEmpty) {
                    addCustom()
                }
            }
            Text("Any command that runs in your terminal - another AI CLI, an SSH session, a REPL. It's added enabled; Save Changes applies it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func addCustom() {
        let tool = CustomDevTool(
            id: "custom-\(UUID().uuidString.prefix(8).lowercased())",
            name: newName.trimmingCharacters(in: .whitespaces),
            command: newCommand.trimmingCharacters(in: .whitespaces),
            icon: newIcon
        )
        config.custom.append(tool)
        config.enabled.append(tool.id)
        newName = ""
        newCommand = ""
        Task { await check() }
    }

    private func check() async {
        installed = await DevToolLocator.installed(allTools.compactMap(\.binary))
    }
}
