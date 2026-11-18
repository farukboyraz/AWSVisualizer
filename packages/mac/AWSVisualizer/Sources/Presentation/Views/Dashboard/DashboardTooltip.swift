import SwiftUI

/// Downward-pointing triangle under the bubble.
struct TooltipArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

/// Keeps a hover bubble up while the pointer is on the target *or* on the
/// bubble, and hides it shortly after it leaves both.
@Observable
final class TooltipHoverState {
    var onTarget = false
    var onBubble = false
    private var hideTask: Task<Void, Never>?

    var isVisible: Bool { onTarget || onBubble || lingering }
    private var lingering = false

    func set(target: Bool) { onTarget = target; scheduleHide() }
    func set(bubble: Bool) { onBubble = bubble; scheduleHide() }

    private func scheduleHide() {
        hideTask?.cancel()
        if onTarget || onBubble { lingering = true; return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.lingering = false
        }
    }
}
