import SwiftUI
import UniformTypeIdentifiers

/// What a metric card shows right now.
enum DashboardCardState: Equatable {
    case notFetched
    case loading(previous: DashboardCached<DashboardCardValue>?)
    case loaded(DashboardCached<DashboardCardValue>)
    case failed(String, previous: DashboardCached<DashboardCardValue>?)

    var value: DashboardCached<DashboardCardValue>? {
        switch self {
        case .loaded(let v): return v
        case .loading(let p), .failed(_, let p): return p
        case .notFetched: return nil
        }
    }

    var isLoading: Bool { if case .loading = self { return true } else { return false } }

    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.notFetched, .notFetched): return true
        case (.loading(let x), .loading(let y)): return x?.fetchedAt == y?.fetchedAt
        case (.loaded(let x), .loaded(let y)): return x.fetchedAt == y.fetchedAt && x.data == y.data
        case (.failed(let m, _), .failed(let n, _)): return m == n
        default: return false
        }
    }
}

/// What the "My cards" section can ask its owner to do.
struct DashboardCardActions {
    var add: () -> Void = {}
    /// Opens the "Edit cards" window (list with edit / delete / order).
    var manage: () -> Void = {}
    /// The card's Run button: a search / metric card opens its results in
    /// the service, an action card runs (after confirming), a link opens.
    var run: (DashboardCard) -> Void = { _ in }
    var openTarget: (CardLinkTarget) -> Void = { _ in }
    /// Dragged card id, dropped onto card id.
    var move: (String, String) -> Void = { _, _ in }
}

/// "My cards": the user's own cards, drag-and-drop ordered. Only Add and
/// Edit (icons) in the header; each card just has its Run button.
struct DashboardCardsSection: View {
    let cards: [DashboardCard]
    let states: [String: DashboardCardState]
    var runResults: [String: DashboardCached<CardActionResult>] = [:]
    let language: AppLanguage
    var serviceName: (String) -> String = { $0 }
    var actions = DashboardCardActions()

    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label {
                    Text(language.cardsTitle).font(.title3.bold())
                } icon: {
                    Image(systemName: "rectangle.stack.badge.person.crop").foregroundStyle(.secondary)
                }
                Spacer()
                NewButton(compactSize: 26, isDisabled: cards.count >= DashboardPrefs.maxCards, help: cards.count >= DashboardPrefs.maxCards ? language.cardLimit : language.cardsAdd, action: actions.add)
                EditButton(compactSize: 26, help: language.cardsEditTitle, action: actions.manage)
            }
            if cards.isEmpty {
                Text(language.cardsEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dashboardSurface()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(cards) { card in
                        DashboardCustomCardView(card: card, state: states[card.id] ?? .notFetched, lastRun: runResults[card.id], language: language, serviceName: serviceName(card.service), actions: actions)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: dropTarget == card.id ? 2 : 0)
                            )
                            .draggable(card.id) {
                                Label(card.title, systemImage: card.icon)
                                    .padding(8)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .dropDestination(for: String.self) { ids, _ in
                                guard let dragged = ids.first, dragged != card.id else { return false }
                                actions.move(dragged, card.id)
                                return true
                            } isTargeted: { targeted in
                                dropTarget = targeted ? card.id : (dropTarget == card.id ? nil : dropTarget)
                            }
                    }
                }
            }
        }
    }
}

/// One card: icon, title and what it works on on the left, its number
/// (or last run / note) underneath, and a round Run button on the right.
struct DashboardCustomCardView: View {
    let card: DashboardCard
    let state: DashboardCardState
    var lastRun: DashboardCached<CardActionResult>?
    let language: AppLanguage
    var serviceName: String = ""
    var actions: DashboardCardActions

    static func kindColor(_ kind: CardTemplate.Kind) -> Color {
        switch kind {
        case .metric: return Color(hex: "#2563EB")
        case .action: return Color(hex: "#DB2777")
        case .link: return Color(hex: "#0D9488")
        case .note: return Color(hex: "#CA8A04")
        }
    }

    private var tint: Color { Self.kindColor(card.kind) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: card.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help(subtitle)
                    }
                }
                switch card.kind {
                case .note:
                    Text(card.params["text"] ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .metric:
                    metricView
                case .action:
                    actionView
                case .link:
                    Text(language.cardKindHint(.link)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if card.kind != .note {
                RunButton(compactSize: 38, help: runHelp) { actions.run(card) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .dashboardSurface()
    }

    private var runHelp: String {
        switch card.kind {
        case .metric: return language.cardRunMetricHelp
        case .action: return language.cardRun
        default: return language.cardOpen
        }
    }
    /// "S3 · bucket/prefix" - the service and the card's main settings.
    private var subtitle: String {
        var parts = [serviceName]
        var values: [String] = []
        for (key, value) in card.params.sorted(by: { $0.key < $1.key }) where key != "text" && key != "title" && key != "description" && !value.isEmpty {
            if key == "search" || key == "query", let q = DynamoSearchBuilderField.parse(value) {
                values.append(q.mode == .partiql ? "PartiQL" : q.mode == .scan ? "\(language.qbMode("scan")) · \(q.conditions.count)" : "\(q.pkName) = \(q.pkValue)")
            } else if key == "queue" {
                values.append(value.split(separator: "/").last.map(String.init) ?? value)
            } else {
                values.append(value)
            }
        }
        if card.service == "codecommit", let source = card.params["source"], let destination = card.params["destination"] {
            values = [card.params["repository"] ?? "", "\(source) → \(destination)"]
        }
        parts.append(contentsOf: values)
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var metricView: some View {
        if state.isLoading && state.value == nil {
            // Refresh clears the card: a loader in the middle until the new value arrives.
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, minHeight: 62)
        } else {
            metricValue
        }
    }

    @ViewBuilder private var metricValue: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cached = state.value {
                let v = cached.data
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    if v.truncated == true { Text(language.cardTruncated).font(.caption).foregroundStyle(.secondary) }
                    Text(DashboardFormat.number(v.value))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(v.unit(language)).font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    ForEach(Array((v.details ?? []).enumerated()), id: \.offset) { _, line in Text(line(language)) }
                    if v.approximate == true { Text("· \(language.cardApproximate)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if !state.isLoading {
                Text(language.cardNotFetched).font(.callout).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                if state.isLoading {
                    ProgressView().controlSize(.mini)
                } else if case .failed(let message, _) = state {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2).help(message)
                }
                if let cached = state.value {
                    Text(language.dashSavedAgo(DashboardFormat.relative(cached.fetchedAt, language: language))).foregroundStyle(.tertiary)
                }
            }
            .font(.caption2)
        }
    }

    @ViewBuilder private var actionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lastRun {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(language.cardLastRun) · \(DashboardFormat.relative(lastRun.fetchedAt, language: language))").font(.caption2).foregroundStyle(.tertiary)
                    HStack(spacing: 6) {
                        Text(lastRun.data.message(language)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let link = lastRun.data.link {
                            OpenButton(compactSize: 18, help: language.cardOpenResult) { actions.openTarget(link) }
                        }
                    }
                }
            } else {
                Text(language.cardNeverRun).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

}
