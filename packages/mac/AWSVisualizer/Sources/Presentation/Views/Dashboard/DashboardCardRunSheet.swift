import SwiftUI

/// Runs an action card: asks its run-time inputs (prefilled from the card),
/// says exactly what will happen, and only then calls the sidecar with
/// `confirm: true`. The result (and where to see it) stays on the card.
struct DashboardCardRunSheet: View {
    let card: DashboardCard
    let language: AppLanguage
    /// The profile / region it runs with (an "all profiles" card: the ones in use).
    let profile: String
    let region: String
    var onFinished: (DashboardCached<CardActionResult>) -> Void
    var onOpen: (CardLinkTarget) -> Void
    var onClose: () -> Void

    @Environment(\.apiService) private var api

    @State private var template: CardTemplate?
    @State private var inputs: [String: String] = [:]
    @State private var loadError: String?
    @State private var isRunning = false
    @State private var runError: String?
    @State private var result: DashboardCached<CardActionResult>?
    /// Fields being filled from AWS (e.g. the last commit message).
    @State private var prefilling: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: card.icon)
                    .foregroundStyle(DashboardCustomCardView.kindColor(.action))
                    .frame(width: 30, height: 30)
                    .background(DashboardCustomCardView.kindColor(.action).opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.title3.bold())
                    Text("\(language.cardRunTitle) · \(profile) · \(region)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result {
                Label(result.data.message(language), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if let link = result.data.link {
                        OpenButton(language.cardOpenResult) { onOpen(link); onClose() }
                    }
                    CloseButton(language.dashClose, action: onClose).keyboardShortcut(.defaultAction)
                }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                HStack { Spacer(); CloseButton(language.dashClose, action: onClose) }
            } else if let template {
                ForEach(template.runParams) { param in
                    CardParamField(param: param, params: $inputs, context: CardFormContext(service: card.service, profile: profile, region: region, language: language))
                        .overlay(alignment: .topTrailing) {
                            if prefilling.contains(param.key) {
                                Label(language.cardPrefilling, systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                }
                if let confirm = template.confirm {
                    Text(fill(confirm(language)))
                        .font(.callout.weight(.medium))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
                Label(language.cardRunWarning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                if let runError {
                    Label(runError, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if isRunning { ProgressView().controlSize(.small); Text(language.cardRunning).foregroundStyle(.secondary) }
                    Spacer()
                    SecondaryButton(language.cardCancel, isDisabled: isRunning, action: onClose).keyboardShortcut(.cancelAction)
                    RunButton(language.cardRunConfirm, isLoading: isRunning, isDisabled: isRunning || !prefilling.isEmpty || problem(template) != nil) { Task { await run(template) } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task { await loadTemplate() }
    }

    /// {repository}, {source}… from the card and this run's inputs; {date} = today.
    private func fill(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "{date}", with: Date().formatted(.iso8601.year().month().day()))
        for (key, value) in card.params.merging(inputs, uniquingKeysWith: { $1 }) {
            out = out.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return out
    }

    private func problem(_ template: CardTemplate) -> String? {
        for param in template.runParams {
            if let problem = param.problem(inputs[param.key] ?? "", language: language) { return problem }
        }
        return nil
    }

    private func loadTemplate() async {
        do {
            guard let found = try await api.getCardTemplates(service: card.service).first(where: { $0.id == card.template }) else {
                loadError = language.cardChooseFirst
                return
            }
            var values: [String: String] = [:]
            for param in found.runParams { values[param.key] = fill(card.params[param.key] ?? param.defaultValue ?? "") }
            inputs = values
            template = found
            await prefill(found)
        } catch {
            loadError = error.friendlyMessage
        }
    }

    /// Empty run fields with a prefill source get their value from AWS -
    /// e.g. a pull request's title / description from the source branch's
    /// last commit message. The user can still change them before running.
    private func prefill(_ template: CardTemplate) async {
        let empty = template.runParams.filter { $0.prefill != nil && (inputs[$0.key] ?? "").isEmpty }
        guard !empty.isEmpty else { return }
        prefilling = Set(empty.map(\.key))
        var cache: [String: [CardOption]] = [:]
        for param in empty {
            guard let prefill = param.prefill else { continue }
            if cache[prefill.source] == nil {
                cache[prefill.source] = (try? await api.getCardOptions(service: card.service, source: prefill.source, profile: profile, region: region, params: card.params)) ?? []
            }
            if let first = cache[prefill.source]?.first, (inputs[param.key] ?? "").isEmpty {
                inputs[param.key] = prefill.use == "detail" ? (first.detail ?? "") : first.value
            }
            prefilling.remove(param.key)
        }
        prefilling = []
    }

    private func run(_ template: CardTemplate) async {
        isRunning = true
        runError = nil
        do {
            let done = try await api.runCard(id: card.id, params: inputs, profile: profile, region: region)
            result = done
            onFinished(done)
        } catch {
            runError = error.friendlyMessage
        }
        isRunning = false
    }
}
