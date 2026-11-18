import SwiftUI

/// What the sidebar's right-click menu can do with a service.
enum SidebarServiceAction: Hashable {
    case open
    case openInNewTab
    case addFavorite
    case removeFavorite
    case addCard
    case copyName
    case removeFromSidebar
}

/// The sidebar's right-click menu for a service (expanded rows and the
/// collapsed icon strip). Data-driven: `sections` lists the items and the
/// sidebar runs the picked action, so a new item is one case above plus
/// one line in `sections`. Destructive items ask first (in the sidebar).
struct SidebarServiceMenu: View {
    struct Context {
        let entry: AWSServiceCatalogEntry
        let isDashboard: Bool
        let isFavorite: Bool
        let canOpenInNewTab: Bool
        let canAddCard: Bool
        let canRemoveFromSidebar: Bool
        let language: AppLanguage
    }

    struct Item: Identifiable {
        let action: SidebarServiceAction
        let title: String
        let systemImage: String
        var isDisabled = false
        var help: String?
        var isDestructive = false
        var id: SidebarServiceAction { action }
    }

    let context: Context
    let perform: (SidebarServiceAction) -> Void

    static func sections(_ c: Context) -> [[Item]] {
        let l = c.language
        var sections: [[Item]] = [[
            Item(action: .open, title: l.sidebarOpen, systemImage: "arrow.right.circle"),
            Item(action: .openInNewTab, title: l.sidebarOpenNewTab, systemImage: "plus.square.on.square", isDisabled: !c.canOpenInNewTab),
        ]]
        guard !c.isDashboard else { return sections }
        sections.append([
            c.isFavorite
                ? Item(action: .removeFavorite, title: l.sidebarRemoveFavorite, systemImage: "star.slash")
                : Item(action: .addFavorite, title: l.sidebarAddFavorite, systemImage: "star"),
            Item(action: .addCard, title: l.sidebarAddCard, systemImage: "rectangle.stack.badge.plus",
                 isDisabled: !c.canAddCard, help: c.canAddCard ? nil : l.sidebarCardLimit),
        ])
        sections.append([
            Item(action: .copyName, title: l.sidebarCopyName, systemImage: "doc.on.doc"),
        ])
        sections.append([
            Item(action: .removeFromSidebar, title: l.sidebarHide, systemImage: "eye.slash",
                 isDisabled: !c.canRemoveFromSidebar, help: c.canRemoveFromSidebar ? nil : l.sidebarLastService, isDestructive: true),
        ])
        return sections
    }

    var body: some View {
        let sections = Self.sections(context)
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            if index > 0 { Divider() }
            ForEach(section) { item in
                Button(role: item.isDestructive ? .destructive : nil) {
                    perform(item.action)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
                .disabled(item.isDisabled)
                .help(item.help ?? "")
            }
        }
    }
}
