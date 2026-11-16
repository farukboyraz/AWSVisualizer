import SwiftUI

/// The current screen's name, shown in the window's title bar (the header
/// above everything) instead of as a heading inside the screen. A screen
/// declares it with `ScreenTitle("SNS Topics")` (or `.screenTitle(_:)`)
/// anywhere in its view tree; `MainView` reads it and sets the window
/// title, falling back to the service's catalog name.
struct ScreenTitleKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        value = value ?? nextValue()
    }
}

extension View {
    func screenTitle(_ title: String) -> some View {
        preference(key: ScreenTitleKey.self, value: title)
    }
}

/// Zero-size marker - drop it where the old in-screen heading was, so the
/// row keeps its right-hand buttons exactly where they were.
struct ScreenTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .screenTitle(title)
    }
}
