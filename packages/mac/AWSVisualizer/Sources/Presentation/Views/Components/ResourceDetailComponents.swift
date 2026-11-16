import SwiftUI
import AppKit

// Building blocks shared by every service detail panel: header with tabs,
// action bar, tab page, sections, read-only fields (single or as a
// console-style multi-column grid), tag editor and JSON policy editor.
// New detail views should be built from these, not private copies.

/// Caption label over a selectable monospaced value - the read-only
/// "Details" row every detail tab uses.
struct DetailField: View {
    let label: String
    let value: String
    var monospaced: Bool = true

    init(_ label: String, _ value: String, monospaced: Bool = true) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value.isEmpty ? "-" : value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One label/value pair for `DetailGrid`.
struct DetailItem: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    var monospaced: Bool = true

    init(_ label: String, _ value: String?, monospaced: Bool = true) {
        self.label = label
        self.value = value ?? "-"
        self.monospaced = monospaced
    }
}

/// The AWS console's "Details" / "Instance summary" block: fields flow
/// into as many columns as fit (2-3 in a normal detail panel, 1 when
/// narrow), so a dozen attributes don't become one long column.
struct DetailGrid: View {
    let items: [DetailItem]
    var minColumnWidth: CGFloat = 200

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minColumnWidth), spacing: 20, alignment: .topLeading)], alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                DetailField(item.label, item.value, monospaced: item.monospaced)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Row of resource actions under a `DetailHeader` (Start/Stop, Purge,
/// Enable/Disable...) with Refresh at the right and an error line below -
/// where the console puts its "Actions" buttons.
struct DetailActionBar<Content: View>: View {
    var error: String?
    var note: String?
    var onRefresh: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                content
                Spacer()
                if let onRefresh {
                    RefreshButton(compactSize: 22, help: "Refresh") { onRefresh() }
                }
            }
            .controlSize(.small)
            if let note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// Headline + stacked content, the section unit inside a detail tab.
struct DetailSection<Content: View>: View {
    let title: String
    var spacing: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title)
                .font(.headline)
            content
        }
    }
}

/// Scrollable, top-aligned, width-capped page body used by every tab.
struct DetailTabPage<Content: View>: View {
    var maxWidth: CGFloat = 760
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(24)
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Small value tile for metric summaries (RDS Monitoring, ECS counts).
struct MetricTile: View {
    let title: String
    let value: String
    var caption: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(tint)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Monospaced block with a copy button - ECR push commands, endpoints.
struct CopyableBlock: View {
    let text: String

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Lists a resource's tags with remove buttons plus an add row. Each
/// service passes its own add/remove calls; the closures return nothing
/// because the caller refreshes its own detail model from the response.
struct ResourceTagsEditor: View {
    let tags: [ResourceTag]
    var resourceNoun: String = "resource"
    let onAdd: (_ key: String, _ value: String) async throws -> Void
    let onRemove: (_ key: String) async throws -> Void

    @State private var newKey = ""
    @State private var newValue = ""
    @State private var isAdding = false
    @State private var removingKey: String?
    @State private var error: String?

    @Environment(AppState.self) private var appState

    var body: some View {
        DetailTabPage(maxWidth: 720) {
            DetailSection(title: appState.language.tagsTitle, spacing: 12) {
                if tags.isEmpty {
                    Text(appState.language.noTagsMessage(noun: resourceNoun))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tags) { tag in
                            HStack {
                                Text(tag.key)
                                    .font(.caption.monospaced().bold())
                                Text(tag.value)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Spacer()
                                DeleteButton(compactSize: 20, isLoading: removingKey == tag.key, isDisabled: removingKey != nil, help: appState.language.removeTagHelp) {
                                    Task { await remove(tag.key) }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField(appState.language.tagKeyPlaceholder, text: $newKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    TextField(appState.language.tagValuePlaceholder, text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    NewButton(appState.language.addTagButton, isLoading: isAdding, isDisabled: !TagRules.canAdd(key: newKey, value: newValue)) {
                        Task { await add() }
                    }
                }
                TagInputWarning(key: newKey, value: newValue)

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func add() async {
        let key = newKey.trimmingCharacters(in: .whitespaces)
        guard TagRules.canAdd(key: newKey, value: newValue) else { return }
        isAdding = true
        error = nil
        do {
            try await onAdd(key, newValue)
            newKey = ""
            newValue = ""
        } catch {
            self.error = error.friendlyMessage
        }
        isAdding = false
    }

    private func remove(_ key: String) async {
        removingKey = key
        error = nil
        do {
            try await onRemove(key)
        } catch {
            self.error = error.friendlyMessage
        }
        removingKey = nil
    }
}

/// Raw JSON policy editor for resources that may or may not have a policy
/// yet (SNS access/delivery policy, ECR lifecycle/repository policy) - the
/// KMS / Secrets Manager policy tab pattern, generalised. `load` returning
/// `nil` means "no policy attached"; `delete` is omitted where the API has
/// no delete (SNS access policy always exists).
struct JsonPolicyEditor: View {
    let title: String
    var warning: String?
    var emptyMessage: String = "No policy attached."
    /// Template offered when no policy exists yet.
    var template: String = ""
    /// Changes when the underlying resource changes, to reload.
    let reloadKey: String
    let load: () async throws -> String?
    let save: (String) async throws -> Void
    var delete: (() async throws -> Void)?

    @State private var state: LoadState<String?> = .loading
    @State private var text = ""
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        LoadableContent(state, retry: { Task { await reload() } }) { existing in
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                if let warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if existing == nil {
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))

                HStack {
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if let message {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    if let delete, existing != nil {
                        DeleteButton("Delete Policy", isLoading: isDeleting, isDisabled: isSaving) {
                            Task { await runDelete(delete) }
                        }
                    }
                    SaveButton("Save Policy", isLoading: isSaving, isDisabled: isDeleting || !isValidJson) {
                        Task { await runSave() }
                    }
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isValidJson {
                    Text("Not valid JSON yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task(id: reloadKey) {
            await reload()
        }
    }

    private var isValidJson: Bool {
        guard let data = text.data(using: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private func reload() async {
        state = .loading
        message = nil
        error = nil
        do {
            let policy = try await load()
            text = policy ?? template
            state = .loaded(policy)
        } catch {
            state = .failed(error.friendlyMessage)
        }
    }

    private func runSave() async {
        isSaving = true
        error = nil
        message = nil
        do {
            try await save(text)
            state = .loaded(text)
            message = "Saved"
        } catch {
            self.error = error.friendlyMessage
        }
        isSaving = false
    }

    private func runDelete(_ delete: () async throws -> Void) async {
        isDeleting = true
        error = nil
        message = nil
        do {
            try await delete()
            text = template
            state = .loaded(nil)
            message = "Deleted"
        } catch {
            self.error = error.friendlyMessage
        }
        isDeleting = false
    }
}

/// Title + optional status badge + segmented tab picker - the header every
/// detail panel in this family opens with.
struct DetailHeader<Tab: Hashable & CaseIterable & RawRepresentable>: View where Tab.RawValue == String, Tab.AllCases: RandomAccessCollection {
    let title: String
    var subtitle: String?
    var status: String?
    @Binding var tab: Tab
    var onBack: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let onBack {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title2.bold())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if let status {
                    StatusBadge(status)
                }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 6)

            TabBar(tabs: Array(Tab.allCases), selection: $tab, title: { $0.rawValue })
                .padding(.bottom, 8)
        }
    }
}

extension Formatters {
    /// "1.4 GB" style - CloudWatch byte metrics come back as Double.
    static func formatByteCount(_ bytes: Double?) -> String {
        guard let bytes else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    static func formatNumber(_ value: Double?, decimals: Int = 1) -> String {
        guard let value else { return "-" }
        return String(format: "%.\(decimals)f", value)
    }
}

extension Formatters {
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// The backend's `Date.toISOString()` output ("2026-10-05T00:52:16.190Z").
    static func formatISODate(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "-" }
        guard let date = isoWithFraction.date(from: raw) ?? isoPlain.date(from: raw) else { return raw }
        return displayFormatter.string(from: date)
    }
}

/// A bordered action button that asks first - for operational actions
/// that aren't deletions but still disturb a running system (stop/reboot a
/// database, stop a task, force a redeploy). `DeleteButton`'s generic
/// "this data will be deleted" wording would be wrong for these.
struct ConfirmedActionButton: View {
    let title: String
    var systemImage: String?
    let confirmationTitle: String
    let confirmationMessage: String
    var isLoading: Bool = false
    var isDisabled: Bool = false
    var role: ButtonRole? = .destructive
    /// Button color kind - defaults to `.warning` for destructive actions
    /// (stop / reboot / stop task) and `.confirm` otherwise (start, enable).
    var kind: AppButtonKind?
    let action: () -> Void

    @State private var showConfirmation = false

    var body: some View {
        AppButton(
            title,
            kind: kind ?? (role == .destructive ? .warning : .confirm),
            systemImage: systemImage,
            showIcon: systemImage != nil,
            isLoading: isLoading,
            isDisabled: isDisabled
        ) {
            showConfirmation = true
        }
        .confirmationDialog(confirmationTitle, isPresented: $showConfirmation, titleVisibility: .visible) {
            Button(title, role: role, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }
}
