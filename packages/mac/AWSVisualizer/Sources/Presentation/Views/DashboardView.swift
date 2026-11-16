import SwiftUI

/// Loads what the dashboard shows and renders `DashboardContent`.
///
/// **Saved data first.** Counts, the cost view and every card's value are
/// saved by the sidecar in ~/.awsvisualizer (`dashboardCache`). Opening the
/// dashboard reads that - no AWS call - and fetches a part again only when
/// it is missing, older than Settings › Display › Dashboard › Refresh
/// (default 15 minutes), or "Fetch every time the dashboard opens" is on
/// (default off). While the dashboard stays open the next fetch is
/// scheduled from the saved data's age.
///
/// **Checks before any call** (the sidecar repeats them):
/// - counts only when a count widget is on, only for non-excluded services;
/// - Cost Explorer only when a cost widget is on;
/// - a card's request only when "My cards" is on, and only for saved cards.
struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var counts: DashboardCached<[String: Int?]>?
    /// Services whose count request is still running.
    @State private var loadingServices: Set<String> = []
    @State private var countsFailure: String?
    @State private var costState: DashboardModel.CostState = .loading
    @State private var costFetchedAt: Date?
    @State private var cardStates: [String: DashboardCardState] = [:]
    /// Last result of each action card (saved as `run|<id>`).
    @State private var runResults: [String: DashboardCached<CardActionResult>] = [:]
    @State private var running: DashboardCard?
    @State private var managingCards = false
    @State private var cardError: String?
    @State private var isLoading = false
    @State private var hasOpened = false

    @State private var costView: DashboardPrefs.CostView = .month
    @State private var costMonth = DashboardContent.currentMonthKey
    @State private var costMonths = 6
    @State private var chartStyle: DashboardPrefs.ChartStyle = .bar

    @State private var editing: EditingCard?

    private struct EditingCard: Identifiable {
        let id = UUID()
        let card: DashboardCard
        let isNew: Bool
    }

    private var prefs: DashboardPrefs { appState.dashboardPrefs }
    private var profile: String { appState.currentProfile }
    private var region: String { appState.currentRegion }

    /// Selected, implemented and not excluded on the dashboard.
    private var entries: [AWSServiceCatalogEntry] {
        let excluded = Set(prefs.excludedServices)
        return appState.selectedCatalogEntries.filter { $0.implemented && !excluded.contains($0.id) }
    }

    /// Metric cards are fetched with the dashboard; actions only run on click.
    /// Cards of this profile, plus the ones shown on every profile.
    private var visibleCards: [DashboardCard] { prefs.cards.filter { $0.isVisible(on: profile) } }
    /// Metric cards are fetched with the dashboard; actions only run on click.
    private var fetchableCards: [DashboardCard] { prefs.isOn(.customCards) ? visibleCards.filter { $0.kind == .metric } : [] }
    private var actionCards: [DashboardCard] { prefs.isOn(.customCards) ? visibleCards.filter { $0.kind == .action } : [] }

    private func contextOf(_ card: DashboardCard) -> (profile: String, region: String) {
        card.context(currentProfile: profile, currentRegion: region)
    }
    private func cardKey(_ card: DashboardCard) -> String {
        let c = contextOf(card)
        return DashboardCacheKey.card(card.id, profile: c.profile, region: c.region)
    }
    private func runKey(_ card: DashboardCard) -> String {
        let c = contextOf(card)
        return DashboardCacheKey.run(card.id, profile: c.profile, region: c.region)
    }

    /// Anything that changes what should be on screen.
    private var loadKey: String {
        [profile, region, entries.map(\.id).joined(separator: ","), "\(prefs.needsCounts)", "\(prefs.needsCost)",
         costView.rawValue, costMonth, "\(costMonths)", fetchableCards.map(\.id).joined(separator: ","),
         "\(prefs.refreshMinutes)"].joined(separator: "|")
    }

    var body: some View {
        AuthGuardedView {
            GeometryReader { geometry in
                ScrollView {
                    content(width: geometry.size.width - 56)
                        .padding(28)
                        .frame(maxWidth: 1500, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            }
            .task(id: loadKey) { await run() }
            .onAppear(perform: applyCostDefaults)
            .onChange(of: prefs.cost) { applyCostDefaults() }
            .sheet(item: $editing) { item in
                DashboardCardEditor(
                    card: item.isNew ? nil : item.card,
                    language: appState.language,
                    profiles: profileNames,
                    defaultProfile: profile,
                    defaultRegion: region,
                    onSave: { card in editing = nil; Task { await saveCard(card) } },
                    onCancel: { editing = nil }
                )
            }
            .sheet(isPresented: $managingCards) {
                DashboardCardManagerSheet(
                    language: appState.language,
                    // Saved right away, like adding from the dashboard.
                    cards: Binding(get: { appState.dashboardPrefs.cards }, set: { cards in Task { await updateCards { $0 = cards } } }),
                    onClose: { managingCards = false }
                )
            }
            .sheet(item: $running) { card in
                DashboardCardRunSheet(
                    card: card,
                    language: appState.language,
                    profile: contextOf(card).profile,
                    region: contextOf(card).region,
                    onFinished: { runResults[card.id] = $0 },
                    onOpen: { appState.open($0) },
                    onClose: { running = nil }
                )
            }
            .alert(cardError ?? "", isPresented: Binding(get: { cardError != nil }, set: { if !$0 { cardError = nil } })) {
                Button(appState.language.okButtonTitle) {}
            }
        }
    }

    @ViewBuilder private func content(width: CGFloat) -> some View {
        let language = appState.language
        if appState.selectedCatalogEntries.filter(\.implemented).isEmpty {
            EmptyStateView(message: language.dashEmpty)
                .frame(maxWidth: .infinity, minHeight: 400)
        } else if let countsFailure, counts == nil {
            ErrorStateView(message: countsFailure, retry: { Task { await refreshAll() } })
                .frame(maxWidth: .infinity, minHeight: 400)
        } else {
            // No skeleton: the real layout right away, each service filling in as its count arrives.
            let waiting = prefs.needsCounts && counts == nil ? Set(entries.map(\.id)) : loadingServices
            let model = DashboardModel(entries: entries, counts: counts?.data ?? [:], loading: waiting, costState: costState, updatedAt: counts?.fetchedAt ?? costFetchedAt ?? Date())
            DashboardContent(
                model: model,
                prefs: prefs,
                language: language,
                profile: profile,
                region: region,
                account: appState.callerIdentity?.account,
                favorites: appState.favoriteServiceIDs,
                width: min(width, 1500),
                isRefreshing: isLoading,
                costView: $costView,
                costMonth: $costMonth,
                costMonths: $costMonths,
                chartStyle: $chartStyle,
                visibleCards: visibleCards,
                cardStates: cardStates,
                runResults: runResults,
                serviceName: { id in appState.serviceCatalog.first { $0.id == id }?.name ?? (id == "note" ? language.cardNoteService : id) },
                cardActions: cardActions,
                onOpen: { appState.selectedService = $0 },
                onRefresh: { Task { await refreshAll() } },
                onCustomize: { appState.requestedSettingsPage = .dashboard },
                loadingServices: waiting,
                onToggleSection: { widget, on in Task { await toggleSection(widget, on) } }
            )
        }
    }

    private var profileNames: [String] {
        let names = appState.profiles.map(\.name)
        return names.isEmpty ? [profile] : names
    }

    private func applyCostDefaults() {
        costView = prefs.cost.view
        costMonths = prefs.cost.months
        chartStyle = prefs.cost.chartStyle
    }

    // MARK: - Loading

    /// Saved data -> what is due -> fetch -> sleep until the next part is due.
    private func run() async {
        let isOpening = !hasOpened
        hasOpened = true
        await loadSaved()
        await fetchDue(force: isOpening && prefs.refreshOnOpen)
        while !Task.isCancelled, let wait = secondsUntilNextDue() {
            try? await Task.sleep(nanoseconds: UInt64(max(wait, 1) * 1_000_000_000))
            if Task.isCancelled { return }
            await fetchDue(force: false)
        }
    }

    private var countsKey: String { DashboardCacheKey.counts(profile: profile, region: region) }
    private var costKey: String { DashboardCacheKey.cost(profile: profile, view: costView, months: costMonths, month: costMonth) }

    /// Reads ~/.awsvisualizer's saved answers - never calls AWS.
    private func loadSaved() async {
        let keys = [countsKey, costKey] + fetchableCards.map(cardKey) + actionCards.map(runKey)
        let saved = (try? await api.getDashboardCache(keys: keys)) ?? [:]
        let decoder = JSONDecoder()

        if prefs.needsCounts {
            if let entry = saved[countsKey], let data = try? decoder.decode([String: Int?].self, from: entry.data) {
                counts = DashboardCached(fetchedAt: entry.fetchedAt, data: data)
            } else if counts.map({ _ in false }) ?? true {
                counts = nil
            }
        } else {
            counts = DashboardCached(fetchedAt: Date(), data: [:])
        }

        if !prefs.needsCost {
            costState = .hidden
            costFetchedAt = nil
        } else if let entry = saved[costKey], let summary = try? decoder.decode(CostSummary.self, from: entry.data) {
            costState = .loaded(DashboardModel.Cost(summary))
            costFetchedAt = entry.fetchedAt
        } else {
            costState = .loading
            costFetchedAt = nil
        }

        var states: [String: DashboardCardState] = [:]
        for card in fetchableCards {
            if let entry = saved[cardKey(card)], let value = try? decoder.decode(DashboardCardValue.self, from: entry.data) {
                states[card.id] = .loaded(DashboardCached(fetchedAt: entry.fetchedAt, data: value))
            } else {
                states[card.id] = cardStates[card.id] ?? .notFetched
            }
        }
        cardStates = states

        var results: [String: DashboardCached<CardActionResult>] = [:]
        for card in actionCards {
            if let entry = saved[runKey(card)], let result = try? decoder.decode(CardActionResult.self, from: entry.data) {
                results[card.id] = DashboardCached(fetchedAt: entry.fetchedAt, data: result)
            }
        }
        runResults = results
    }

    private func isDue(_ fetchedAt: Date?) -> Bool {
        guard let fetchedAt else { return true }
        return DashboardCached(fetchedAt: fetchedAt, data: ()).isStale(after: prefs.refreshMinutes)
    }

    /// Fetches every part that is missing or stale (or all of them with `force`).
    private func fetchDue(force: Bool) async {
        let countsDue = prefs.needsCounts && !entries.isEmpty && (force || isDue(counts?.fetchedAt))
        let costDue = prefs.needsCost && (force || isDue(costFetchedAt))
        let cardsDue = fetchableCards.filter { force || isDue(cardStates[$0.id]?.value?.fetchedAt) }
        guard countsDue || costDue || !cardsDue.isEmpty else { return }
        isLoading = true
        await withTaskGroup(of: Void.self) { group in
            if countsDue { group.addTask { await fetchCounts() } }
            if costDue { group.addTask { await fetchCost() } }
            for card in cardsDue { group.addTask { await fetchCard(card.id) } }
        }
        isLoading = false
    }

    /// Seconds until the oldest shown part goes stale; nil = manual refresh only.
    private func secondsUntilNextDue() -> Double? {
        guard prefs.refreshMinutes > 0 else { return nil }
        let stamps = [prefs.needsCounts ? counts?.fetchedAt : nil, prefs.needsCost ? costFetchedAt : nil]
            + fetchableCards.map { cardStates[$0.id]?.value?.fetchedAt }
        let dates = stamps.compactMap { $0 }
        guard let oldest = dates.min() else { return nil }
        return oldest.addingTimeInterval(Double(prefs.refreshMinutes) * 60).timeIntervalSinceNow
    }

    private func refreshAll() async {
        isLoading = true
        await withTaskGroup(of: Void.self) { group in
            if prefs.needsCounts && !entries.isEmpty { group.addTask { await fetchCounts(clear: true) } }
            if prefs.needsCost { group.addTask { await fetchCost() } }
            for card in fetchableCards { group.addTask { await fetchCard(card.id, clear: true) } }
        }
        isLoading = false
    }

    /// One request per service (at most 6 at a time), so each tile and the
    /// totals fill in the moment its count arrives instead of all at once.
    /// `clear`: a Refresh click - the old numbers go first.
    private func fetchCounts(clear: Bool = false) async {
        countsFailure = nil
        let ids = entries.map(\.id)
        guard !ids.isEmpty else { return }
        if clear || counts == nil { counts = DashboardCached(fetchedAt: Date(), data: clear ? [:] : (counts?.data ?? [:])) }
        loadingServices = Set(ids)
        let requestProfile = profile, requestRegion = region
        var failures = 0
        await withTaskGroup(of: (String, Int??).self) { group in
            var queue = ids[...]
            func next() {
                guard let id = queue.popFirst() else { return }
                group.addTask {
                    let result = try? await api.getServiceCounts(profile: requestProfile, region: requestRegion, services: [id], source: "dashboard")
                    return (id, result.map { $0[id] ?? nil })
                }
            }
            for _ in 0..<min(6, ids.count) { next() }
            for await (id, value) in group {
                if Task.isCancelled { break }
                var data = counts?.data ?? [:]
                if let value { data[id] = value } else { failures += 1; data[id] = Int?.none }
                counts = DashboardCached(fetchedAt: Date(), data: data)
                loadingServices.remove(id)
                next()
            }
        }
        loadingServices = []
        if failures == ids.count { countsFailure = appState.language.dashCostFailed }
    }

    /// A section switched on / off in the header: saved right away; turning
    /// one on makes the dashboard fetch what it needs (the load task re-runs).
    private func toggleSection(_ widget: DashboardPrefs.Widget, _ on: Bool) async {
        var updated = prefs
        updated.set(widget, on)
        let previous = appState.dashboardPrefs
        appState.dashboardPrefs = updated.normalized
        do {
            let saved = try await api.updateDashboardPrefs(updated)
            if let prefs = saved.dashboard { appState.dashboardPrefs = prefs }
        } catch {
            appState.dashboardPrefs = previous
            cardError = error.friendlyMessage
        }
    }

    private func fetchCost() async {
        if case .loaded = costState {} else { costState = .loading }
        do {
            // fresh: the dashboard decided it is due - skip the sidecar's memory cache.
            let response = try await api.getCost(profile: profile, view: costView, months: costMonths, month: costView == .month ? costMonth : nil, fresh: true)
            if !response.authorized {
                costState = .denied
            } else if let data = response.data {
                costState = .loaded(DashboardModel.Cost(data))
            } else {
                costState = .hidden
            }
            costFetchedAt = Date()
        } catch where error.isCancellation {
            // The dashboard reloaded (view / month / profile changed) while this
            // request was in flight: the new load fetches the cost itself, so
            // nothing is shown and nothing is marked as fetched.
        } catch {
            costState = .failed(error.friendlyMessage)
            costFetchedAt = Date()
        }
    }

    /// `clear`: a Refresh click - the card empties and shows a loader in
    /// the middle until the new value arrives (timed refreshes keep the old
    /// value on screen meanwhile).
    private func fetchCard(_ id: String, clear: Bool = false) async {
        guard let card = prefs.cards.first(where: { $0.id == id }) else { return }
        let previous = cardStates[id]?.value
        cardStates[id] = .loading(previous: clear ? nil : previous)
        let c = contextOf(card)
        do {
            cardStates[id] = .loaded(try await api.getDashboardCardValue(id: id, profile: c.profile, region: c.region))
        } catch where error.isCancellation {
            cardStates[id] = previous.map { .loaded($0) } ?? .notFetched
        } catch {
            cardStates[id] = .failed(error.friendlyMessage, previous: previous)
        }
    }

    // MARK: - Cards

    private var cardActions: DashboardCardActions {
        DashboardCardActions(
            add: {
                editing = EditingCard(card: DashboardCard(profiles: [profile]), isNew: true)
            },
            manage: { managingCards = true },
            run: { card in
                if card.kind == .action {
                    running = card
                } else {
                    // Search / metric cards open their results, links their target.
                    Task {
                        do { appState.open(try await api.getCardLink(id: card.id)) } catch { cardError = error.friendlyMessage }
                    }
                }
            },
            openTarget: { appState.open($0) },
            move: { dragged, target in
                Task {
                    await updateCards { cards in
                        guard let from = cards.firstIndex(where: { $0.id == dragged }),
                              let to = cards.firstIndex(where: { $0.id == target }) else { return }
                        let card = cards.remove(at: from)
                        cards.insert(card, at: to)
                    }
                }
            }
        )
    }

    private func saveCard(_ card: DashboardCard) async {
        await updateCards { cards in
            if let index = cards.firstIndex(where: { $0.id == card.id }) { cards[index] = card } else { cards.append(card) }
        }
        if card.kind == .metric, prefs.isOn(.customCards) { await fetchCard(card.id) }
    }

    /// Cards are saved right away (not via the Settings draft): order,
    /// additions and deletions go to ~/.awsvisualizer immediately.
    private func updateCards(_ change: (inout [DashboardCard]) -> Void) async {
        var updated = prefs
        change(&updated.cards)
        let previous = appState.dashboardPrefs
        appState.dashboardPrefs = updated
        do {
            // The sidecar fills each card's kind / icon from its template.
            let saved = try await api.updateDashboardPrefs(updated)
            if let prefs = saved.dashboard { appState.dashboardPrefs = prefs }
        } catch {
            appState.dashboardPrefs = previous
            cardError = error.friendlyMessage
        }
    }
}
