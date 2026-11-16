import SwiftUI

/// Where a form reads its dropdowns from. Card forms use the dashboard's
/// option sources; ResourcePage forms pass `loadOptions` (the page's own
/// /pages/<service>/options route).
struct CardFormContext {
    let service: String
    let profile: String
    let region: String
    let language: AppLanguage
    var loadOptions: ((_ source: String, _ params: [String: String]) async throws -> [CardOption])? = nil
}

/// One template parameter as a form row: label, the right control for its
/// type, its hint and - once something is typed - what's wrong with it.
struct CardParamField: View {
    let param: CardTemplate.Param
    @Binding var params: [String: String]
    let context: CardFormContext

    private var language: AppLanguage { context.language }

    private var value: Binding<String> {
        Binding(get: { params[param.key] ?? "" }, set: { params[param.key] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                Text(param.label(language)).font(.callout.weight(.medium))
                if param.isRequired { Text("*").foregroundStyle(.red) }
            }
            control
            if let hint = param.hint {
                Text(hint(language)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if param.type != .dynamoQuery && param.type != .dynamoSearch, !(params[param.key] ?? "").isEmpty, let problem = param.problem(params[param.key] ?? "", language: language) {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch param.type {
        case .text:
            TextField(param.placeholder ?? "", text: value).textFieldStyle(.roundedBorder)
        case .textarea:
            TextField(param.placeholder ?? "", text: value, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
        case .select:
            Picker("", selection: value) {
                if !param.isRequired { Text("—").tag("") }
                ForEach(param.choices ?? [], id: \.value) { Text($0.label(language)).tag($0.value) }
            }
            .labelsHidden()
            .fixedSize()
        case .combo:
            CardComboField(param: param, value: value, params: params, context: context)
        case .dynamoQuery:
            DynamoSearchBuilderField(param: param, value: value, params: params, context: context)
        case .dynamoSearch:
            DynamoSearchBuilderField(param: param, value: value, params: params, context: context)
        }
    }
}

/// A text field with a dropdown of choices loaded from the sidecar (buckets,
/// folders, tables, branches…). Waits for the fields it depends on and
/// reloads when they change; the value can also be typed.
struct CardComboField: View {
    let param: CardTemplate.Param
    @Binding var value: String
    let params: [String: String]
    let context: CardFormContext

    @Environment(\.apiService) private var api

    @State private var options: [CardOption] = []
    @State private var isLoading = false
    @State private var failure: String?
    @State private var showList = false
    @State private var search = ""

    private var language: AppLanguage { context.language }
    /// Other fields this one needs (its own key only means "reload on change").
    private var missing: [String] {
        (param.dependsOn ?? []).filter { $0 != param.key && (params[$0] ?? "").isEmpty }
    }
    private var reloadKey: String {
        ([context.profile, context.region] + (param.dependsOn ?? []).map { params[$0] ?? "" }).joined(separator: "|")
    }
    private var filtered: [CardOption] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? options : options.filter { $0.label.lowercased().contains(needle) || $0.value.lowercased().contains(needle) }
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField(missing.isEmpty ? (param.placeholder ?? "") : language.cardWaitFor(missing.joined(separator: ", ")), text: $value)
                .textFieldStyle(.roundedBorder)
                .disabled(!missing.isEmpty)
            Button {
                search = ""
                showList.toggle()
            } label: {
                if isLoading {
                    ProgressView().controlSize(.small).frame(width: 16)
                } else {
                    Image(systemName: "chevron.down").frame(width: 16)
                }
            }
            .disabled(!missing.isEmpty)
            .help(language.cardOptionsLoading)
            .popover(isPresented: $showList, arrowEdge: .bottom) { list }
        }
        .task(id: reloadKey) { await load() }
        if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(3)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(language.cardSearchService, text: $search).textFieldStyle(.roundedBorder)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            } else if filtered.isEmpty {
                Text(language.cardOptionsEmpty).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered) { option in
                            Button {
                                value = option.value
                                showList = false
                            } label: {
                                HStack {
                                    Image(systemName: "checkmark").opacity(option.value == value ? 1 : 0).frame(width: 14)
                                    Text(option.label).lineLimit(1)
                                    Spacer(minLength: 8)
                                    if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(option.value == value ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(10)
        .frame(width: 380)
    }

    private func load() async {
        guard missing.isEmpty, let source = param.source else { options = []; return }
        // Typing in a field this depends on shouldn't fire a request per keystroke.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        isLoading = true
        failure = nil
        do {
            if let loadOptions = context.loadOptions {
                options = try await loadOptions(source, params)
            } else {
                options = try await api.getCardOptions(service: context.service, source: source, profile: context.profile, region: context.region, params: params)
            }
        } catch is CancellationError {
        } catch {
            options = []
            failure = error.friendlyMessage
        }
        isLoading = false
    }
}
