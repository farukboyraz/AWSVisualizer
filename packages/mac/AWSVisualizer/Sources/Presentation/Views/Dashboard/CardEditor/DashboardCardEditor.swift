import SwiftUI

/// Add / edit a dashboard card, in three steps on one page:
/// 1. **Service** - the user's selected services first, then the rest of the
///    catalog, plus "Note".
/// 2. **Card type** - what the sidecar offers for that service (its own
///    templates first, then resource count / shortcuts every service has).
/// 3. **Settings** - the template's parameters as a form: dropdowns filled
///    from AWS (bucket → folder, table → query builder, repository →
///    branches), and the run-time inputs of an action.
/// Underneath, a preview of the selected data loads as the form is filled.
struct DashboardCardEditor: View {
    let isNew: Bool
    let language: AppLanguage
    let profiles: [String]
    var onSave: (DashboardCard) -> Void
    var onCancel: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var draft: DashboardCard
    @State private var templates: [CardTemplate] = []
    @State private var templatesLoading = false
    @State private var templatesError: String?
    @State private var choosingService: Bool
    @State private var preview: CardPreviewView.Phase = .waiting
    @State private var previewNonce = 0

    init(card: DashboardCard?, language: AppLanguage, profiles: [String], defaultProfile: String, defaultRegion: String, onSave: @escaping (DashboardCard) -> Void, onCancel: @escaping () -> Void) {
        isNew = card == nil
        self.language = language
        self.profiles = profiles
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: card ?? DashboardCard(profiles: [defaultProfile]))
        _choosingService = State(initialValue: card == nil)
    }

    private var template: CardTemplate? { templates.first { $0.id == draft.template } }
    private var context: CardFormContext {
        let c = draft.context(currentProfile: appState.currentProfile, currentRegion: appState.currentRegion)
        return CardFormContext(service: draft.service, profile: c.profile, region: c.region, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isNew ? language.cardNew : language.cardEditTitle).font(.title2.bold())
                Spacer()
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    serviceStep
                    if !draft.service.isEmpty && !choosingService { typeStep }
                    if let template, !choosingService {
                        settingsStep(template)
                        if template.kind == .metric || template.kind == .action {
                            CardPreviewView(state: template.hasPreview == true ? preview : .unavailable, language: language) { previewNonce += 1 }
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            footer.padding(16)
        }
        .frame(width: 780, height: 800)
        .task(id: draft.service) { await loadTemplates() }
        .task(id: previewKey) { await loadPreview() }
    }

    // MARK: 1. Service

    /// No service yet: the picker inline. Chosen: a large button that
    /// opens the same picker in a popover.
    @ViewBuilder private var serviceStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language.cardStepService).font(.headline)
            if choosingService {
                CardServicePicker(selection: draft.service, language: language) { chooseService($0) }
            } else {
                CardServiceButton(selection: draft.service, language: language) { chooseService($0) }
            }
        }
    }

    private func chooseService(_ id: String) {
        if draft.service != id {
            draft.service = id
            draft.template = ""
            draft.params = [:]
            templates = []
        }
        choosingService = false
    }

    // MARK: 2. Card type

    @ViewBuilder private var typeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language.cardStepType).font(.headline)
            if templatesLoading {
                HStack { ProgressView().controlSize(.small); Text(language.cardLoadingTypes).foregroundStyle(.secondary) }
            } else if let templatesError {
                Label(templatesError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(templates) { tpl in
                        Button { chooseTemplate(tpl) } label: { templateRow(tpl) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func templateRow(_ tpl: CardTemplate) -> some View {
        let selected = draft.template == tpl.id
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: tpl.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(kindColor(tpl.kind))
                .frame(width: 30, height: 30)
                .background(kindColor(tpl.kind).opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tpl.name(language)).font(.callout.weight(.semibold))
                    Text(language.cardKindLabel(tpl.kind))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(kindColor(tpl.kind).opacity(0.15), in: Capsule())
                        .foregroundStyle(kindColor(tpl.kind))
                }
                Text(tpl.description(language)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
    }

    func kindColor(_ kind: CardTemplate.Kind) -> Color { DashboardCustomCardView.kindColor(kind) }

    private func chooseTemplate(_ tpl: CardTemplate) {
        guard draft.template != tpl.id else { return }
        let previousName = template?.name(language)
        draft.template = tpl.id
        draft.kind = tpl.kind
        draft.icon = tpl.icon
        var params: [String: String] = [:]
        for p in tpl.params { params[p.key] = draft.params[p.key] ?? p.defaultValue ?? "" }
        draft.params = params.filter { !$0.value.isEmpty }
        if draft.title.isEmpty || draft.title == previousName { draft.title = tpl.name(language) }
    }

    private func loadTemplates() async {
        guard !draft.service.isEmpty else { return }
        templatesLoading = true
        templatesError = nil
        do {
            templates = try await api.getCardTemplates(service: draft.service)
        } catch {
            templatesError = error.friendlyMessage
        }
        templatesLoading = false
    }

    // MARK: 3. Settings

    private func settingsStep(_ tpl: CardTemplate) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language.cardStepSettings).font(.headline)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) { Text(language.cardTitleField).font(.callout.weight(.medium)); Text("*").foregroundStyle(.red) }
                TextField("", text: $draft.title).textFieldStyle(.roundedBorder)
            }
            profileScope(tpl)
            ForEach(tpl.cardParams.filter { $0.isVisible(draft.params) }) { param in
                CardParamField(param: param, params: $draft.params, context: context)
            }
            if !tpl.runParams.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label(language.cardRunParams, systemImage: "questionmark.bubble").font(.callout.weight(.semibold))
                    Text(language.cardRunParamsHint).font(.caption).foregroundStyle(.secondary)
                    ForEach(tpl.runParams) { param in
                        CardParamField(param: param, params: $draft.params, context: context)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    /// Which profile's dashboard the card is on - or every profile's.
    /// Which profiles' dashboards show the card (one, several or all), and
    /// the region it reads (or the one in use).
    private func profileScope(_ tpl: CardTemplate) -> some View {
        let usesAWS = tpl.kind == .metric || tpl.kind == .action
        return VStack(alignment: .leading, spacing: 10) {
            Text(language.cardProfiles).font(.callout.weight(.medium))
            Toggle(isOn: $draft.allProfiles) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.cardAllProfiles)
                    Text(usesAWS ? language.cardAllProfilesHintAWS : language.cardAllProfilesHint).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            if !draft.allProfiles {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], alignment: .leading, spacing: 6) {
                    ForEach(profiles, id: \.self) { name in
                        Toggle(isOn: Binding(
                            get: { draft.profiles.contains(name) },
                            set: { on in
                                if on { if !draft.profiles.contains(name) { draft.profiles.append(name) } } else { draft.profiles.removeAll { $0 == name } }
                            }
                        )) {
                            HStack(spacing: 4) {
                                Text(name).lineLimit(1)
                                if name == appState.currentProfile { Text(language.cardCurrent).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 18)
                Text(language.cardProfilesHint).font(.caption).foregroundStyle(.secondary)
            }
            if usesAWS {
                HStack {
                    Text(language.cardRegion)
                    Picker("", selection: $draft.region) {
                        Text(language.cardCurrentRegion).tag("")
                        Divider()
                        ForEach(AWSRegion.all) { Text("\($0.code) - \($0.name)").tag($0.code) }
                    }
                    .labelsHidden()
                    .frame(width: 300)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The profile / region the preview runs with (an "all profiles" card: the ones in use).
    private var previewContext: (profile: String, region: String) {
        draft.context(currentProfile: appState.currentProfile, currentRegion: appState.currentRegion)
    }

    // MARK: Preview

    /// Card-scope params only - typing a run-time default doesn't reload the data.
    private var previewKey: String {
        guard let tpl = template else { return "none" }
        let keys = Set(tpl.cardParams.map(\.key))
        let params = draft.params.filter { keys.contains($0.key) }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return ([draft.service, draft.template, previewContext.profile, previewContext.region, "\(previewNonce)"] + params).joined(separator: "|")
    }

    private func loadPreview() async {
        guard let tpl = template, tpl.hasPreview == true else { preview = .unavailable; return }
        guard cardProblems(tpl).isEmpty else { preview = .waiting; return }
        try? await Task.sleep(nanoseconds: 700_000_000)
        if Task.isCancelled { return }
        preview = .loading
        do {
            let keys = Set(tpl.cardParams.map(\.key))
            let result = try await api.getCardPreview(service: draft.service, template: draft.template, profile: previewContext.profile, region: previewContext.region, params: draft.params.filter { keys.contains($0.key) })
            preview = .loaded(result)
        } catch is CancellationError {
        } catch {
            preview = .failed(error.friendlyMessage)
        }
    }

    // MARK: Checks / footer

    /// What stops saving (card-scope params; run-time ones may stay empty).
    private func cardProblems(_ tpl: CardTemplate) -> [String] {
        var problems: [String] = []
        for param in tpl.cardParams where param.isVisible(draft.params) {
            let value = draft.params[param.key] ?? ""
            if param.type == .dynamoQuery || param.type == .dynamoSearch {
                if param.isRequired, let problem = DynamoSearchBuilderField.problem(value, language: language) { problems.append(problem) }
            } else if let problem = param.problem(value, language: language) {
                problems.append(problem)
            }
        }
        for param in tpl.runParams where !(draft.params[param.key] ?? "").isEmpty {
            if let problem = param.problem(draft.params[param.key] ?? "", language: language), !problem.isEmpty, (draft.params[param.key] ?? "").contains("{") == false { problems.append(problem) }
        }
        return problems
    }

    private var saveProblem: String? {
        guard let tpl = template else { return language.cardChooseFirst }
        if draft.title.trimmingCharacters(in: .whitespaces).isEmpty { return language.cardInvalidTitle }
        if !draft.allProfiles && draft.profiles.isEmpty { return language.cardChooseProfiles }
        return cardProblems(tpl).first
    }

    private var footer: some View {
        HStack {
            if let problem = saveProblem {
                Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            SecondaryButton(language.cardCancel, action: onCancel).keyboardShortcut(.cancelAction)
            SaveButton(language.cardSave, isDisabled: saveProblem != nil) {
                var card = draft
                card.title = card.title.trimmingCharacters(in: .whitespaces)
                if let tpl = template {
                    let keys = Set(tpl.params.map(\.key))
                    card.params = card.params.filter { keys.contains($0.key) && !$0.value.isEmpty }
                }
                onSave(card)
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}
