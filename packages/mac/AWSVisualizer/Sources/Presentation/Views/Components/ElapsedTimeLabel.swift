import SwiftUI

/// How long a query/search has taken - running time across Resume clicks
/// (paused time between Stop and Resume doesn't count).
struct QueryStopwatch: Equatable {
    private(set) var accumulated: TimeInterval = 0
    private(set) var runningSince: Date?

    var hasValue: Bool { runningSince != nil || accumulated > 0 }

    mutating func start(reset: Bool) {
        if reset { accumulated = 0 }
        if runningSince == nil { runningSince = Date() }
    }

    mutating func stop() {
        if let since = runningSince { accumulated += Date().timeIntervalSince(since) }
        runningSince = nil
    }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        accumulated + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    static func format(_ t: TimeInterval) -> String {
        if t < 1 { return "\(Int((t * 1000).rounded())) ms" }
        if t < 60 { return String(format: "%.1f s", t) }
        return "\(Int(t) / 60) m \(Int(t) % 60) s"
    }
}

/// "⏱ 1.4 s" next to a result count - ticks live while running.
struct ElapsedTimeLabel: View {
    let stopwatch: QueryStopwatch

    var body: some View {
        if stopwatch.runningSince != nil {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                label(stopwatch.elapsed(at: context.date))
            }
        } else if stopwatch.hasValue {
            label(stopwatch.elapsed())
        }
    }

    private func label(_ t: TimeInterval) -> some View {
        Label(QueryStopwatch.format(t), systemImage: "stopwatch")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .help("Total time for this query, including every page read")
    }
}
