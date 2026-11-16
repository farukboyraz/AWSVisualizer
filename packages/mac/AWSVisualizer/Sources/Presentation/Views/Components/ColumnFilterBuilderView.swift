import SwiftUI

/// The "Filter Builder" popup opened from a `DataGridView` column's search
/// icon - a flat list of up to `FilterCondition.maxConditions` conditions,
/// each combined with the running result via its own AND/OR (first
/// condition has none, nothing precedes it). Edits here are a local draft;
/// nothing reaches the grid until "Search" is pressed (or Cmd+Return),
/// mirroring how the reference filter-builder mockup behaves rather than
/// re-filtering on every keystroke.
///
/// The draft is this view's own `@State`, not a binding into the grid: with
/// a binding, every keystroke and picker change invalidated the whole
/// `DataGridView` body (all of its rows) while the popover was open, which
/// is what made opening and typing in the builder feel sluggish on large
/// results.
struct ColumnFilterBuilderView: View {
    let columns: [DataGridColumn]
    var onSearch: ([FilterCondition]) -> Void
    var onDiscard: () -> Void
    var onClearAll: () -> Void
    /// "Search with PartiQL" - shown left of Search when set.
    var onSearchWithPartiQL: (([FilterCondition]) -> Void)?

    @State private var draftConditions: [FilterCondition]

    init(
        columns: [DataGridColumn],
        initialConditions: [FilterCondition],
        onSearch: @escaping ([FilterCondition]) -> Void,
        onDiscard: @escaping () -> Void,
        onClearAll: @escaping () -> Void,
        onSearchWithPartiQL: (([FilterCondition]) -> Void)? = nil
    ) {
        self.columns = columns
        self.onSearch = onSearch
        self.onDiscard = onDiscard
        self.onClearAll = onClearAll
        self.onSearchWithPartiQL = onSearchWithPartiQL
        _draftConditions = State(initialValue: initialConditions)
    }

    @Environment(AppState.self) private var appState
    @FocusState private var focusedConditionID: UUID?
    @State private var showClearConfirmation = false

    private let rowHeight: CGFloat = 44
    private let minBodyHeight: CGFloat = 90
    private let maxBodyHeight: CGFloat = 260
    private let popupWidth: CGFloat = 620

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(draftConditions.enumerated()), id: \.element.id) { index, condition in
                        conditionRow(isFirst: index == 0, condition: condition)
                    }
                }
                .padding(12)
            }
            .frame(minHeight: min(minBodyHeight, bodyContentHeight), idealHeight: bodyContentHeight, maxHeight: maxBodyHeight)

            if draftConditions.count >= FilterCondition.maxConditions {
                Text(appState.language.maxFilterConditionsWarning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            Divider()
            footer
        }
        .frame(width: popupWidth)
        .background(
            // Cmd+Return applies + closes regardless of which value field
            // currently has focus, matching the spec's "Cmd+Enter searches"
            // shortcut without needing to attach it per-textfield.
            Button("") { onSearch(draftConditions) }
                .keyboardShortcut(.return, modifiers: .command)
                .hidden()
        )
        .onAppear {
            focusedConditionID = draftConditions.last?.id
        }
    }

    private var bodyContentHeight: CGFloat {
        CGFloat(max(draftConditions.count, 1)) * rowHeight + 24
    }

    private var header: some View {
        HStack {
            Text("Filter Builder")
                .font(.headline)
            Spacer()
            ConfirmingCloseButton(
                confirmationTitle: appState.language.discardChangesTitle,
                confirmationMessage: appState.language.discardChangesMessage,
                confirmButtonTitle: appState.language.yesButtonTitle,
                cancelButtonTitle: appState.language.noButtonTitle,
                action: onDiscard
            )
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            ClearButton(appState.language.clearFiltersButtonLabel, systemImage: "trash") {
                showClearConfirmation = true
            }
            .confirmationDialog(
                appState.language.clearFiltersConfirmationTitle,
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(appState.language.yesButtonTitle, role: .destructive) { onClearAll() }
                Button(appState.language.noButtonTitle, role: .cancel) {}
            } message: {
                Text(appState.language.clearFiltersConfirmationMessage)
            }

            Spacer()

            if let onSearchWithPartiQL {
                SecondaryButton("Search with PartiQL", systemImage: "terminal") {
                    onSearchWithPartiQL(draftConditions)
                }
                .help("Open these conditions as a PartiQL SELECT and run it (case-sensitive)")
            }
            RunButton("Search", systemImage: "magnifyingglass") { onSearch(draftConditions) }
        }
        .padding(12)
    }

    // Every row reads and writes its condition by `id`, never by array
    // index. "Clear Filters" (and the row × button) shrink `draftConditions`
    // while SwiftUI can still render the outgoing rows one more time during
    // the popover's dismissal - an index-based `$draftConditions[index]`
    // then subscripts past the end and traps, killing the whole app. A
    // missing id just reads a default and ignores writes instead.
    private func conditionRow(isFirst: Bool, condition: FilterCondition) -> some View {
        let id = condition.id
        return HStack(spacing: 8) {
            Button {
                removeCondition(id: id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .background(Color.red.opacity(0.15), in: Circle())

            // Reserved even on the first row (which has no AND/OR - nothing
            // precedes it to combine with) so every row's column picker
            // starts at the same x-position instead of the first row
            // looking shifted left relative to the rest.
            if !isFirst {
                Picker("", selection: binding(id, default: .and, get: { $0.logicalOperator ?? .and }, set: { $0.logicalOperator = $1 })) {
                    ForEach(FilterLogicalOperator.allCases) { op in
                        Text(op.rawValue).tag(op)
                    }
                }
                .labelsHidden()
                .frame(width: 70)
            } else {
                Color.clear.frame(width: 70)
            }

            // Pick from the list (A → Z) or type any attribute name - the
            // list can't know an attribute no loaded item has.
            HStack(spacing: 2) {
                TextField("", text: binding(id, default: condition.columnID, get: { $0.columnID }, set: { $0.columnID = $1 }))
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(columns) { column in
                        Button(column.title) { updateCondition(id) { $0.columnID = column.id } }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .frame(width: 170)

            Picker("", selection: binding(id, default: condition.matchOperator, get: { $0.matchOperator }, set: { $0.matchOperator = $1 })) {
                ForEach(FilterMatchOperator.allCases) { op in
                    Text(op.rawValue).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            .onChange(of: condition.matchOperator) { _, newOperator in
                normalizeValues(id: id, for: newOperator)
            }

            valueInputs(for: condition)

            Spacer(minLength: 0)
        }
        .frame(height: rowHeight)
    }

    @ViewBuilder
    private func valueInputs(for condition: FilterCondition) -> some View {
        switch condition.matchOperator {
        case .onlyBlankNullNone, .notBlankNullNone:
            Text("No value needed")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 160, alignment: .leading)
        case .equal, .notEqual, .contains:
            TextField("Value", text: binding(condition.id, default: "", get: { $0.values.first ?? "" }, set: { $0.values = [$1] }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .focused($focusedConditionID, equals: condition.id)
        case .isIn:
            inValuesRow(for: condition)
        }
    }

    private func inValuesRow(for condition: FilterCondition) -> some View {
        let id = condition.id
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(condition.values.indices, id: \.self) { valueIndex in
                    TextField("Value \(valueIndex + 1)", text: binding(id, default: "", get: {
                        $0.values.indices.contains(valueIndex) ? $0.values[valueIndex] : ""
                    }, set: { condition, newValue in
                        guard condition.values.indices.contains(valueIndex) else { return }
                        condition.values[valueIndex] = newValue
                    }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .focused($focusedConditionID, equals: valueIndex == 0 ? id : nil)
                }
            }
        }
        .frame(width: 280, height: rowHeight)
        .onChange(of: condition.values) { _, _ in
            growInValuesIfNeeded(id: id)
        }
    }

    // MARK: - Bindings

    private func index(of id: UUID) -> Int? {
        draftConditions.firstIndex { $0.id == id }
    }

    /// A binding into one draft condition, looked up by id on every access.
    private func binding<Value>(
        _ id: UUID,
        default defaultValue: Value,
        get: @escaping (FilterCondition) -> Value,
        set: @escaping (inout FilterCondition, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let i = index(of: id) else { return defaultValue }
                return get(draftConditions[i])
            },
            set: { newValue in
                guard let i = index(of: id) else { return }
                set(&draftConditions[i], newValue)
            }
        )
    }

    // MARK: - Mutations

    private func updateCondition(_ id: UUID, _ change: (inout FilterCondition) -> Void) {
        guard let i = index(of: id) else { return }
        change(&draftConditions[i])
    }

    private func removeCondition(id: UUID) {
        guard let i = index(of: id) else { return }
        draftConditions.remove(at: i)
        if draftConditions.indices.contains(0) {
            draftConditions[0].logicalOperator = nil
        }
    }

    private func normalizeValues(id: UUID, for op: FilterMatchOperator) {
        guard let i = index(of: id) else { return }
        switch op {
        case .onlyBlankNullNone, .notBlankNullNone:
            draftConditions[i].values = []
        case .equal, .notEqual, .contains:
            draftConditions[i].values = [draftConditions[i].values.first ?? ""]
        case .isIn:
            let existing = draftConditions[i].values.filter { !$0.isEmpty }
            if existing.count >= FilterCondition.maxInValues {
                draftConditions[i].values = existing
            } else {
                draftConditions[i].values = existing + [""]
            }
        }
    }

    /// Keeps exactly one trailing blank "type the next value here" slot for
    /// the `In` operator's boxes, up to the 10-value cap - every non-blank
    /// value stays, blanks in the middle are left alone (dropped only when
    /// the filter is actually applied), and only the *trailing* run of
    /// blanks collapses back down to a single one.
    private func growInValuesIfNeeded(id: UUID) {
        guard let i = index(of: id) else { return }
        var values = draftConditions[i].values
        if let lastNonEmpty = values.lastIndex(where: { !$0.isEmpty }) {
            values = Array(values[0...lastNonEmpty])
            if values.count < FilterCondition.maxInValues {
                values.append("")
            }
        } else {
            values = [""]
        }
        if values != draftConditions[i].values {
            draftConditions[i].values = values
        }
    }
}
