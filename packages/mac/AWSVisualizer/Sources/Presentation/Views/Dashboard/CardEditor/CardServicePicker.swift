import SwiftUI

/// Picks the service of a dashboard card:
/// - **Favorites** first, as large tiles;
/// - then **your services** (the ones selected in Settings), medium tiles,
///   with "Note" at the front;
/// - then an underlined "Show other services" link that reveals the rest
///   of the catalog as small tiles.
/// Heights follow the content (no fixed box). A search field filters every
/// group, and the others open by themselves while searching or when the
/// current choice is one of them.
struct CardServicePicker: View {
    let selection: String
    let language: AppLanguage
    var onSelect: (String) -> Void

    @Environment(AppState.self) private var appState

    @State private var search = ""
    @State private var showOthers = false

    private var implemented: [AWSServiceCatalogEntry] { appState.serviceCatalog.filter(\.implemented) }
    private var favorites: [AWSServiceCatalogEntry] { implemented.filter { appState.favoriteServiceIDs.contains($0.id) } }
    private var yours: [AWSServiceCatalogEntry] {
        let favs = Set(favorites.map(\.id))
        return appState.selectedCatalogEntries.filter { $0.implemented && !favs.contains($0.id) }
    }
    private var others: [AWSServiceCatalogEntry] {
        let shown = Set(favorites.map(\.id) + yours.map(\.id))
        return implemented.filter { !shown.contains($0.id) }
    }
    private var note: AWSServiceCatalogEntry {
        AWSServiceCatalogEntry(id: "note", name: language.cardNoteService, category: "", icon: "note.text", implemented: true)
    }
    private var othersVisible: Bool { showOthers || !search.isEmpty || others.contains { $0.id == selection } }

    private func matches(_ e: AWSServiceCatalogEntry) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || e.name.lowercased().contains(needle) || e.id.contains(needle) || e.category.lowercased().contains(needle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(language.cardSearchService, text: $search).textFieldStyle(.roundedBorder)

            let favs = favorites.filter(matches)
            if !favs.isEmpty {
                section(language.dashFavorites, icon: "star.fill", tint: .yellow) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 124), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(favs) { largeTile($0) }
                    }
                }
            }

            let mine = ([note] + yours).filter(matches)
            if !mine.isEmpty {
                section(language.cardSelectedServices, icon: "square.grid.2x2.fill", tint: .secondary) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(mine) { mediumTile($0) }
                    }
                }
            }

            let rest = others.filter(matches)
            if !rest.isEmpty {
                if othersVisible {
                    section(language.cardOtherServices, icon: "ellipsis.circle", tint: .secondary) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 4)], alignment: .leading, spacing: 4) {
                            ForEach(rest) { smallTile($0) }
                        }
                    }
                    if search.isEmpty && !others.contains(where: { $0.id == selection }) {
                        linkButton(language.cardHideOtherServices) { showOthers = false }
                    }
                } else {
                    linkButton("\(language.cardShowOtherServices) (\(rest.count))") { showOthers = true }
                }
            }
        }
    }

    // MARK: Tiles

    private func largeTile(_ e: AWSServiceCatalogEntry) -> some View {
        Button { onSelect(e.id) } label: {
            VStack(spacing: 8) {
                icon(e, size: 26)
                    .frame(width: 50, height: 50)
                    .background(tint(e).opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(e.name).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(background(e), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(border(e, radius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func mediumTile(_ e: AWSServiceCatalogEntry) -> some View {
        Button { onSelect(e.id) } label: {
            HStack(spacing: 8) {
                icon(e, size: 16)
                    .frame(width: 30, height: 30)
                    .background(tint(e).opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(e.name).font(.callout).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(background(e), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(border(e, radius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func smallTile(_ e: AWSServiceCatalogEntry) -> some View {
        Button { onSelect(e.id) } label: {
            HStack(spacing: 6) {
                icon(e, size: 11).frame(width: 16)
                Text(e.name).font(.caption).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(background(e), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(border(e, radius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(_ e: AWSServiceCatalogEntry, size: CGFloat) -> some View {
        Image(systemName: e.icon)
            .font(.system(size: size, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint(e))
    }

    private func tint(_ e: AWSServiceCatalogEntry) -> Color { e.id == "note" ? Color(hex: "#CA8A04") : e.tint }
    private func background(_ e: AWSServiceCatalogEntry) -> Color { e.id == selection ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.045) }
    private func border(_ e: AWSServiceCatalogEntry, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(e.id == selection ? Color.accentColor : .clear, lineWidth: 1.5)
    }

    private func section<Content: View>(_ title: String, icon: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } icon: { Image(systemName: icon).font(.caption).foregroundStyle(tint) }
            content()
        }
    }

    /// Looks like underlined text, not a button.
    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout).underline().foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}

/// The chosen service as a large button; clicking it opens the same picker
/// in a popover (favorites / your services / others).
struct CardServiceButton: View {
    let selection: String
    let language: AppLanguage
    var onSelect: (String) -> Void

    @Environment(AppState.self) private var appState
    @State private var showPicker = false
    @State private var isHovering = false
    /// The picker's own height, so the popover is only as tall as it needs (max 560).
    @State private var pickerHeight: CGFloat = 300

    private var entry: AWSServiceCatalogEntry? { appState.serviceCatalog.first { $0.id == selection } }

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 14) {
                Image(systemName: entry?.icon ?? "note.text")
                    .font(.system(size: 24, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(entry?.tint ?? Color(hex: "#CA8A04"))
                    .frame(width: 48, height: 48)
                    .background((entry?.tint ?? Color(hex: "#CA8A04")).opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry?.name ?? language.cardNoteService).font(.title3.weight(.semibold))
                    Text(entry?.category.isEmpty == false ? entry!.category : language.cardKindHint(.note)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(language.cardChangeService, systemImage: "chevron.up.chevron.down")
                    .font(.callout)
                    .foregroundStyle(isHovering ? Color.accentColor : .secondary)
            }
            .padding(12)
            .background(Color.primary.opacity(isHovering ? 0.07 : 0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            ScrollView {
                CardServicePicker(selection: selection, language: language) { id in
                    showPicker = false
                    onSelect(id)
                }
                .padding(16)
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { pickerHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in pickerHeight = h }
                })
            }
            .frame(width: 640, height: min(pickerHeight, 560))
        }
    }
}
