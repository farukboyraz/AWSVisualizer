import SwiftUI

/// Settings › Display › Dashboard. Edits the Settings draft; saved with
/// "Save Changes" like every other page.
struct DashboardSettingsPage: View {
    @Binding var prefs: DashboardPrefs

    @Environment(AppState.self) private var appState

    @State private var customMode = false
    @State private var customValue = "180"
    @State private var customHours = false

    private var language: AppLanguage { appState.language }
    private var services: [AWSServiceCatalogEntry] { appState.selectedCatalogEntries.filter(\.implemented) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sections
            Divider()
            cost
            Divider()
            refresh
            Divider()
            cardList
            Divider()
            look
            Divider()
            serviceList
        }
    }

    // MARK: Sections

    private var sections: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(language.dsSections)
            ForEach(DashboardPrefs.Widget.allCases, id: \.self) { widget in
                HStack {
                    Text(language.dsWidget(widget))
                    Text(widget.usesCost ? language.dsUsesCost : widget == .customCards ? language.dsUsesCards : language.dsUsesCounts)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    Spacer()
                    SwitchBox(isOn: Binding(get: { prefs.isOn(widget) }, set: { prefs.set(widget, $0) }))
                }
            }
            note(language.dsSectionsNote)
        }
    }

    // MARK: Cost

    private var cost: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(language.dsCost)
            Group {
                HStack {
                    Text(language.dsCostView)
                    Spacer()
                    MultiSwitchBox(selection: $prefs.cost.view, options: DashboardPrefs.CostView.allCases.map { ($0, language.costViewLabel($0)) }, segmentWidth: 92)
                }
                HStack {
                    Text(language.dsMonths)
                    Spacer()
                    MultiSwitchBox(selection: $prefs.cost.months, options: DashboardPrefs.monthRanges.map { ($0, language.monthsLabel($0)) }, segmentWidth: 76)
                }
                HStack {
                    Text(language.dsChartStyle)
                    Spacer()
                    MultiSwitchBox(selection: $prefs.cost.chartStyle, options: DashboardPrefs.ChartStyle.allCases.map { ($0, language.chartStyleLabel($0)) }, segmentWidth: 76)
                }
                LabeledSwitchBox(title: language.dsShowEstimate, isOn: $prefs.cost.showEstimate)
                note(language.dsCostViewNote)
            }
            .disabled(!prefs.needsCost)
            .opacity(prefs.needsCost ? 1 : 0.45)
            if !prefs.needsCost {
                Label(language.dsCostOff, systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Appearance

    private var look: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(language.dsLook)
            HStack {
                Text(language.dsColors)
                Spacer()
                MultiSwitchBox(selection: $prefs.colorStyle, options: DashboardPrefs.ColorStyle.allCases.map { ($0, language.colorStyleLabel($0)) }, segmentWidth: 92)
            }
            HStack {
                Text(language.dsServicesLayout)
                Spacer()
                MultiSwitchBox(selection: $prefs.servicesLayout, options: DashboardPrefs.ServicesLayout.allCases.map { ($0, language.servicesLayoutLabel($0)) }, segmentWidth: 120)
            }
            note(language.dsServicesLayoutNote)
            LabeledSwitchBox(title: language.dsHideEmpty, isOn: $prefs.hideEmptyServices)
        }
    }

    // MARK: Refresh

    /// -1 in the switch = "Custom".
    private static let customTag = -1

    private var refreshSelection: Binding<Int> {
        Binding(
            get: { ([0] + DashboardPrefs.refreshPresets).contains(prefs.refreshMinutes) && !customMode ? prefs.refreshMinutes : Self.customTag },
            set: { value in
                if value == Self.customTag {
                    customMode = true
                    loadCustomFields(from: prefs.refreshMinutes == 0 ? 180 : prefs.refreshMinutes)
                    applyCustom()
                } else {
                    customMode = false
                    prefs.refreshMinutes = value
                }
            }
        )
    }

    private func loadCustomFields(from minutes: Int) {
        if minutes % 60 == 0 { customValue = "\(minutes / 60)"; customHours = true } else { customValue = "\(minutes)"; customHours = false }
    }

    /// Minutes the custom fields describe; nil when outside 1 min .. 24 h.
    private var customMinutes: Int? {
        guard let n = Int(customValue.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        let minutes = customHours ? n * 60 : n
        return (1...DashboardPrefs.refreshMax).contains(minutes) ? minutes : nil
    }

    private func applyCustom() {
        if let minutes = customMinutes { prefs.refreshMinutes = minutes }
    }

    private var refresh: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(language.dsRefresh)
            HStack {
                Text(language.dsRefreshEvery)
                Spacer()
                MultiSwitchBox(
                    selection: refreshSelection,
                    options: ([0] + DashboardPrefs.refreshPresets).map { ($0, language.dsRefreshLabel($0)) } + [(Self.customTag, language.dsCustom)],
                    segmentWidth: 70
                )
            }
            if refreshSelection.wrappedValue == Self.customTag {
                HStack(spacing: 8) {
                    Spacer()
                    TextField("", text: $customValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: customValue) { applyCustom() }
                    Picker("", selection: $customHours) {
                        Text(language.dsMinutes).tag(false)
                        Text(language.dsHours).tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: customHours) { applyCustom() }
                }
                if customMinutes == nil {
                    Label(language.dsRefreshInvalid(DashboardPrefs.refreshMax), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            note(language.dsRefreshNote)
            LabeledSwitchBox(title: language.dsRefreshOnOpen, isOn: $prefs.refreshOnOpen)
            note(language.dsRefreshOnOpenNote)
        }
        .onAppear {
            if !([0] + DashboardPrefs.refreshPresets).contains(prefs.refreshMinutes) {
                customMode = true
                loadCustomFields(from: prefs.refreshMinutes)
            }
        }
    }

    // MARK: Cards

    private var cardList: some View {
        VStack(alignment: .leading, spacing: 6) {
            DashboardCardList(cards: $prefs.cards, language: language)
            note(language.cardsSettingsNote)
        }
    }

    // MARK: Services

    private var serviceList: some View {
        let excluded = Set(prefs.excludedServices)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                header(language.dsServices)
                Spacer()
                if !services.isEmpty {
                    Text(language.dsServicesCount(shown: services.filter { !excluded.contains($0.id) }.count, total: services.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(language.dsAll) { prefs.excludedServices = [] }.controlSize(.small)
                    Button(language.dsNone) { prefs.excludedServices = services.map(\.id) }.controlSize(.small)
                }
            }
            if services.isEmpty {
                note(language.dsNoServices)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], alignment: .leading, spacing: 8) {
                    ForEach(services) { entry in
                        HStack(spacing: 8) {
                            ServiceIcon(entry: entry)
                                .frame(width: 18)
                            Text(entry.name).lineLimit(1)
                            Spacer(minLength: 6)
                            SwitchBox(isOn: Binding(
                                get: { !excluded.contains(entry.id) },
                                set: { on in
                                    var set = Set(prefs.excludedServices)
                                    if on { set.remove(entry.id) } else { set.insert(entry.id) }
                                    // Keep the selection order, so the saved file is stable.
                                    prefs.excludedServices = services.map(\.id).filter(set.contains)
                                }
                            ))
                        }
                    }
                }
            }
            note(language.dsServicesNote)
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}
