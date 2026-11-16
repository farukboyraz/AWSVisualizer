import SwiftUI

/// Mirrors a distribution's page in the CloudFront console - same tabs:
/// General, Security, Origins, Behaviors, Error pages, Invalidations,
/// Tags - with Enable/Disable and Delete in the action bar. Built from the
/// shared detail components.
struct CloudFrontDistributionDetailView: View {
    let distributionId: String
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case general = "General"
        case security = "Security"
        case origins = "Origins"
        case behaviors = "Behaviors"
        case errorPages = "Error pages"
        case invalidations = "Invalidations"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .general
    @State private var detailState: LoadState<CloudFrontDistributionDetail> = .loading
    @State private var pendingAction: String?
    @State private var actionError: String?

    var body: some View {
        LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(
                    title: detail.id,
                    subtitle: detail.comment?.isEmpty == false ? "\(detail.domainName) · \(detail.comment!)" : detail.domainName,
                    status: detail.status == "Deployed" ? (detail.enabled ? "Enabled" : "Disabled") : detail.status,
                    tab: $tab
                )
                actionBar(detail)

                Group {
                    switch tab {
                    case .general:
                        CloudFrontGeneralTab(detail: detail)
                    case .security:
                        CloudFrontSecurityTab(detail: detail)
                    case .origins:
                        CloudFrontOriginsView(origins: detail.origins)
                    case .behaviors:
                        CloudFrontBehaviorsView(behaviors: detail.behaviors)
                    case .errorPages:
                        CloudFrontErrorPagesView(responses: detail.errorResponses ?? [])
                    case .invalidations:
                        CloudFrontInvalidationsView(distributionId: distributionId)
                    case .tags:
                        ResourceTagsEditor(tags: detail.tags, resourceNoun: "distribution", onAdd: { key, value in
                            detailState = .loaded(try await api.addCloudFrontTag(profile: appState.currentProfile, region: appState.currentRegion, id: distributionId, key: key, value: value))
                        }, onRemove: { key in
                            detailState = .loaded(try await api.removeCloudFrontTag(profile: appState.currentProfile, region: appState.currentRegion, id: distributionId, key: key))
                        })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: distributionId) {
            await loadDetail()
        }
    }

    private func actionBar(_ detail: CloudFrontDistributionDetail) -> some View {
        let isDeploying = detail.status != "Deployed"
        return DetailActionBar(
            error: actionError,
            note: isDeploying ? "Changes are deploying to edge locations - this usually takes a few minutes." : (detail.enabled ? "Disable the distribution and wait for it to finish deploying before deleting it." : nil),
            onRefresh: { Task { await loadDetail() } }
        ) {
            if detail.enabled {
                ConfirmedActionButton(
                    title: "Disable",
                    systemImage: "pause.circle",
                    confirmationTitle: "Disable \(detail.id)?",
                    confirmationMessage: "CloudFront stops serving requests for this distribution once the change deploys.",
                    isLoading: pendingAction == "disable",
                    isDisabled: pendingAction != nil
                ) { Task { await setEnabled(false) } }
            } else {
                ConfirmedActionButton(
                    title: "Enable",
                    systemImage: "play.circle",
                    confirmationTitle: "Enable \(detail.id)?",
                    confirmationMessage: "CloudFront starts serving requests again once the change deploys.",
                    isLoading: pendingAction == "enable",
                    isDisabled: pendingAction != nil,
                    role: nil
                ) { Task { await setEnabled(true) } }
            }
            DeleteButton("Delete", isLoading: pendingAction == "delete", isDisabled: detail.enabled || isDeploying || pendingAction != nil) {
                Task { await deleteDistribution() }
            }
        }
    }

    private func setEnabled(_ enabled: Bool) async {
        pendingAction = enabled ? "enable" : "disable"
        actionError = nil
        do {
            detailState = .loaded(try await api.setCloudFrontDistributionEnabled(profile: appState.currentProfile, region: appState.currentRegion, id: distributionId, enabled: enabled))
        } catch {
            actionError = error.friendlyMessage
        }
        pendingAction = nil
    }

    private func deleteDistribution() async {
        pendingAction = "delete"
        actionError = nil
        do {
            try await api.deleteCloudFrontDistribution(profile: appState.currentProfile, region: appState.currentRegion, id: distributionId)
            onDeleted()
        } catch {
            actionError = error.friendlyMessage
        }
        pendingAction = nil
    }

    private func loadDetail() async {
        do {
            detailState = .loaded(try await api.getCloudFrontDistributionDetail(profile: appState.currentProfile, region: appState.currentRegion, id: distributionId))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

private struct CloudFrontGeneralTab: View {
    let detail: CloudFrontDistributionDetail

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Details", spacing: 12) {
                DetailItemCopy(label: "Distribution domain name", value: detail.domainName)
                DetailGrid(items: [
                    DetailItem("ARN", detail.arn),
                    DetailItem("Last modified", Formatters.formatISODate(detail.lastModified), monospaced: false),
                ])
            }
            DetailSection(title: "Settings", spacing: 12) {
                DetailGrid(items: [
                    DetailItem("Description", detail.comment?.isEmpty == false ? detail.comment : nil, monospaced: false),
                    DetailItem("Price class", detail.priceClass.map(Self.priceClassName), monospaced: false),
                    DetailItem("Supported HTTP versions", detail.httpVersion.map(Self.httpVersionName), monospaced: false),
                    DetailItem("Default root object", detail.defaultRootObject),
                    DetailItem("IPv6", detail.ipv6Enabled.map { $0 ? "On" : "Off" }, monospaced: false),
                    DetailItem("Standard logging", detail.loggingBucket ?? "Off"),
                ])
                let aliases = detail.aliases ?? []
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alternate domain names").font(.caption2).foregroundStyle(.tertiary)
                    if aliases.isEmpty {
                        Text("-").font(.caption)
                    } else {
                        ForEach(aliases, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
            }
        }
    }

    static func priceClassName(_ raw: String) -> String {
        switch raw {
        case "PriceClass_All": return "Use all edge locations (best performance)"
        case "PriceClass_200": return "North America, Europe, Asia, Middle East, and Africa"
        case "PriceClass_100": return "North America and Europe only"
        default: return raw
        }
    }

    static func httpVersionName(_ raw: String) -> String {
        switch raw {
        case "http2and3": return "HTTP/2, HTTP/3"
        case "http2": return "HTTP/2"
        case "http3": return "HTTP/3"
        case "http1.1": return "HTTP/1.1 only"
        default: return raw
        }
    }
}

/// Domain name with a copy button - the value people come here for.
private struct DetailItemCopy: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            CopyableBlock(text: value)
        }
    }
}

/// The console's Security tab: AWS WAF, viewer TLS certificate and
/// geographic restrictions.
private struct CloudFrontSecurityTab: View {
    let detail: CloudFrontDistributionDetail

    var body: some View {
        DetailTabPage(maxWidth: 900) {
            DetailSection(title: "Web Application Firewall (WAF)", spacing: 8) {
                if let webAcl = detail.webAclId {
                    DetailField("Web ACL", webAcl)
                } else {
                    Label("No web ACL associated - requests aren't filtered by AWS WAF.", systemImage: "shield.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            DetailSection(title: "Viewer certificate", spacing: 12) {
                DetailGrid(items: [
                    DetailItem("Certificate", detail.certificateSource == "cloudfront" ? "Default CloudFront certificate (*.cloudfront.net)" : (detail.certificateArn ?? detail.certificateSource), monospaced: detail.certificateSource != "cloudfront"),
                    DetailItem("Security policy (minimum TLS)", detail.minimumProtocolVersion),
                    DetailItem("SSL support method", detail.sslSupportMethod.map { $0 == "sni-only" ? "SNI only" : ($0 == "vip" ? "Dedicated IP (legacy clients)" : $0) }, monospaced: false),
                ])
            }
            DetailSection(title: "Geographic restrictions", spacing: 8) {
                let type = detail.geoRestrictionType ?? "none"
                let locations = detail.geoRestrictionLocations ?? []
                DetailField("Restriction type", type == "none" ? "No restrictions" : (type == "whitelist" ? "Allow list" : "Block list"), monospaced: false)
                if !locations.isEmpty {
                    DetailField("Countries", locations.joined(separator: ", "))
                }
            }
        }
    }
}

private struct CloudFrontErrorPagesView: View {
    let responses: [CloudFrontErrorResponse]

    var body: some View {
        if responses.isEmpty {
            EmptyStateView(message: "No custom error responses - CloudFront returns the origin's error pages.")
        } else {
            Table(responses) {
                TableColumn("HTTP error code") { r in
                    Text("\(r.errorCode)").font(.body.monospaced())
                }
                .width(min: 90, ideal: 120)
                TableColumn("Response page path") { r in
                    Text(r.responsePagePath ?? "-").font(.caption.monospaced())
                }
                .width(min: 140, ideal: 240)
                TableColumn("HTTP response code") { r in
                    Text(r.responseCode ?? "-").font(.caption.monospaced())
                }
                .width(min: 90, ideal: 130)
                TableColumn("Error caching minimum TTL") { r in
                    Text(r.errorCachingMinTtl.map { "\($0) s" } ?? "-").font(.caption)
                }
                .width(min: 120, ideal: 160)
            }
        }
    }
}

/// Lists recent invalidations and creates new ones - one path per line,
/// like the console's "Create invalidation" form.
private struct CloudFrontInvalidationsView: View {
    let distributionId: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var state: LoadState<[CloudFrontInvalidation]> = .loading
    @State private var pathsText = "/*"
    @State private var isCreating = false
    @State private var createError: String?
    @State private var selected: CloudFrontInvalidation?

    private var paths: [String] {
        pathsText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Create invalidation").font(.headline)
                Text("One path per line, each starting with \"/\". A trailing * matches everything under it (\"/images/*\"); \"/*\" clears the whole cache. The first 1,000 paths each month are free.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $pathsText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
                HStack {
                    if let createError {
                        Text(createError).font(.caption).foregroundStyle(.red)
                    } else if let bad = paths.first(where: { !$0.hasPrefix("/") }) {
                        Text("Path must start with \"/\": \(bad)").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    ConfirmedActionButton(
                        title: "Create invalidation",
                        systemImage: "arrow.triangle.2.circlepath",
                        confirmationTitle: "Invalidate \(paths.count) path\(paths.count == 1 ? "" : "s")?",
                        confirmationMessage: "Edge caches drop these objects and fetch them from the origin on the next request. This can briefly raise load on the origin.",
                        isLoading: isCreating,
                        isDisabled: isCreating || paths.isEmpty || paths.contains(where: { !$0.hasPrefix("/") }),
                        role: nil
                    ) { Task { await create() } }
                }
            }
            .padding()

            Divider()

            HStack {
                Text("Invalidations").font(.headline)
                Spacer()
                RefreshButton(compactSize: 22, help: "Refresh") { Task { await load() } }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            LoadableContent(state, retry: { Task { await load() } }, emptyMessage: "No invalidations yet") { items in
                Table(items, selection: Binding(get: { selected?.id }, set: { id in
                    selected = items.first { $0.id == id }
                    if let id { Task { await loadPaths(id) } }
                })) {
                    TableColumn("Invalidation ID") { i in
                        Text(i.id).font(.caption.monospaced())
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn("Status") { i in
                        StatusBadge(i.status)
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Created") { i in
                        Text(Formatters.formatISODate(i.createTime)).font(.caption)
                    }
                    .width(min: 120, ideal: 160)
                }
            }

            if let selected, let paths = selected.paths {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Object paths · \(selected.id)").font(.caption.bold())
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(paths, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .padding()
            }
        }
        .task(id: distributionId) {
            await load()
        }
    }

    private func load() async {
        state = .loading
        do {
            let items = try await api.getCloudFrontInvalidations(profile: appState.currentProfile, region: appState.currentRegion, id: distributionId)
            state = items.isEmpty ? .empty : .loaded(items)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }

    private func loadPaths(_ invalidationId: String) async {
        guard let full = try? await api.getCloudFrontInvalidation(profile: appState.currentProfile, region: appState.currentRegion, id: distributionId, invalidationId: invalidationId),
              selected?.id == invalidationId else { return }
        selected = full
    }

    private func create() async {
        isCreating = true
        createError = nil
        do {
            let created = try await api.createCloudFrontInvalidation(profile: appState.currentProfile, region: appState.currentRegion, id: distributionId, paths: paths)
            await load()
            selected = created
        } catch {
            createError = error.friendlyMessage
        }
        isCreating = false
    }
}

private struct CloudFrontOriginsView: View {
    let origins: [CloudFrontOrigin]

    var body: some View {
        if origins.isEmpty {
            EmptyStateView(message: "No origins")
        } else {
            Table(origins) {
                TableColumn("ID") { o in
                    Text(o.id).font(.caption.monospaced())
                }
                .width(min: 100, ideal: 160)

                TableColumn("Domain") { o in
                    Text(o.domainName).font(.body)
                }
                .width(min: 180, ideal: 300)

                TableColumn("Origin Path") { o in
                    Text(o.originPath?.isEmpty == false ? o.originPath! : "-")
                        .font(.caption.monospaced())
                }
                .width(min: 100, ideal: 160)

                TableColumn("Type") { o in
                    Text(o.type == "s3" ? "S3" : "Custom")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)
            }
        }
    }
}

private struct CloudFrontBehaviorsView: View {
    let behaviors: [CloudFrontCacheBehavior]

    var body: some View {
        if behaviors.isEmpty {
            EmptyStateView(message: "No cache behaviors")
        } else {
            Table(behaviors) {
                TableColumn("Path Pattern") { b in
                    HStack(spacing: 6) {
                        Text(b.pathPattern).font(.body.monospaced())
                        if b.isDefault {
                            Text("default")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }
                .width(min: 140, ideal: 220)

                TableColumn("Origin") { b in
                    Text(b.targetOriginId).font(.caption.monospaced())
                }
                .width(min: 120, ideal: 200)

                TableColumn("Viewer Protocol Policy") { b in
                    Text(b.viewerProtocolPolicy ?? "-").font(.caption)
                }
                .width(min: 140, ideal: 180)

                TableColumn("Allowed Methods") { b in
                    Text(b.allowedMethods?.joined(separator: ", ") ?? "-").font(.caption)
                        .help(b.allowedMethods?.joined(separator: ", ") ?? "")
                }
                .width(min: 120, ideal: 200)

                TableColumn("Cache Policy") { b in
                    Text(b.cachePolicyId ?? "Legacy cache settings").font(.caption.monospaced())
                        .foregroundStyle(b.cachePolicyId == nil ? .secondary : .primary)
                }
                .width(min: 120, ideal: 220)

                TableColumn("Compress") { b in
                    Text(b.compress == true ? "Yes" : "No").font(.caption)
                }
                .width(min: 60, ideal: 70)
            }
        }
    }
}
