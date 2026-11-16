import SwiftUI

/// Asks for a ResourcePage action's or create form's fields (G1) and submits
/// them. The fields are the dashboard card field model, so they are drawn by
/// `CardParamField` and checked with the same rules the sidecar applies
/// again (packages/api/src/infrastructure/form-fields.ts).
struct PageFormSheet: View {
    let service: String
    let form: PageAction
    /// Sends the values; a thrown error is shown in the sheet, success closes it.
    let submit: ([String: String]) async throws -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var values: [String: String] = [:]
    @State private var isRunning = false
    @State private var failure: String?

    private var language: AppLanguage { appState.language }
    private var fields: [CardTemplate.Param] { (form.form ?? []).filter { $0.isVisible(values) } }
    private var hasProblems: Bool { fields.contains { $0.problem(values[$0.key] ?? "", language: language) != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: form.systemImage)
                    .font(.title3)
                    .foregroundStyle(form.destructive ? Color.orange : Color.accentColor)
                    .frame(width: 30, height: 30)
                Text(form.confirmTitle).font(.title3.bold()).lineLimit(2)
            }

            Text(form.confirmMessage).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(fields) { field in
                        CardParamField(param: field, params: $values, context: context)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 360)

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if hasProblems {
                Text(language.formFixFields).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Label(language.formIrreversible, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                Spacer()
                SecondaryButton(language.formCancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                submitButton
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            // Defaults (computed per resource by the backend, e.g. a dated snapshot name).
            for field in form.form ?? [] where values[field.key] == nil {
                if let value = field.defaultValue { values[field.key] = value }
            }
        }
    }

    @ViewBuilder private var submitButton: some View {
        if form.destructive {
            WarningButton(form.title, systemImage: form.systemImage, isLoading: isRunning, isDisabled: isRunning || hasProblems) { run() }
        } else {
            ConfirmButton(form.title, systemImage: form.systemImage, isLoading: isRunning, isDisabled: isRunning || hasProblems) { run() }
        }
    }

    private var context: CardFormContext {
        let profile = appState.currentProfile
        let region = appState.currentRegion
        return CardFormContext(service: service, profile: profile, region: region, language: language) { [api, service] source, params in
            try await api.getPageOptions(service: service, source: source, profile: profile, region: region, params: params)
        }
    }

    private func run() {
        isRunning = true
        failure = nil
        // Only the fields that are shown are sent; the sidecar checks them again.
        let sent = Dictionary(uniqueKeysWithValues: fields.compactMap { f in values[f.key].map { (f.key, $0) } })
        Task {
            do {
                try await submit(sent)
                dismiss()
            } catch {
                failure = error.friendlyMessage
            }
            isRunning = false
        }
    }
}
