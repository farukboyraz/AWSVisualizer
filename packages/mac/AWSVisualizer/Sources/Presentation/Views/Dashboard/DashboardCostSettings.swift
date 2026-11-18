import SwiftUI

/// What the gear on the spend panel opens: every filter of the spend
/// sections in one place - Daily / Monthly / One month, the month or range,
/// and (when the chart is on) its type and colors. Changes apply right away
/// and last for this session; Settings › Display › Dashboard keeps the defaults.
struct DashboardCostSettingsPanel: View {
    let cost: DashboardCostSelection
    let language: AppLanguage
    /// The chart's own options (off when only spend by service is shown).
    var showsChartOptions = true

    private static let segmentWidth: CGFloat = 74
    private static let segmentHeight: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.dashSpendSettings).font(.headline)
            row(language.dashSpendView) {
                MultiSwitchBox(selection: cost.$view, options: DashboardPrefs.CostView.allCases.map { ($0, language.costViewLabel($0)) }, segmentWidth: Self.segmentWidth, height: Self.segmentHeight)
            }
            if cost.view == .month {
                row(language.dashSpendPeriod) {
                    Picker("", selection: cost.$month) {
                        ForEach(DashboardContent.monthKeys, id: \.self) { Text(language.monthName($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
            } else if cost.view == .monthly {
                row(language.dashSpendPeriod) {
                    Picker("", selection: cost.$months) {
                        ForEach(DashboardPrefs.monthRanges, id: \.self) { Text(language.monthsLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
            }
            if showsChartOptions {
                Divider()
                row(language.dashSpendChartType) { chartStyleSwitch }
                row(language.dashSpendColors) {
                    MultiSwitchBox(selection: cost.$singleColor, options: [(false, language.dashMultiColor), (true, language.dashSingleColor)], segmentWidth: Self.segmentWidth, height: Self.segmentHeight)
                }
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: Self.segmentHeight)
    }

    /// Bars / lines / points: icon segments, the current one filled.
    private var chartStyleSwitch: some View {
        HStack(spacing: 2) {
            ForEach(DashboardPrefs.ChartStyle.allCases, id: \.self) { style in
                Button { cost.chartStyle = style } label: {
                    Image(systemName: style == .bar ? "chart.bar.fill" : style == .line ? "chart.xyaxis.line" : "chart.dots.scatter")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 22)
                        .foregroundStyle(cost.chartStyle == style ? Color.white : Color.secondary)
                        .background(cost.chartStyle == style ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(language.chartStyleLabel(style))
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
