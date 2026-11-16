import SwiftUI

/// Mirrors a hosted zone's console page: Records (with create / edit /
/// delete for simple records), Hosted zone details, and Tags.
struct Route53ZoneDetailView: View {
    let zoneId: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    enum DetailTab: String, CaseIterable {
        case records = "Records"
        case details = "Hosted zone details"
        case tags = "Tags"
    }

    @State private var tab: DetailTab = .records
    @State private var detailState: LoadState<Route53ZoneDetail> = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(detailState, retry: { Task { await loadDetail() } }) { detail in
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeader(
                        title: detail.name,
                        subtitle: "\(detail.id) · \(detail.isPrivate ? "Private" : "Public") hosted zone",
                        tab: $tab
                    )
                    Group {
                        switch tab {
                        case .records:
                            Route53RecordsTab(zoneId: zoneId, zoneName: detail.name)
                        case .details:
                            Route53DetailsTab(detail: detail, onUpdated: { detailState = .loaded($0) })
                        case .tags:
                            ResourceTagsEditor(tags: detail.tags, resourceNoun: "hosted zone", onAdd: { key, value in
                                detailState = .loaded(try await api.addRoute53ZoneTag(profile: appState.currentProfile, zoneId: zoneId, key: key, value: value))
                            }, onRemove: { key in
                                detailState = .loaded(try await api.removeRoute53ZoneTag(profile: appState.currentProfile, zoneId: zoneId, key: key))
                            })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: zoneId) {
            await loadDetail()
        }
    }

    private func loadDetail() async {
        do {
            detailState = .loaded(try await api.getRoute53ZoneDetail(profile: appState.currentProfile, zoneId: zoneId))
        } catch {
            detailState = .failed(error.friendlyMessage)
        }
    }
}

/// What the record editor sheet is open for.
private enum RecordSheetTarget: Identifiable {
    case create
    case edit(Route53Record)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let record): return record.id
        }
    }
}

private struct Route53RecordsTab: View {
    let zoneId: String
    let zoneName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var records: [Route53Record] = []
    @State private var state: LoadState<Void> = .loading
    @State private var nextCursor: (name: String?, type: String?, identifier: String?)?
    @State private var isLoadingMore = false
    @State private var filter = ""
    @State private var sheetTarget: RecordSheetTarget?
    @State private var deletingRecord: String?
    @State private var pendingDelete: Route53Record?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by name, type or value", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer()
                NewButton("Create Record") { sheetTarget = .create }
                RefreshButton(compactSize: 24, help: "Refresh") { Task { await loadFirstPage() } }
            }
            .padding(.horizontal)
            .padding(.top, 4)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            LoadableContent(state, retry: { Task { await loadFirstPage() } }) { _ in
                VStack(spacing: 0) {
                    Table(filteredRecords) {
                        TableColumn("Name") { r in
                            Text(r.name).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        .width(min: 160, ideal: 240)
                        TableColumn("Type") { r in
                            Text(r.type).font(.caption.bold())
                        }
                        .width(min: 44, ideal: 56)
                        TableColumn("Routing") { r in
                            Text(r.routingPolicy).font(.caption).foregroundStyle(.secondary)
                        }
                        .width(min: 60, ideal: 90)
                        TableColumn("TTL") { r in
                            Text(r.ttl.map(String.init) ?? "-").font(.caption.monospacedDigit())
                        }
                        .width(min: 40, ideal: 60)
                        TableColumn("Value / Route traffic to") { r in
                            Text(valueSummary(r))
                                .font(.caption.monospaced())
                                .lineLimit(3)
                                .textSelection(.enabled)
                                .help(valueSummary(r))
                        }
                        .width(min: 180, ideal: 320)
                        TableColumn("") { r in
                            HStack(spacing: 6) {
                                if r.aliasTarget == nil && !isApexSystemRecord(r) {
                                    EditButton(compactSize: 20, help: "Edit Record") { sheetTarget = .edit(r) }
                                }
                                if !isApexSystemRecord(r) {
                                    DeleteButton(compactSize: 20, isLoading: deletingRecord == r.id, isDisabled: deletingRecord != nil, help: "Delete Record") {
                                        Task { await delete(r) }
                                    }
                                }
                            }
                        }
                        .width(56)
                    }

                    if nextCursor != nil {
                        HStack {
                            Spacer()
                            SecondaryButton("Load more records", systemImage: "arrow.down.circle", isLoading: isLoadingMore) {
                                Task { await loadMore() }
                            }
                            Spacer()
                        }
                        .padding(6)
                    }
                }
            }
        }
        .task(id: zoneId) {
            await loadFirstPage()
        }
        .sheet(item: $sheetTarget) { target in
            Route53RecordEditor(zoneId: zoneId, zoneName: zoneName, target: target) {
                Task { await loadFirstPage() }
            }
        }
    }

    private var filteredRecords: [Route53Record] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return records }
        return records.filter {
            $0.name.lowercased().contains(q) || $0.type.lowercased() == q || $0.values.contains { $0.lowercased().contains(q) }
                || ($0.aliasTarget?.dnsName.lowercased().contains(q) ?? false)
        }
    }

    /// The zone's own NS and SOA records - Route53 refuses to delete them
    /// and editing them is how a zone gets broken, so neither is offered.
    private func isApexSystemRecord(_ r: Route53Record) -> Bool {
        (r.type == "NS" || r.type == "SOA") && r.name.lowercased() == zoneName.lowercased()
    }

    private func valueSummary(_ r: Route53Record) -> String {
        if let alias = r.aliasTarget {
            return "ALIAS → \(alias.dnsName)\(alias.evaluateTargetHealth ? " (evaluate health)" : "")"
        }
        return r.values.joined(separator: "\n")
    }

    private func loadFirstPage() async {
        state = .loading
        error = nil
        do {
            let page = try await api.getRoute53Records(profile: appState.currentProfile, zoneId: zoneId)
            records = page.records
            nextCursor = page.nextRecordName.map { ($0, page.nextRecordType, page.nextRecordIdentifier) }
            state = .loaded(())
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor else { return }
        isLoadingMore = true
        do {
            let page = try await api.getRoute53Records(profile: appState.currentProfile, zoneId: zoneId, startName: cursor.name, startType: cursor.type, startIdentifier: cursor.identifier)
            records.append(contentsOf: page.records)
            nextCursor = page.nextRecordName.map { ($0, page.nextRecordType, page.nextRecordIdentifier) }
        } catch {
            self.error = error.friendlyMessage
        }
        isLoadingMore = false
    }

    private func delete(_ record: Route53Record) async {
        deletingRecord = record.id
        error = nil
        do {
            try await api.deleteRoute53Record(profile: appState.currentProfile, zoneId: zoneId, record: record)
            records.removeAll { $0.id == record.id }
        } catch {
            self.error = error.friendlyMessage
        }
        deletingRecord = nil
    }
}

private struct Route53RecordEditor: View {
    let zoneId: String
    let zoneName: String
    let target: RecordSheetTarget
    var onSaved: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    private static let recordTypes = ["A", "AAAA", "CNAME", "TXT", "MX", "NS", "PTR", "SRV", "CAA", "SPF", "NAPTR", "DS"]

    @State private var subdomain = ""
    @State private var type = "A"
    @State private var ttl = 300
    @State private var valuesText = ""
    @State private var isSaving = false
    @State private var error: String?

    private var editing: Route53Record? {
        if case .edit(let record) = target { return record }
        return nil
    }

    /// Zone apex without the trailing dot, for display after the subdomain field.
    private var zoneSuffix: String {
        zoneName.hasSuffix(".") ? String(zoneName.dropLast()) : zoneName
    }

    private var fullName: String {
        let sub = subdomain.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return sub.isEmpty ? zoneSuffix : "\(sub).\(zoneSuffix)"
    }

    private var values: [String] {
        valuesText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "Create record" : "Edit record")
                .font(.title3.bold())

            if let editing {
                DetailField("Record name", editing.name)
                HStack(spacing: 24) {
                    DetailField("Type", editing.type)
                    DetailField("Routing policy", editing.routingPolicy)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Record name").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("subdomain (empty for the apex)", text: $subdomain)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                        Text(".\(zoneSuffix)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Picker("Record type", selection: $type) {
                    ForEach(Self.recordTypes, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 220)
            }

            HStack(spacing: 8) {
                Text("TTL (seconds)")
                TextField("", value: $ttl, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                ForEach([60, 300, 3600, 86400], id: \.self) { preset in
                    SecondaryButton(preset >= 3600 ? "\(preset / 3600)h" : "\(preset / 60)m") { ttl = preset }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Value - one per line").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $valuesText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
                Text(valueHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                SecondaryButton("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                SaveButton(editing == nil ? "Create Record" : "Save Changes", isLoading: isSaving, isDisabled: values.isEmpty || ttl < 0) {
                    Task { await save() }
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let editing {
                ttl = editing.ttl ?? 300
                valuesText = editing.values.joined(separator: "\n")
            }
        }
    }

    private var valueHint: String {
        switch editing?.type ?? type {
        case "TXT", "SPF": return "TXT values must be wrapped in double quotes, e.g. \"v=spf1 include:example.com ~all\"."
        case "MX": return "Priority and mail server, e.g. 10 mail.example.com"
        case "CNAME": return "A single domain name, e.g. app.example.net"
        case "SRV": return "priority weight port target, e.g. 1 10 5269 xmpp.example.com"
        case "CAA": return "flags tag \"value\", e.g. 0 issue \"amazon.com\""
        default: return "Separate multiple values with new lines."
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            if let editing {
                try await api.updateRoute53Record(profile: appState.currentProfile, zoneId: zoneId, record: editing, ttl: ttl, values: values)
            } else {
                try await api.createRoute53Record(profile: appState.currentProfile, zoneId: zoneId, name: fullName, type: type, ttl: ttl, values: values)
            }
            onSaved()
            dismiss()
        } catch {
            self.error = error.friendlyMessage
        }
        isSaving = false
    }
}

private struct Route53DetailsTab: View {
    let detail: Route53ZoneDetail
    var onUpdated: (Route53ZoneDetail) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var comment = ""
    @State private var isSaving = false
    @State private var saved = false
    @State private var error: String?

    var body: some View {
        DetailTabPage {
            DetailSection(title: "Hosted zone") {
                HStack(spacing: 24) {
                    DetailField("Hosted zone ID", detail.id)
                    DetailField("Type", detail.isPrivate ? "Private" : "Public")
                    DetailField("Record count", "\(detail.recordCount)")
                }
            }

            SettingsFieldRow(label: "Description (comment)", isSaving: isSaving, error: error, saved: saved, save: { Task { await saveComment() } }) {
                TextField("", text: $comment)
                    .textFieldStyle(.roundedBorder)
            }

            if !detail.nameServers.isEmpty {
                DetailSection(title: "Name servers") {
                    Text("Use these at your domain registrar to delegate the domain to this zone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    CopyableBlock(text: detail.nameServers.joined(separator: "\n"))
                }
            }

            if !detail.vpcs.isEmpty {
                DetailSection(title: "Associated VPCs") {
                    ForEach(detail.vpcs, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
        }
        .task(id: detail.id) {
            comment = detail.comment ?? ""
        }
    }

    private func saveComment() async {
        isSaving = true
        error = nil
        saved = false
        do {
            onUpdated(try await api.updateRoute53ZoneComment(profile: appState.currentProfile, zoneId: detail.id, comment: comment))
            saved = true
        } catch {
            self.error = error.friendlyMessage
        }
        isSaving = false
    }
}
