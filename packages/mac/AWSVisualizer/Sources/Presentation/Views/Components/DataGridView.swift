import SwiftUI
import AppKit

/// A single column in a `DataGridView` - identity + resize bounds only, no
/// AWS-service-specific knowledge. What each cell actually renders is up to
/// the caller's `cell` closure, so the same grid works for a DynamoDB scan
/// result, and just as well for any other table-shaped data - each caller
/// swaps the column list and cell rendering, not the grid itself.
struct DataGridColumn: Identifiable {
    let id: String
    let title: String
    var minWidth: CGFloat = 120
    var maxWidth: CGFloat = 280
    var alignment: HorizontalAlignment = .leading
}

/// Reusable, per-column-resizable data grid: pinned header row, columns the
/// user can individually narrow/widen by dragging their right edge, and a
/// vertically-scrolling body underneath while the header stays put. Column
/// widths are the grid's own internal `@State`, not a `@Binding` - a caller
/// that needs them reset (e.g. when the schema/table selection changes)
/// does it by giving the grid a fresh identity with `.id(...)` instead of
/// reaching in, which also means a width-drag only ever invalidates this
/// view's own body, never the caller's (see `DataGridColumnResizeHandle`'s
/// doc comment for why that distinction used to matter).
///
/// Mirrors the pinned-header layering pattern DynamoDB's scan view used
/// before this component existed: an outer horizontal `ScrollView` holding
/// [header, vertical ScrollView of rows] so header and rows scroll together
/// horizontally (columns stay aligned) while rows scroll independently
/// underneath the fixed header. The inner vertical `ScrollView` needs a
/// concrete height from `GeometryReader` - `maxHeight: .infinity` doesn't
/// resolve inside the content of an already-unbounded outer `ScrollView`.
struct DataGridView<RowValue: Identifiable, Cell: View>: View {
    let columns: [DataGridColumn]
    let rows: [RowValue]
    var actionsColumnWidth: CGFloat = 0
    var headerHeight: CGFloat = 32
    var rowIsEven: (Int) -> Bool = { $0 % 2 == 0 }
    /// When true, a column with no manual width override sizes itself to
    /// fit its longest value/header (see `recomputeAutoFitWidths`) instead
    /// of splitting the available width evenly across all columns.
    var autoFitColumns: Bool = false
    @ViewBuilder var cell: (RowValue, DataGridColumn) -> Cell
    /// Trailing per-row controls (e.g. edit/clone icons), type-erased since
    /// a stored `@ViewBuilder` property can't itself carry an extra generic
    /// parameter without forcing every caller to spell it out.
    var rowActions: ((RowValue) -> AnyView)?
    var onDoubleTapRow: ((RowValue) -> Void)?
    var contextMenu: ((RowValue) -> AnyView)?
    /// Raw filterable text for a cell - powers both the built-in per-column
    /// search/filter popovers (a search icon appears on every header only
    /// when this is supplied) and `autoFitColumns`' width measurement.
    /// Kept separate from `cell` since what's rendered and what's matched/
    /// measured against aren't always the same thing.
    var filterValue: ((RowValue, DataGridColumn) -> String?)?
    /// When set, the grid stops filtering `rows` itself and hands each
    /// applied condition list (empty = cleared) to the caller instead - for
    /// data that is paged, where filtering only the rows on screen would
    /// silently miss everything on other pages (DynamoDB searches the whole
    /// table server-side with these).
    var onFilterApplied: (([FilterCondition]) -> Void)?
    /// Conditions to show as already applied when the grid appears - lets a
    /// caller that owns the filter (see `onFilterApplied`) recreate the grid
    /// without the header icons/popover forgetting the active filter.
    var initialFilterConditions: [FilterCondition] = []
    /// Called when one of the last few rows scrolls into view - for
    /// callers that load more rows on demand (infinite scrolling).
    var onReachEnd: (() -> Void)?
    /// Adds "Search with PartiQL" to the Filter Builder.
    var onSearchWithPartiQL: (([FilterCondition]) -> Void)?
    /// More names the Filter Builder offers besides the grid's columns -
    /// e.g. DynamoDB attributes that no row on screen has (sparse ones).
    var extraFilterColumnIDs: [String] = []

    /// The grid's columns plus the extra names, A → Z (case-insensitive).
    private var filterColumns: [DataGridColumn] {
        let known = Set(columns.map(\.id))
        let extra = extraFilterColumnIDs.filter { !known.contains($0) }.map { DataGridColumn(id: $0, title: $0) }
        return (columns + extra).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    @State private var columnWidths: [String: CGFloat] = [:]
    @State private var autoFitWidths: [String: CGFloat] = [:]
    @State private var appliedFilterConditions: [FilterCondition] = []
    @State private var activeFilterColumnID: String?
    @State private var draftConditions: [FilterCondition] = []
    /// Clicked row - highlighted until another row is clicked.
    @State private var selectedRowID: RowValue.ID?

    /// The ceiling `autoFitColumns` mode is allowed to reach *per column*
    /// - deliberately more generous than a column's own `maxWidth` (which
    /// exists to keep the *evenly-split* mode from letting one column
    /// dominate), since the whole point of auto-fit is to actually show
    /// the content instead of clipping it at a cap chosen for a different
    /// mode. Kept well below `manualFitMaxWidth` because this applies to
    /// every column at once - a single very long value shouldn't be able
    /// to push the whole grid that wide on its own.
    private let autoFitMaxWidth: CGFloat = 480
    /// The ceiling double-clicking one column's edge is allowed to reach -
    /// much higher than `autoFitMaxWidth` since it's an explicit, single-
    /// column "show me everything" request rather than every column
    /// sizing itself at once.
    private let manualFitMaxWidth: CGFloat = 900

    private var filteredRows: [RowValue] {
        guard onFilterApplied == nil, let filterValue, !appliedFilterConditions.isEmpty else { return rows }
        return rows.filter { row in
            evaluateFilterConditions(appliedFilterConditions, row: row) { row, columnID in
                // A name typed into the Filter Builder may not be a column on screen.
                let column = columns.first(where: { $0.id == columnID }) ?? DataGridColumn(id: columnID, title: columnID)
                return filterValue(row, column)
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow(availableWidth: geometry.size.width)
                        .frame(height: headerHeight)
                    Divider()
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            let visibleRows = filteredRows
                            ForEach(Array(visibleRows.enumerated()), id: \.element.id) { idx, row in
                                rowView(row, isEven: rowIsEven(idx), isSelected: row.id == selectedRowID, availableWidth: geometry.size.width)
                                    .onAppear {
                                        // LazyVStack only builds rows near the viewport, so a
                                        // row from the last few appearing means "near the end".
                                        if idx >= visibleRows.count - 5 { onReachEnd?() }
                                    }
                            }
                        }
                    }
                    .frame(height: max(0, geometry.size.height - headerHeight - 1))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear {
            if appliedFilterConditions.isEmpty, !initialFilterConditions.isEmpty {
                appliedFilterConditions = initialFilterConditions
            }
            recomputeAutoFitWidths()
        }
        .onChange(of: autoFitColumns) { _, _ in recomputeAutoFitWidths() }
        .onChange(of: rows.map(\.id)) { _, _ in recomputeAutoFitWidths() }
    }

    /// A user-driven width (manual drag, or double-click-to-fit) is capped
    /// at `manualFitMaxWidth`, not the tighter `column.maxWidth` - that
    /// cap exists for the passive evenly-split/auto-fit modes, not for
    /// something the user explicitly asked for by hand.
    private func effectiveManualMaxWidth(for column: DataGridColumn) -> CGFloat {
        max(column.maxWidth, manualFitMaxWidth)
    }

    private func width(for column: DataGridColumn, availableWidth: CGFloat) -> CGFloat {
        if let stored = columnWidths[column.id] {
            return min(effectiveManualMaxWidth(for: column), max(column.minWidth, stored))
        }
        if autoFitColumns, let fitted = autoFitWidths[column.id] {
            return fitted
        }
        let usable = max(0, availableWidth - actionsColumnWidth)
        let count = max(1, columns.count)
        return min(column.maxWidth, max(column.minWidth, usable / CGFloat(count)))
    }

    /// Measures each column's longest value (plus its header title) with
    /// the exact font the cells/header actually render in, and caches the
    /// result - computed once per data/columns/mode change (`.onAppear` +
    /// the `.onChange`s above) rather than inline inside `width(for:)`,
    /// which would otherwise re-scan every row for every column on every
    /// single cell's layout pass (an O(rows × columns) rescan for each of
    /// the O(rows × columns) cells being laid out).
    private func recomputeAutoFitWidths() {
        guard autoFitColumns, filterValue != nil else {
            if !autoFitWidths.isEmpty { autoFitWidths = [:] }
            return
        }
        var result: [String: CGFloat] = [:]
        for column in columns {
            result[column.id] = measuredFitWidth(for: column, ceiling: autoFitMaxWidth)
        }
        autoFitWidths = result
    }

    /// The width `column` needs to show its longest value/header in full,
    /// with the exact font the cells/header actually render in - shared by
    /// `recomputeAutoFitWidths()` (every column at once, only when
    /// `autoFitColumns` is on, capped at `ceiling` so one very long value
    /// doesn't dominate the whole grid while every other column is also
    /// auto-sizing) and double-clicking a single column's resize handle
    /// (one column, on demand, regardless of the mode, with a much higher
    /// `ceiling` since that's an explicit "fit this column, I mean it"
    /// request for just the one column).
    private func measuredFitWidth(for column: DataGridColumn, ceiling: CGFloat) -> CGFloat {
        guard let filterValue else { return column.minWidth }
        let headerFont = NSFont.boldSystemFont(ofSize: 12.5)
        let cellFont = NSFont.systemFont(ofSize: 12.5)
        var maxTextWidth = ceil((column.title as NSString).size(withAttributes: [.font: headerFont]).width)
        for row in rows {
            guard let text = filterValue(row, column), !text.isEmpty else { continue }
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: cellFont]).width)
            maxTextWidth = max(maxTextWidth, textWidth)
        }
        // Horizontal cell/header padding (8pt each side) plus room for the
        // header's title-to-icon spacing, search icon and resize handle,
        // so the title+icon never wrap/clip.
        let horizontalPadding: CGFloat = 16
        let headerChromeAllowance: CGFloat = 28
        let effectiveMax = max(column.maxWidth, ceiling)
        return min(effectiveMax, max(column.minWidth, maxTextWidth + horizontalPadding + headerChromeAllowance))
    }

    /// Double-clicking a column's edge fits *that* column to (essentially)
    /// its full content right now, as a manual override - available even
    /// when `autoFitColumns` is off, the same "double-click a column
    /// border to autosize it" affordance spreadsheets use. Uses a much
    /// higher ceiling than the passive auto-fit mode: this is one column
    /// the user explicitly asked to see in full, not every column sizing
    /// itself at once.
    private func autoFitSingleColumn(_ column: DataGridColumn) {
        columnWidths[column.id] = measuredFitWidth(for: column, ceiling: manualFitMaxWidth)
    }

    private func headerRow(availableWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                headerCell(column, availableWidth: availableWidth)
            }
            if actionsColumnWidth > 0 {
                Color.clear.frame(width: actionsColumnWidth)
            }
        }
        .background(Color.secondary.opacity(0.18))
    }

    private func headerCell(_ column: DataGridColumn, availableWidth: CGFloat) -> some View {
        let w = width(for: column, availableWidth: availableWidth)
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(column.title)
                    .font(.system(size: 12.5, weight: .bold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: column.alignment, vertical: .center))
                if filterValue != nil {
                    filterButton(for: column)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            DataGridColumnResizeHandle(
                minWidth: column.minWidth,
                maxWidth: effectiveManualMaxWidth(for: column),
                currentWidth: w,
                onChange: { newWidth in columnWidths[column.id] = newWidth },
                onDoubleClick: { autoFitSingleColumn(column) }
            )
        }
        .frame(width: w, alignment: .leading)
        .overlay(alignment: .trailing) { columnBorder }
    }

    /// A persistent, visible line at each column's right edge (header *and*
    /// every row - `rowView` applies the same overlay) - previously the
    /// only boundary indicator was the resize handle's cursor-on-hover, so
    /// where one column ended and the next began wasn't visible at rest.
    private var columnBorder: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 1)
    }

    /// Search icon that opens the shared `ColumnFilterBuilderView` popover,
    /// anchored to whichever column's icon was actually clicked
    /// (`activeFilterColumnID` drives one popover shared across all
    /// columns rather than a separate one per column). Filled/tinted when
    /// this column already has an applied condition, so an active filter
    /// stays visible after the popover closes.
    private func filterButton(for column: DataGridColumn) -> some View {
        let isActive = appliedFilterConditions.contains { $0.columnID == column.id }
        return Button {
            openFilterPopover(for: column)
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(HeaderSearchButtonStyle(isActive: isActive))
        .help("Filter \(column.title)")
        .popover(isPresented: Binding(
            get: { activeFilterColumnID == column.id },
            set: { if !$0 { activeFilterColumnID = nil } }
        )) {
            ColumnFilterBuilderView(
                columns: filterColumns,
                initialConditions: draftConditions,
                onSearch: { conditions in
                    appliedFilterConditions = conditions
                    activeFilterColumnID = nil
                    onFilterApplied?(conditions)
                },
                onDiscard: {
                    activeFilterColumnID = nil
                },
                onClearAll: {
                    activeFilterColumnID = nil
                    appliedFilterConditions = []
                    onFilterApplied?([])
                },
                onSearchWithPartiQL: onSearchWithPartiQL.map { handler in
                    { conditions in
                        activeFilterColumnID = nil
                        handler(conditions)
                    }
                }
            )
        }
    }

    /// Opens the shared filter popover for `column` - if there's still room
    /// under the 5-condition cap, layers on a new draft condition for this
    /// column (connected with AND to whatever's already applied); at the
    /// cap, just reopens with the existing conditions so the user can
    /// remove one instead.
    private func openFilterPopover(for column: DataGridColumn) {
        if appliedFilterConditions.count < FilterCondition.maxConditions {
            let newCondition = FilterCondition(
                logicalOperator: appliedFilterConditions.isEmpty ? nil : .and,
                columnID: column.id
            )
            draftConditions = appliedFilterConditions + [newCondition]
        } else {
            draftConditions = appliedFilterConditions
        }
        activeFilterColumnID = column.id
    }

    private func rowView(_ row: RowValue, isEven: Bool, isSelected: Bool, availableWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                // Padding has to land *inside* the `.frame` (pad, then
                // constrain) so this cell's total width is exactly `w` -
                // the same total the header cell's column occupies.
                // Padding outside the frame (frame, then pad) was adding
                // 16pt beyond `w` per row cell that the header never had,
                // so every row drifted further right than its header the
                // more columns there were - column boundaries and header
                // titles stopped lining up, and the grid overflowed wider
                // than it needed to.
                cell(row, column)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(width: width(for: column, availableWidth: availableWidth), alignment: Alignment(horizontal: column.alignment, vertical: .center))
                    .overlay(alignment: .trailing) { columnBorder }
            }
            if let rowActions {
                rowActions(row)
                    .frame(width: actionsColumnWidth)
            }
        }
        .modifier(DataGridRowChrome(isEven: isEven, isSelected: isSelected))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleTapRow?(row)
        }
        // Simultaneous, so selecting doesn't wait out the double-click delay.
        .simultaneousGesture(TapGesture().onEnded { selectedRowID = row.id })
        .modifier(DataGridOptionalContextMenu(row: row, builder: contextMenu))
    }
}

/// Row background: clearer zebra stripes, a hover tint, and a selected
/// row in the accent color with a bar on its left edge. Hover lives in
/// each row's own state so moving the mouse never re-renders the grid.
private struct DataGridRowChrome: ViewModifier {
    let isEven: Bool
    let isSelected: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(background)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                }
            }
            .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(isHovered ? 0.30 : 0.24) }
        if isHovered { return Color.accentColor.opacity(0.11) }
        return isEven ? Color.clear : Color.secondary.opacity(0.14)
    }
}

/// Applies `.contextMenu` only when the caller actually supplied one -
/// keeps `DataGridView` usable for read-only grids too.
private struct DataGridOptionalContextMenu<RowValue>: ViewModifier {
    let row: RowValue
    let builder: ((RowValue) -> AnyView)?

    func body(content: Content) -> some View {
        if let builder {
            content.contextMenu { builder(row) }
        } else {
            content
        }
    }
}

/// A column's own right-edge drag handle - each instance owns its drag-start
/// width locally, so dragging one column's edge never interferes with any
/// other column's state (unlike a single shared "which column is resizing"
/// flag would). Same hover-cursor + incremental-drag pattern as
/// `ResizableSplitView`'s divider.
///
/// **Dikkat — sürükleme jitter'ı, `columnWidths` bir `@Binding` iken.**
/// `columnWidths` eskiden `DynamoDBView`'ın kendi `@State`'ine bağlı bir
/// `@Binding`'ti; her `onChange` çağrısı (sürüklerken her piksel) sahibi
/// olan `DynamoDBView`'ın **tüm body'sini** geçersiz kılıyordu -
/// `scanResultsView(_:)` yeniden çağrılıp `columns`/`rows` dizileri sıfırdan
/// kuruluyor, tüm satırlar yeniden diff'leniyordu; bu maliyet her fare
/// hareketinde tekrarlanınca kare düşüyor, genişlik fare imlecinin gerisinde
/// kalıp sıçramalarla "yetişiyormuş" gibi görünüyordu. Çözüm: `columnWidths`
/// artık `DataGridView`'ın kendi iç `@State`'i - bir sürükleme artık sadece
/// bu view'ın body'sini geçersiz kılıyor, `DynamoDBView`'ınkini değil.
///
/// **Dikkat — asıl titreşimin (ve bazı tablolarda hiç sürüklenememenin)
/// kök nedeni: varsayılan `.local` koordinat uzayı.** `DragGesture()`
/// varsayılan olarak `translation`'ı bu view'ın **kendi** yerel koordinat
/// çerçevesine göre hesaplıyor - ama bu view'ın ekrandaki konumu tam olarak
/// sürüklemenin kendisinin değiştirdiği şey (genişlik değişince handle da
/// onunla birlikte kayıyor). Yani referans çerçeve, üzerine ölçüm yapılan
/// değerin kendisiyle birlikte hareket eden **taşınan bir hedef** - her
/// `onChange` sonrası handle birkaç piksel kayınca, bir sonraki
/// `onChanged` olayının "yerel" konumu bu kaymaya göre yeniden hesaplanıyor
/// ve `translation` sürükleme yönüyle tutarsız sıçramalar yapabiliyor
/// (bazı ekran/pencere konumlarında bu sıçramalar `min`/`max`'e çarpıp
/// orada "sıkışmış" gibi görünüyor - "bazı tablolarda hiç düzenleme
/// yapamıyorum" şikayetinin kaynağı buydu). Çözüm: `DragGesture(...,
/// coordinateSpace: .global)` - artık `translation`, handle'ın kendi
/// (taşınan) çerçevesine değil **ekranın sabit çerçevesine** göre
/// ölçülüyor, referans noktası sürüklemenin kendisinden etkilenmiyor.
private struct DataGridColumnResizeHandle: View {
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let currentWidth: CGFloat
    let onChange: (CGFloat) -> Void
    /// Double-clicking the handle fits this column to its content right
    /// now, regardless of the grid's `autoFitColumns` mode.
    var onDoubleClick: (() -> Void)?

    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragStartWidth ?? currentWidth
                        if dragStartWidth == nil { dragStartWidth = currentWidth }
                        let proposed = base + value.translation.width
                        onChange(min(maxWidth, max(minWidth, proposed)))
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { onDoubleClick?() }
            )
    }
}

/// The round search button on every filterable column header - a small
/// circle that fills with the accent color while the column has an active
/// filter, highlights on hover and dips on press like the app's buttons.
private struct HeaderSearchButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        SearchCircle(configuration: configuration, isActive: isActive)
    }

    private struct SearchCircle: View {
        let configuration: ButtonStyleConfiguration
        let isActive: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isActive ? Color.white : (isHovered ? Color.accentColor : Color.secondary))
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(isActive ? Color.accentColor : Color.accentColor.opacity(isHovered ? 0.18 : 0.08))
                )
                .overlay(Circle().stroke(Color.accentColor.opacity(isActive ? 0 : (isHovered ? 0.5 : 0.25)), lineWidth: 1))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}
