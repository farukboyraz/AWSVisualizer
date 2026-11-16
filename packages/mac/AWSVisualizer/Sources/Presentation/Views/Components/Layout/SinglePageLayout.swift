import SwiftUI

/// One page at a time (Settings → Layout → Single page, see
/// `MasterDetailView`): the list fills the window; once something is
/// selected its detail takes the whole page. Above it, one compact path
/// row - `‹  Tables / Orders` - where ‹ and "Tables" both go back. The list
/// stays alive underneath (hidden), so Back lands on the same scroll
/// position and search text.
struct SinglePageLayout<Master: View, Detail: View>: View {
    var isDetailActive: Bool
    var onBack: () -> Void
    var backTitle: String
    var detailTitle: String?
    var showsBackBar = true
    @ViewBuilder var master: () -> Master
    @ViewBuilder var detail: () -> Detail

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            master()
                .listTierBackground(colorScheme)
                .opacity(isDetailActive ? 0 : 1)
                .allowsHitTesting(!isDetailActive)
                .accessibilityHidden(isDetailActive)
            if isDetailActive {
                VStack(spacing: 0) {
                    if showsBackBar {
                        PathBar(onBack: onBack, crumbs: [
                            PathCrumb(title: backTitle, action: onBack),
                        ] + (detailTitle.map { [PathCrumb(title: $0)] } ?? []))
                        Divider()
                    }
                    detail()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Theme.detailBackground(colorScheme))
            }
        }
    }
}

/// One step of a `PathBar`. `action == nil` = the current place (bold,
/// not clickable).
struct PathCrumb: Identifiable {
    let id = UUID()
    var title: String
    var icon: AnyView?
    var action: (() -> Void)?

    init(title: String, icon: AnyView? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.icon = icon
        self.action = action
    }
}

/// `‹  Buckets / my-bucket / logs / app.log` - Back (⌘[) plus a path whose
/// every earlier part is clickable, so several levels can be skipped at
/// once. Shared by single-page screens and S3's location row.
struct PathBar<Trailing: View>: View {
    var onBack: (() -> Void)?
    /// Back sits before the path (default) or after it (S3, next to search).
    var backAtEnd = false
    let crumbs: [PathCrumb]
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if !backAtEnd { backButton }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                            if index > 0 {
                                Text("/")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 2)
                            }
                            crumbView(crumb).id(crumb.id)
                        }
                    }
                }
                .onChange(of: crumbs.map(\.title)) { _, _ in
                    // Keep the current (last) part in view on deep paths.
                    if let last = crumbs.last { proxy.scrollTo(last.id, anchor: .trailing) }
                }
            }
            if backAtEnd { backButton }
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var backButton: some View {
        if let onBack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Color.secondary.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back (⌘[)")
        }
    }

    @ViewBuilder
    private func crumbView(_ crumb: PathCrumb) -> some View {
        let label = HStack(spacing: 4) {
            if let icon = crumb.icon { icon.font(.callout) }
            Text(crumb.title)
                .font(.callout.weight(crumb.action == nil ? .semibold : .regular))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        if let action = crumb.action {
            Button(action: action) {
                label
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to \(crumb.title)")
        } else {
            label.foregroundStyle(.primary)
        }
    }
}

extension PathBar where Trailing == EmptyView {
    init(onBack: (() -> Void)?, backAtEnd: Bool = false, crumbs: [PathCrumb]) {
        self.init(onBack: onBack, backAtEnd: backAtEnd, crumbs: crumbs, trailing: { EmptyView() })
    }
}
