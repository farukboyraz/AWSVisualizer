import SwiftUI

/// Mirrors a repository's console page: Images (with scan findings, scan
/// and delete), Details (URI, push commands, tag immutability, scan on
/// push), Lifecycle policy, Permissions (repository policy) and Tags.
struct EcrRepositoryDetailView: View {
    let repositoryName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case images = "Images"
        case details = "Details"
        case lifecycle = "Lifecycle policy"
        case permissions = "Permissions"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .images
    @State private var detailState: LoadState<EcrRepositoryDetail> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeader(
                        title: detail.repositoryName,
                        subtitle: detail.repositoryUri,
                        status: detail.imageTagMutability == "IMMUTABLE" ? "Immutable tags" : nil,
                        tab: $tab
                    )
                    Group {
                        switch tab {
                        case .images:
                            EcrImagesTab(repositoryName: repositoryName, repositoryUri: detail.repositoryUri)
                        case .details:
                            EcrDetailsTab(detail: detail, onUpdated: { detailState = .loaded($0) })
                        case .lifecycle:
                            JsonPolicyEditor(
                                title: "Lifecycle policy",
                                warning: "Lifecycle rules expire images automatically once saved - an overly broad rule can delete images still in use.",
                                emptyMessage: "No lifecycle policy - images are kept forever. The template below expires all but the 30 most recent images.",
                                template: Self.lifecycleTemplate,
                                reloadKey: repositoryName,
                                load: { try await api.getEcrPolicy(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, kind: "lifecycle-policy") },
                                save: { try await api.putEcrPolicy(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, kind: "lifecycle-policy", policy: $0) },
                                delete: { try await api.deleteEcrPolicy(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, kind: "lifecycle-policy") }
                            )
                        case .permissions:
                            JsonPolicyEditor(
                                title: "Repository policy",
                                warning: "Controls who can pull and push. Lambda container functions and cross-account pulls usually depend on it - double-check before saving or deleting.",
                                emptyMessage: "No repository policy - only IAM permissions in this account apply.",
                                reloadKey: repositoryName,
                                load: { try await api.getEcrPolicy(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, kind: "policy") },
                                save: { try await api.putEcrPolicy(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, kind: "policy", policy: $0) },
                                delete: { try await api.deleteEcrPolicy(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, kind: "policy") }
                            )
                        case .tags:
                            ResourceTagsEditor(tags: detail.tags, resourceNoun: "repository", onAdd: { key, value in
                                detailState = .loaded(try await api.addEcrRepositoryTag(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, arn: detail.repositoryArn, key: key, value: value))
                            }, onRemove: { key in
                                detailState = .loaded(try await api.removeEcrRepositoryTag(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, arn: detail.repositoryArn, key: key))
                            })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: repositoryName) {
            await loadDetail()
        }
    }

    private static let lifecycleTemplate = """
    {
      "rules": [
        {
          "rulePriority": 1,
          "description": "Keep only the 30 most recent images",
          "selection": {
            "tagStatus": "any",
            "countType": "imageCountMoreThan",
            "countNumber": 30
          },
          "action": { "type": "expire" }
        }
      ]
    }
    """

    private func loadDetail() async {
        do {
            detailState = .loaded(try await api.getEcrRepositoryDetail(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

private struct EcrImagesTab: View {
    let repositoryName: String
    let repositoryUri: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var images: [EcrImage] = []
    @State private var state: LoadState<Void> = .loading
    @State private var nextToken: String?
    @State private var isLoadingMore = false
    @State private var filter = ""
    @State private var busyDigest: String?
    @State private var findingsFor: EcrImage?
    @State private var error: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by tag or digest", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                Spacer()
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadFirstPage() } }
            }
            .padding(.horizontal)
            .padding(.top, 4)

            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            if let message { Text(message).font(.caption).foregroundStyle(.green).padding(.horizontal) }

            LoadableContent(state, retry: { Task { await loadFirstPage() } }) { _ in
                VStack(spacing: 0) {
                    Table(filteredImages) {
                        TableColumn("Image tags") { image in
                            Text(image.imageTags.isEmpty ? "<untagged>" : image.imageTags.joined(separator: ", "))
                                .font(.caption.monospaced())
                                .foregroundStyle(image.imageTags.isEmpty ? .secondary : .primary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                        .width(min: 140, ideal: 220)
                        TableColumn("Pushed") { image in
                            Text(Formatters.formatISODate(image.pushedAt)).font(.caption)
                        }
                        .width(min: 110, ideal: 140)
                        TableColumn("Size") { image in
                            Text(Formatters.formatBytes(image.sizeInBytes)).font(.caption.monospacedDigit())
                        }
                        .width(min: 60, ideal: 80)
                        TableColumn("Last pulled") { image in
                            Text(Formatters.formatISODate(image.lastPulledAt)).font(.caption).foregroundStyle(.secondary)
                        }
                        .width(min: 110, ideal: 140)
                        TableColumn("Vulnerabilities") { image in
                            scanSummary(image)
                        }
                        .width(min: 100, ideal: 150)
                        TableColumn("Digest") { image in
                            Text(String(image.imageDigest.replacingOccurrences(of: "sha256:", with: "").prefix(12)))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .help(image.imageDigest)
                                .textSelection(.enabled)
                        }
                        .width(min: 90, ideal: 100)
                        TableColumn("") { image in
                            HStack(spacing: 6) {
                                Button {
                                    findingsFor = image
                                } label: {
                                    Image(systemName: "shield.lefthalf.filled")
                                }
                                .buttonStyle(.borderless)
                                .help("Scan findings")
                                Button {
                                    Task { await scan(image) }
                                } label: {
                                    Image(systemName: "magnifyingglass.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Scan now")
                                .disabled(busyDigest != nil)
                                DeleteButton(compactSize: 20, isLoading: busyDigest == image.imageDigest, isDisabled: busyDigest != nil, help: "Delete Image") {
                                    Task { await delete(image) }
                                }
                            }
                        }
                        .width(84)
                    }
                    .contextMenu(forSelectionType: EcrImage.ID.self) { ids in
                        if let image = images.first(where: { ids.contains($0.id) }) {
                            Button("Copy image URI") { copy(imageUri(image)) }
                            Button("Copy digest") { copy(image.imageDigest) }
                        }
                    }

                    if nextToken != nil {
                        Button(isLoadingMore ? "Loading…" : "Load more images") {
                            Task { await loadMore() }
                        }
                        .disabled(isLoadingMore)
                        .padding(6)
                    }
                }
            }
        }
        .task(id: repositoryName) {
            await loadFirstPage()
        }
        .sheet(item: $findingsFor) { image in
            EcrFindingsSheet(repositoryName: repositoryName, image: image)
        }
    }

    @ViewBuilder
    private func scanSummary(_ image: EcrImage) -> some View {
        if !image.findingCounts.isEmpty {
            HStack(spacing: 4) {
                ForEach(image.findingCounts.sorted { severityRank($0.key) < severityRank($1.key) }) { count in
                    Text("\(count.value) \(count.key.prefix(1))")
                        .font(.caption2.bold().monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(severityColor(count.key).opacity(0.2))
                        .foregroundStyle(severityColor(count.key))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help("\(count.value) \(count.key.lowercased())")
                }
            }
        } else if let status = image.scanStatus {
            Text(status == "COMPLETE" ? "None found" : status.replacingOccurrences(of: "_", with: " ").lowercased())
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Not scanned").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var filteredImages: [EcrImage] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return images }
        return images.filter { $0.imageDigest.lowercased().contains(q) || $0.imageTags.contains { $0.lowercased().contains(q) } }
    }

    private func imageUri(_ image: EcrImage) -> String {
        if let tag = image.imageTags.first { return "\(repositoryUri):\(tag)" }
        return "\(repositoryUri)@\(image.imageDigest)"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func loadFirstPage() async {
        state = .loading
        error = nil
        do {
            let page = try await api.getEcrImages(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, nextToken: nil)
            images = page.images
            nextToken = page.nextToken
            state = images.isEmpty ? .empty : .loaded(())
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }

    private func loadMore() async {
        guard let token = nextToken else { return }
        isLoadingMore = true
        do {
            let page = try await api.getEcrImages(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, nextToken: token)
            images.append(contentsOf: page.images)
            nextToken = page.nextToken
        } catch {
            self.error = error.friendlyMessage
        }
        isLoadingMore = false
    }

    private func scan(_ image: EcrImage) async {
        busyDigest = image.imageDigest
        error = nil
        message = nil
        do {
            try await api.startEcrImageScan(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, digest: image.imageDigest)
            message = "Scan started - results appear here once it completes (usually within a few minutes)."
        } catch {
            self.error = error.friendlyMessage
        }
        busyDigest = nil
    }

    private func delete(_ image: EcrImage) async {
        busyDigest = image.imageDigest
        error = nil
        message = nil
        do {
            try await api.deleteEcrImage(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, digest: image.imageDigest)
            images.removeAll { $0.imageDigest == image.imageDigest }
            if images.isEmpty { state = .empty }
        } catch {
            self.error = error.friendlyMessage
        }
        busyDigest = nil
    }
}

private func severityRank(_ severity: String) -> Int {
    ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL", "UNDEFINED"].firstIndex(of: severity) ?? 99
}

private func severityColor(_ severity: String) -> Color {
    switch severity {
    case "CRITICAL": return .red
    case "HIGH": return .orange
    case "MEDIUM": return .yellow
    case "LOW": return .blue
    default: return .secondary
    }
}

private struct EcrFindingsSheet: View {
    let repositoryName: String
    let image: EcrImage

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var state: LoadState<EcrScanFindings> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan findings").font(.title3.bold())
                    Text(image.imageTags.first ?? image.imageDigest)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }

            LoadableContent(state, retry: { Task { await load() } }) { result in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        if let status = result.scanStatus { StatusBadge(status) }
                        if let completed = result.completedAt {
                            Text("Completed \(Formatters.formatISODate(completed))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let description = result.scanStatusDescription {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                    if result.findings.isEmpty {
                        EmptyStateView(message: result.scanStatus == "COMPLETE" ? "No vulnerabilities found" : "No findings available")
                    } else {
                        List(result.findings) { finding in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(finding.severity)
                                        .font(.caption2.bold())
                                        .foregroundStyle(severityColor(finding.severity))
                                        .frame(width: 90, alignment: .leading)
                                    if let uri = finding.uri, let url = URL(string: uri) {
                                        Link(finding.name, destination: url).font(.caption.monospaced())
                                    } else {
                                        Text(finding.name).font(.caption.monospaced())
                                    }
                                    Spacer()
                                    if let package = finding.packageName {
                                        Text("\(package) \(finding.packageVersion ?? "")")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let description = finding.description {
                                    Text(description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 720, idealWidth: 860, minHeight: 440, idealHeight: 600)
        .task { await load() }
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await api.getEcrScanFindings(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, digest: image.imageDigest))
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }
}

private struct EcrDetailsTab: View {
    let detail: EcrRepositoryDetail
    var onUpdated: (EcrRepositoryDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        DetailTabPage {
            DetailSection(title: "Repository") {
                CopyableBlock(text: detail.repositoryUri)
                DetailField("ARN", detail.repositoryArn)
                HStack(spacing: 24) {
                    DetailField("Registry", detail.registryId)
                    DetailField("Created", Formatters.formatISODate(detail.createdAt), monospaced: false)
                    DetailField("Encryption", detail.encryptionType == "KMS" ? "KMS\(detail.kmsKey.map { " (\($0))" } ?? "")" : (detail.encryptionType ?? "-"))
                }
            }

            DetailSection(title: "Settings", spacing: 10) {
                LabeledSwitchBox(title: "Tag immutability (prevent overwriting existing tags)", isOn: Binding(
                    get: { detail.imageTagMutability == "IMMUTABLE" },
                    set: { newValue in Task { await setImmutability(newValue) } }
                ))
                .disabled(busy != nil)
                LabeledSwitchBox(title: "Scan on push (basic scanning)", isOn: Binding(
                    get: { detail.scanOnPush },
                    set: { newValue in Task { await setScanOnPush(newValue) } }
                ))
                .disabled(busy != nil)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)

            DetailSection(title: "Push commands") {
                Text("Same steps as the console's \"View push commands\" - run them in a terminal with Docker installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CopyableBlock(text: pushCommands)
            }
        }
    }

    private var registry: String {
        detail.repositoryUri.split(separator: "/").first.map(String.init) ?? detail.repositoryUri
    }

    private var pushCommands: String {
        """
        aws ecr get-login-password --region \(appState.currentRegion) --profile \(appState.currentProfile) | docker login --username AWS --password-stdin \(registry)
        docker build -t \(detail.repositoryName) .
        docker tag \(detail.repositoryName):latest \(detail.repositoryUri):latest
        docker push \(detail.repositoryUri):latest
        """
    }

    private func setImmutability(_ immutable: Bool) async {
        busy = "mutability"
        error = nil
        do {
            onUpdated(try await api.setEcrTagMutability(profile: appState.currentProfile, region: appState.currentRegion, name: detail.repositoryName, immutable: immutable))
        } catch {
            self.error = error.friendlyMessage
        }
        busy = nil
    }

    private func setScanOnPush(_ enabled: Bool) async {
        busy = "scan"
        error = nil
        do {
            onUpdated(try await api.setEcrScanOnPush(profile: appState.currentProfile, region: appState.currentRegion, name: detail.repositoryName, enabled: enabled))
        } catch {
            self.error = error.friendlyMessage
        }
        busy = nil
    }
}
