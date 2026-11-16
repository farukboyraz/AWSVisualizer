import SwiftUI

/// The list of the user's cards with add / edit / delete and drag-and-drop
/// order - shared by Settings › Display › Dashboard and the dashboard's
/// "Edit cards" window. Edits go through `cards`; the owner decides when
/// they are saved (the Settings draft, or right away on the dashboard).
struct DashboardCardList: View {
    @Binding var cards: [DashboardCard]
    let language: AppLanguage

    @Environment(AppState.self) private var appState

    @State private var editing: Editing?
    @State private var dropTarget: String?

    private struct Editing: Identifiable {
        let id = UUID()
        let card: DashboardCard?
    }

    private var profileNames: [String] {
        let names = appState.profiles.map(\.name)
        return names.isEmpty ? [appState.currentProfile] : names
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language.cardsTitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
                NewButton(compactSize: 24, isDisabled: cards.count >= DashboardPrefs.maxCards, help: cards.count >= DashboardPrefs.maxCards ? language.cardLimit : language.cardsAdd) {
                    editing = Editing(card: nil)
                }
            }
            if cards.isEmpty {
                Text(language.cardsEmpty).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 4) {
                    ForEach(cards) { card in row(card) }
                }
                Text(language.cardsDragHint).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .sheet(item: $editing) { item in
            DashboardCardEditor(
                card: item.card,
                language: language,
                profiles: profileNames,
                defaultProfile: appState.currentProfile,
                defaultRegion: appState.currentRegion,
                onSave: { card in
                    editing = nil
                    if let index = cards.firstIndex(where: { $0.id == card.id }) { cards[index] = card } else { cards.append(card) }
                },
                onCancel: { editing = nil }
            )
        }
    }

    private func row(_ card: DashboardCard) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Image(systemName: card.icon).foregroundStyle(DashboardCustomCardView.kindColor(card.kind)).frame(width: 18)
            Text(card.title).lineLimit(1)
            Text(language.cardKindLabel(card.kind)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            // Which dashboards it is on.
            Label(scope(card), systemImage: card.allProfiles ? "person.3" : card.profiles.count > 1 ? "person.2" : "person.crop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(card.allProfiles ? language.cardScopeAll : card.profiles.joined(separator: ", "))
            EditButton(compactSize: 20, help: language.cardEdit) { editing = Editing(card: card) }
            DeleteButton(compactSize: 20, help: language.cardDelete) { cards.removeAll { $0.id == card.id } }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(dropTarget == card.id ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 7))
        .draggable(card.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let dragged = ids.first, dragged != card.id,
                  let from = cards.firstIndex(where: { $0.id == dragged }),
                  let to = cards.firstIndex(where: { $0.id == card.id }) else { return false }
            let moved = cards.remove(at: from)
            cards.insert(moved, at: to)
            return true
        } isTargeted: { dropTarget = $0 ? card.id : (dropTarget == card.id ? nil : dropTarget) }
    }

    private func scope(_ card: DashboardCard) -> String {
        if card.allProfiles { return language.cardScopeAll }
        if card.profiles.count > 2 { return language.cardScopeCount(card.profiles.count) }
        return card.profiles.joined(separator: ", ")
    }
}

/// The dashboard's "Edit cards" window: the shared list, saved right away.
struct DashboardCardManagerSheet: View {
    let language: AppLanguage
    @Binding var cards: [DashboardCard]
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(language.cardsEditTitle).font(.title2.bold())
                Spacer()
                CloseButton(language.dashClose, action: onClose).keyboardShortcut(.cancelAction)
            }
            ScrollView { DashboardCardList(cards: $cards, language: language) }
        }
        .padding(22)
        .frame(width: 640, height: 520)
    }
}
