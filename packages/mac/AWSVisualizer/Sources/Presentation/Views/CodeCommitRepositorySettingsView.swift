import SwiftUI

/// Mirrors the "Settings" page of a repository in the AWS CodeCommit
/// console: general info (name, description, default branch) and tags,
/// each independently editable and saved with its own AWS API call -
/// same per-field save pattern as the app's own Settings screen.
struct CodeCommitRepositorySettingsView: View {
    let repositoryName: String
    let detail: CodeCommitRepositoryDetail
    var onUpdated: (CodeCommitRepositoryDetail) -> Void
    var onRenamed: () -> Void
    var onDeleted: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var nameField = ""
    @State private var descriptionField = ""
    @State private var defaultBranchField = ""
    @State private var branchesState: LoadState<[CodeCommitBranch]> = .loading

    @State private var isSavingName = false
    @State private var isSavingDescription = false
    @State private var isSavingBranch = false
    @State private var nameError: String?
    @State private var descriptionError: String?
    @State private var branchError: String?
    @State private var nameSaved = false
    @State private var descriptionSaved = false
    @State private var branchSaved = false

    @State private var newTagKey = ""
    @State private var newTagValue = ""
    @State private var isAddingTag = false
    @State private var tagError: String?
    @State private var removingTagKey: String?

    @State private var isDeleting = false
    @State private var deleteError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                generalSection
                Divider()
                tagsSection
                Divider()
                CodeCommitTriggersSection(repositoryName: repositoryName)
                Divider()
                readOnlySection
                Divider()
                dangerZoneSection
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: detail.repositoryName) {
            resetFields()
            await loadBranches()
        }
    }

    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Danger zone")
                .font(.headline)
                .foregroundStyle(.red)
            DeleteButton("Delete Repository", isLoading: isDeleting) {
                Task { await deleteRepository() }
            }
            if let deleteError {
                Text(deleteError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func deleteRepository() async {
        isDeleting = true
        deleteError = nil
        do {
            try await api.deleteCodeCommitRepository(profile: appState.currentProfile, region: appState.currentRegion, repositoryName: detail.repositoryName)
            onDeleted()
        } catch {
            deleteError = error.friendlyMessage
        }
        isDeleting = false
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General")
                .font(.headline)

            SettingsFieldRow(label: "Repository name", isSaving: isSavingName, error: nameError, saved: nameSaved, save: { Task { await saveName() } }) {
                TextField("Repository name", text: $nameField)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsFieldRow(label: "Description", isSaving: isSavingDescription, error: descriptionError, saved: descriptionSaved, save: { Task { await saveDescription() } }) {
                TextField("Description", text: $descriptionField)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsFieldRow(label: "Default branch", isSaving: isSavingBranch, error: branchError, saved: branchSaved, save: { Task { await saveDefaultBranch() } }) {
                if case .loaded(let branches) = branchesState, !branches.isEmpty {
                    Picker("", selection: $defaultBranchField) {
                        ForEach(branches) { b in Text(b.name).tag(b.name) }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                } else {
                    TextField("Default branch", text: $defaultBranchField)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            }
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appState.language.tagsTitle)
                .font(.headline)

            if detail.tags.isEmpty {
                Text(appState.language.noTagsMessage(noun: "repository"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(detail.tags) { tag in
                        HStack {
                            Text(tag.key)
                                .font(.caption.monospaced().bold())
                            Text(tag.value)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            DeleteButton(compactSize: 20, isLoading: removingTagKey == tag.key, isDisabled: removingTagKey != nil, help: appState.language.removeTagHelp) {
                                Task { await removeTag(tag.key) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField(appState.language.tagKeyPlaceholder, text: $newTagKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                TextField(appState.language.tagValuePlaceholder, text: $newTagValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                NewButton(appState.language.addTagButton, isLoading: isAddingTag, isDisabled: !TagRules.canAdd(key: newTagKey, value: newTagValue)) {
                    Task { await addTag() }
                }
            }
            TagInputWarning(key: newTagKey, value: newTagValue)

            if let tagError {
                Text(tagError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var readOnlySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.headline)

            DetailField("Repository ID", detail.repositoryId)
            if let arn = detail.arn { DetailField("ARN", arn) }
            if let cloneUrl = detail.cloneUrlHttp { DetailField("Clone URL (HTTPS)", cloneUrl) }
            if let created = detail.creationDate { DetailField("Created", Formatters.formatGitDate(created)) }
            if let modified = detail.lastModifiedDate { DetailField("Last modified", Formatters.formatGitDate(modified)) }
        }
    }


    private func resetFields() {
        nameField = detail.repositoryName
        descriptionField = detail.description ?? ""
        defaultBranchField = detail.defaultBranch ?? ""
        nameError = nil
        descriptionError = nil
        branchError = nil
        tagError = nil
    }

    private func loadBranches() async {
        branchesState = .loading
        do {
            let branches = try await api.getCodeCommitBranches(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName)
            branchesState = branches.isEmpty ? .empty : .loaded(branches)
        } catch {
            branchesState = .failed(error.friendlyMessage)
        }
    }

    private func saveName() async {
        let trimmed = nameField.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != detail.repositoryName else { return }
        isSavingName = true
        nameError = nil
        nameSaved = false
        do {
            _ = try await api.updateCodeCommitRepositoryName(profile: appState.currentProfile, region: appState.currentRegion, oldName: detail.repositoryName, newName: trimmed)
            onRenamed()
        } catch {
            nameError = error.friendlyMessage
        }
        isSavingName = false
    }

    private func saveDescription() async {
        isSavingDescription = true
        descriptionError = nil
        descriptionSaved = false
        do {
            let updated = try await api.updateCodeCommitRepositoryDescription(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, description: descriptionField)
            onUpdated(updated)
            descriptionSaved = true
        } catch {
            descriptionError = error.friendlyMessage
        }
        isSavingDescription = false
    }

    private func saveDefaultBranch() async {
        let trimmed = defaultBranchField.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSavingBranch = true
        branchError = nil
        branchSaved = false
        do {
            let updated = try await api.updateCodeCommitDefaultBranch(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, defaultBranchName: trimmed)
            onUpdated(updated)
            branchSaved = true
        } catch {
            branchError = error.friendlyMessage
        }
        isSavingBranch = false
    }

    private func addTag() async {
        let key = newTagKey.trimmingCharacters(in: .whitespaces)
        guard TagRules.canAdd(key: newTagKey, value: newTagValue) else { return }
        isAddingTag = true
        tagError = nil
        do {
            let updated = try await api.addCodeCommitRepositoryTag(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, key: key, value: newTagValue)
            onUpdated(updated)
            newTagKey = ""
            newTagValue = ""
        } catch {
            tagError = error.friendlyMessage
        }
        isAddingTag = false
    }

    private func removeTag(_ key: String) async {
        removingTagKey = key
        tagError = nil
        do {
            let updated = try await api.removeCodeCommitRepositoryTag(profile: appState.currentProfile, region: appState.currentRegion, name: repositoryName, key: key)
            onUpdated(updated)
        } catch {
            tagError = error.friendlyMessage
        }
        removingTagKey = nil
    }
}

/// Reusable "label + Save button + field + error" row for simple per-field
/// settings forms - used by CodeCommit repo settings, SQS queue
/// configuration, and KMS key details.
struct SettingsFieldRow<Field: View>: View {
    let label: String
    let isSaving: Bool
    let error: String?
    let saved: Bool
    let save: () -> Void
    @ViewBuilder let field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                SaveButton("Save", isLoading: isSaving) {
                    save()
                }
                if saved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            field
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private let triggerEventOptions = ["all", "createReference", "updateReference", "deleteReference"]

/// Mirrors the console's repo Settings → Triggers page - SNS/Lambda
/// notifications on push/branch events, used for CI/CD integration.
/// `PutRepositoryTriggers` always replaces the *entire* trigger set (it's
/// not additive), so every add/remove here re-saves the full array.
struct CodeCommitTriggersSection: View {
    let repositoryName: String

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var triggersState: LoadState<[CodeCommitRepositoryTrigger]> = .loading
    @State private var newName = ""
    @State private var newDestinationArn = ""
    @State private var newBranches = ""
    @State private var newEvents: Set<String> = ["all"]
    @State private var isSaving = false
    @State private var testResults: [String]?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Triggers")
                .font(.headline)
            Text("Notifies an SNS topic or Lambda function when this repository is pushed to.")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch triggersState {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
            case .empty, .loaded:
                let triggers = triggersState.loadedValue ?? []
                if triggers.isEmpty {
                    Text("No triggers configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(triggers) { trigger in
                            triggerRow(trigger, all: triggers)
                        }
                    }
                }
            }

            addTriggerForm

            if let testResults {
                if testResults.isEmpty {
                    Label("Test succeeded for all triggers.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(testResults, id: \.self) { line in
                            Text(line).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: repositoryName) {
            await load()
        }
    }

    private func triggerRow(_ trigger: CodeCommitRepositoryTrigger, all: [CodeCommitRepositoryTrigger]) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trigger.name).font(.caption.bold())
                Text(trigger.destinationArn).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(trigger.events.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                Task { await test(trigger) }
            } label: {
                Text("Test")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            DeleteButton(compactSize: 20, isDisabled: isSaving, help: "Remove Trigger") {
                Task { await remove(trigger, all: all) }
            }
        }
        .padding(.vertical, 2)
    }

    private var addTriggerForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Trigger name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                TextField("arn:aws:sns:... or arn:aws:lambda:...", text: $newDestinationArn)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
            HStack(spacing: 8) {
                TextField("Branches (comma-separated, empty = all)", text: $newBranches)
                    .textFieldStyle(.roundedBorder)
                NewButton("Add Trigger", isLoading: isSaving, isDisabled: newName.trimmingCharacters(in: .whitespaces).isEmpty || newDestinationArn.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await add() }
                }
            }
            HStack(spacing: 12) {
                ForEach(triggerEventOptions, id: \.self) { event in
                    Toggle(event, isOn: Binding(
                        get: { newEvents.contains(event) },
                        set: { isOn in
                            if event == "all" {
                                newEvents = isOn ? ["all"] : []
                            } else {
                                newEvents.remove("all")
                                if isOn { newEvents.insert(event) } else { newEvents.remove(event) }
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }
        }
    }

    private func load() async {
        triggersState = .loading
        do {
            let triggers = try await api.getCodeCommitTriggers(profile: appState.currentProfile, region: appState.currentRegion, repositoryName: repositoryName)
            triggersState = triggers.isEmpty ? .empty : .loaded(triggers)
        } catch {
            triggersState = .failed(error.friendlyMessage)
        }
    }

    private func add() async {
        let existing = triggersState.loadedValue ?? []
        let branches = newBranches.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let trigger = CodeCommitRepositoryTrigger(
            name: newName.trimmingCharacters(in: .whitespaces),
            destinationArn: newDestinationArn.trimmingCharacters(in: .whitespaces),
            customData: nil,
            branches: branches,
            events: Array(newEvents)
        )
        await save(existing + [trigger])
        if error == nil {
            newName = ""
            newDestinationArn = ""
            newBranches = ""
            newEvents = ["all"]
        }
    }

    private func remove(_ trigger: CodeCommitRepositoryTrigger, all: [CodeCommitRepositoryTrigger]) async {
        await save(all.filter { $0.name != trigger.name })
    }

    private func save(_ triggers: [CodeCommitRepositoryTrigger]) async {
        isSaving = true
        error = nil
        do {
            try await api.setCodeCommitTriggers(profile: appState.currentProfile, region: appState.currentRegion, repositoryName: repositoryName, triggers: triggers)
            triggersState = triggers.isEmpty ? .empty : .loaded(triggers)
        } catch {
            self.error = error.friendlyMessage
        }
        isSaving = false
    }

    private func test(_ trigger: CodeCommitRepositoryTrigger) async {
        testResults = nil
        error = nil
        do {
            testResults = try await api.testCodeCommitTriggers(profile: appState.currentProfile, region: appState.currentRegion, repositoryName: repositoryName, triggers: [trigger])
        } catch {
            self.error = error.friendlyMessage
        }
    }
}

private extension LoadState {
    /// Read-only convenience for a screen that treats `.loaded`/`.empty` the
    /// same way (an array that happens to be empty) but still wants
    /// `.loading`/`.failed` handled separately above.
    var loadedValue: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}
