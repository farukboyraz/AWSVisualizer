import SwiftUI
import Charts

/// CloudWatch graphs (G2): the console's Monitoring tab. A range picker
/// (1h … 1w) over a grid of charts; every series of the grid comes from one
/// `POST /api/cloudwatch/metric-data` request (split by 20 if needed).
/// Used by the ResourcePage `charts` and the Lambda / RDS / DynamoDB
/// Monitor tabs.
struct MetricChartGrid: View {
    let charts: [MetricChartSpec]
    /// Changes when the resource changes, so the grid reloads.
    var reloadKey: String = ""

    @Environment(AppState.self) private var appState
    @Environment(\.apiService) private var api

    @State private var range: MetricRange = .hours3
    @State private var series: [String: MetricSeries] = [:]
    @State private var period: Int?
    @State private var messages: [String] = []
    @State private var isLoading = false
    @State private var failure: String?
    @State private var refreshCount = 0

    private var language: AppLanguage { appState.language }

    /// Request ids are prefixed per chart so charts can reuse "m0", "m1".
    private var requests: [(chart: Int, query: MetricQuery)] {
        charts.enumerated().flatMap { ci, chart in
            chart.queries.enumerated().map { qi, q in (ci, q.withId("c\(ci)_\(qi)")) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TabBar(tabs: MetricRange.allCases, selection: $range, style: .pills, title: { language.metricRangeTitle($0) })
                if let period {
                    Text(language.metricsPeriod(period)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                RefreshButton(compactSize: 22, isDisabled: isLoading, help: language.metricsRefresh) { refreshCount += 1 }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !messages.isEmpty {
                Text(messages.prefix(3).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                ForEach(Array(charts.enumerated()), id: \.offset) { ci, chart in
                    MetricChartCard(
                        spec: chart,
                        series: chart.queries.indices.compactMap { series["c\(ci)_\($0)"] },
                        isLoading: isLoading && series.isEmpty,
                        language: language
                    )
                }
            }
        }
        .task(id: "\(reloadKey)|\(range.rawValue)|\(refreshCount)|\(appState.currentProfile)|\(appState.currentRegion)") { await load() }
    }

    private func load() async {
        guard !charts.isEmpty else { return }
        isLoading = true
        failure = nil
        do {
            var merged: [String: MetricSeries] = [:]
            var notes: [String] = []
            var lastPeriod: Int?
            let all = requests.map(\.query)
            for start in stride(from: 0, to: all.count, by: 20) {
                let chunk = Array(all[start..<min(start + 20, all.count)])
                let res = try await api.getMetricData(profile: appState.currentProfile, region: appState.currentRegion, range: range, queries: chunk)
                for s in res.series { merged[s.id] = s }
                notes += res.messages
                lastPeriod = res.period
            }
            series = merged
            messages = notes
            period = lastPeriod
        } catch where error.isCancellation {
            // The range or resource changed mid-request; the new load takes over.
            return
        } catch {
            series = [:]
            failure = error.friendlyMessage
        }
        isLoading = false
    }
}

/// One chart: title, last value, line per series and a hover read-out.
struct MetricChartCard: View {
    let spec: MetricChartSpec
    let series: [MetricSeries]
    let isLoading: Bool
    let language: AppLanguage

    @State private var hoverDate: Date?

    private var hasData: Bool { series.contains { !$0.points.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(spec.title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                if let latest = latestText { Text(latest).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !hasData {
                    Text(language.metricsNoData).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    chart
                }
            }
            .frame(height: 150)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }

    private var chart: some View {
        Chart {
            ForEach(series, id: \.id) { s in
                ForEach(s.points, id: \.t) { p in
                    LineMark(x: .value("Time", p.date), y: .value(s.label, p.v))
                        .foregroundStyle(by: .value("Series", s.label))
                        .interpolationMethod(.monotone)
                }
            }
            if let hoverDate {
                RuleMark(x: .value("Time", hoverDate))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        readout(at: hoverDate)
                    }
            }
        }
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(MetricFormat.value(v, unit: spec.unit, compact: true)) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geo[plot].origin.x
                            hoverDate = (proxy.value(atX: x) as Date?).flatMap(nearestDate)
                        case .ended:
                            hoverDate = nil
                        }
                    }
            }
        }
    }

    /// The data point closest to the pointer (any series).
    private func nearestDate(_ date: Date) -> Date? {
        series.flatMap(\.points).map(\.date).min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }

    private func readout(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2.bold())
            ForEach(series, id: \.id) { s in
                if let p = s.points.first(where: { $0.date == date }) {
                    Text("\(series.count > 1 ? s.label + ": " : "")\(MetricFormat.value(p.v, unit: spec.unit, compact: false))")
                        .font(.caption2.monospacedDigit())
                }
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Latest value of a single-series chart (the number the console shows next to the title).
    private var latestText: String? {
        guard series.count == 1, let last = series.first?.points.last else { return nil }
        return MetricFormat.value(last.v, unit: spec.unit, compact: false)
    }
}

enum MetricFormat {
    static func value(_ v: Double, unit: String?, compact: Bool) -> String {
        switch unit {
        case "%":
            return String(format: v < 10 ? "%.1f%%" : "%.0f%%", v)
        case "Bytes":
            return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory)
        case "ms":
            return v < 1000 ? String(format: v < 10 ? "%.1f ms" : "%.0f ms", v) : String(format: "%.2f s", v / 1000)
        case "Seconds":
            return v < 60 ? String(format: "%.1f s", v) : String(format: "%.1f min", v / 60)
        default:
            return number(v, compact: compact)
        }
    }

    static func number(_ v: Double, compact: Bool) -> String {
        let a = abs(v)
        if compact || a >= 10_000 {
            if a >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
            if a >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
            if a >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        }
        if v == v.rounded() { return String(format: "%.0f", v) }
        return String(format: a < 1 ? "%.3f" : "%.2f", v)
    }
}
