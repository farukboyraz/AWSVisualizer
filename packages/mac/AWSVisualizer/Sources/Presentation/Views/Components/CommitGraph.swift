import SwiftUI

/// `git log --graph`-style lanes for a newest-first commit list, from each
/// commit's `parents`. Every row knows the line segments in its top half
/// (from the row above down to the commit dot) and bottom half (from the
/// dot down to the row below), so rows drawn one under the other join up
/// into continuous branch lines: a branch splitting off, a merge joining,
/// and unrelated branches passing straight through.
struct CommitGraphRow {
    /// Lane of this commit's dot.
    let lane: Int
    /// (from lane at the top edge, to lane at the dot's height).
    let top: [(from: Int, to: Int)]
    /// (from lane at the dot's height, to lane at the bottom edge).
    let bottom: [(from: Int, to: Int)]
    let isMerge: Bool
}

struct CommitGraph {
    let rows: [String: CommitGraphRow]
    let laneCount: Int
    /// Child commit IDs per commit (the reverse of `parents`), loaded ones only.
    let children: [String: [String]]

    init(commits: [CodeCommitCommit]) {
        var rows: [String: CommitGraphRow] = [:]
        var children: [String: [String]] = [:]
        // Commit ID each lane is heading down to (nil = free lane).
        var lanes: [String?] = []
        var widest = 1

        for commit in commits {
            for parent in commit.parents { children[parent, default: []].append(commit.commitId) }

            let incoming = lanes.indices.filter { lanes[$0] == commit.commitId }
            let lane = incoming.first ?? lanes.firstIndex(where: { $0 == nil }) ?? lanes.count
            if lane == lanes.count { lanes.append(nil) }

            // Top half: lanes coming into this commit bend into its dot,
            // every other busy lane passes straight through.
            var top: [(Int, Int)] = []
            for i in lanes.indices {
                guard let target = lanes[i] else { continue }
                top.append(target == commit.commitId ? (i, lane) : (i, i))
            }

            // Bottom half: this commit's lane continues to its first parent,
            // further parents (a merge) branch out to other lanes - or join
            // a lane already heading to that parent.
            var next = lanes
            for i in incoming { next[i] = nil }
            next[lane] = nil
            var bottom: [(Int, Int)] = []
            var startedHere = Set<Int>()
            for (index, parent) in commit.parents.enumerated() {
                if let existing = next.firstIndex(where: { $0 == parent }) {
                    if index == 0, existing > lane, next[lane] == nil {
                        // Two lines meet at this parent: keep the leftmost
                        // lane (the main line) and bend the other into it.
                        next[existing] = nil
                        next[lane] = parent
                        startedHere.insert(lane)
                        bottom.append((lane, lane))
                        bottom.append((existing, lane))
                    } else {
                        bottom.append((lane, existing))
                    }
                } else if index == 0 {
                    next[lane] = parent
                    startedHere.insert(lane)
                    bottom.append((lane, lane))
                } else {
                    let target = next.firstIndex(where: { $0 == nil }) ?? next.count
                    if target == next.count { next.append(nil) }
                    next[target] = parent
                    startedHere.insert(target)
                    bottom.append((lane, target))
                }
            }
            for i in next.indices where next[i] != nil && !startedHere.contains(i) && lanes.indices.contains(i) && lanes[i] == next[i] {
                bottom.append((i, i))
            }
            while next.last.map({ $0 == nil }) == true { next.removeLast() }

            widest = max(widest, lanes.count, next.count)
            rows[commit.commitId] = CommitGraphRow(lane: lane, top: top, bottom: bottom, isMerge: commit.parents.count > 1)
            lanes = next
        }
        self.rows = rows
        self.laneCount = widest
        self.children = children
    }

    static let laneSpacing: CGFloat = 12
    static let palette: [Color] = [
        Color(hex: "#3B82F6"), Color(hex: "#F97316"), Color(hex: "#16A34A"), Color(hex: "#DB2777"),
        Color(hex: "#9333EA"), Color(hex: "#0891B2"), Color(hex: "#CA8A04"), Color(hex: "#DC2626"),
    ]

    static func color(_ lane: Int) -> Color { palette[lane % palette.count] }

    var width: CGFloat { CGFloat(laneCount) * Self.laneSpacing + 10 }
}

/// One row's slice of the graph. Drawn a little taller than the cell so
/// the lines meet the rows above and below across the table's row gaps.
struct CommitGraphCell: View {
    let row: CommitGraphRow
    var isSelected = false

    private static let overdraw: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let spacing = CommitGraph.laneSpacing
            let x = { (lane: Int) in CGFloat(lane) * spacing + spacing / 2 + 4 }
            let mid = size.height / 2
            for (from, to) in row.top {
                var path = Path()
                path.move(to: CGPoint(x: x(from), y: 0))
                path.addCurve(to: CGPoint(x: x(to), y: mid), control1: CGPoint(x: x(from), y: mid * 0.6), control2: CGPoint(x: x(to), y: mid * 0.4))
                context.stroke(path, with: .color(CommitGraph.color(from == to ? from : to)), lineWidth: 2)
            }
            for (from, to) in row.bottom {
                var path = Path()
                path.move(to: CGPoint(x: x(from), y: mid))
                path.addCurve(to: CGPoint(x: x(to), y: size.height), control1: CGPoint(x: x(from), y: mid + mid * 0.6), control2: CGPoint(x: x(to), y: mid + mid * 0.4))
                context.stroke(path, with: .color(CommitGraph.color(to)), lineWidth: 2)
            }
            let radius: CGFloat = row.isMerge ? 5 : 4
            let dot = CGRect(x: x(row.lane) - radius, y: mid - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dot), with: .color(CommitGraph.color(row.lane)))
            if row.isMerge {
                context.fill(Path(ellipseIn: dot.insetBy(dx: 2, dy: 2)), with: .color(.white))
            }
            if isSelected {
                context.stroke(Path(ellipseIn: dot.insetBy(dx: -2.5, dy: -2.5)), with: .color(.primary), lineWidth: 1.5)
            }
        }
        .padding(.vertical, -Self.overdraw)
    }
}
