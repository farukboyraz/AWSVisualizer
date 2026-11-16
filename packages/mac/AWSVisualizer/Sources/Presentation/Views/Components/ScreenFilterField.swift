import SwiftUI

/// The filter field above a service's list. When a dashboard card's Run
/// opened this service with a search (e.g. a resource-count card's "name
/// contains"), the field starts with it - so the list shows the same
/// resources the card counted.
struct ScreenFilterField: View {
    @Binding var text: String
    var prompt: String?

    @Environment(AppState.self) private var appState

    var body: some View {
        TextField(prompt ?? appState.language.filterPrompt, text: $text)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .onAppear {
                if let pending = appState.takePendingFilter() { text = pending }
            }
            .onChange(of: appState.pendingFilter?.text) { _, _ in
                if let pending = appState.takePendingFilter() { text = pending }
            }
    }
}

extension Array {
    /// The items whose text contains every word of `query` (any order, any
    /// field, case-insensitive) - "web running" finds running instances
    /// whose name has "web". Empty query = everything.
    func matching(_ query: String) -> [Element] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return self }
        return filter { item in
            let text = SearchableText.of(item)
            return words.allSatisfy { text.contains($0) }
        }
    }
}

/// Every text (and number) field of a value, lowercased, read by
/// reflection - so any list can be filtered without each type listing its
/// own fields. Goes two levels into nested values (tags, attachments…).
enum SearchableText {
    static func of(_ value: Any) -> String {
        var parts: [String] = []
        collect(value, depth: 0, into: &parts)
        return parts.joined(separator: " ").lowercased()
    }

    private static func collect(_ value: Any, depth: Int, into parts: inout [String]) {
        switch value {
        case let s as String: parts.append(s); return
        case let s as Substring: parts.append(String(s)); return
        case let n as Int: parts.append(String(n)); return
        case let d as Double: parts.append(String(d)); return
        case let b as Bool: parts.append(b ? "true" : "false"); return
        case is Date: return
        default: break
        }
        guard depth < 3 else { return }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let wrapped = mirror.children.first?.value { collect(wrapped, depth: depth, into: &parts) }
            return
        }
        for child in mirror.children { collect(child.value, depth: depth + 1, into: &parts) }
    }
}
