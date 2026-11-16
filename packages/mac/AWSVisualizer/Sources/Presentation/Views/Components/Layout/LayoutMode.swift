import SwiftUI

/// Settings → Layout (persisted as `layoutMode` in ~/.awsvisualizer):
/// how list + detail screens (tables → items, buckets → objects,
/// functions → details…) are arranged. `MasterDetailView` reads it.
enum LayoutMode: String, CaseIterable, Identifiable {
    /// List on the left, the selected item on the right (default).
    case sideBySide
    /// One page at a time: the list, or the selected item with Back.
    case singlePage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sideBySide: "Side by side"
        case .singlePage: "Single page"
        }
    }
}

private struct LayoutModeKey: EnvironmentKey {
    static let defaultValue: LayoutMode = .sideBySide
}

private struct WordWrapKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Injected at the app root from `AppState.layoutMode`.
    var layoutMode: LayoutMode {
        get { self[LayoutModeKey.self] }
        set { self[LayoutModeKey.self] = newValue }
    }

    /// Whether text / code viewers wrap long lines - Settings' default,
    /// flipped for the session by View → Word Wrap (`AppState.wordWrap`).
    var wordWrap: Bool {
        get { self[WordWrapKey.self] }
        set { self[WordWrapKey.self] = newValue }
    }
}
