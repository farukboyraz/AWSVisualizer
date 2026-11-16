import SwiftUI

/// Live warning under a tag key/value form, in the app's language
/// (`TagRules` + `AppLanguage.validationMessage`). Shows nothing while the
/// input is fine.
struct TagInputWarning: View {
    let key: String
    let value: String

    @Environment(AppState.self) private var appState

    var body: some View {
        if let problem = TagRules.problem(key: key, value: value) {
            Label(appState.language.validationMessage(problem), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
