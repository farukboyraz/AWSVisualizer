import SwiftUI
import AppKit

/// Calls `action` when the middle mouse button is pressed and released over
/// this view (SwiftUI has no gesture for it). Put it in a `.background`: it
/// takes no clicks itself, so everything on top keeps working.
struct MiddleClickMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.action = action
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.action = action
    }

    final class MonitorView: NSView {
        var action: () -> Void = {}
        private var monitor: Any?
        private var pressedHere = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            pressedHere = false
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.buttonNumber == 2, event.window === window else { return event }
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            if event.type == .otherMouseDown {
                pressedHere = inside
                return inside ? nil : event
            }
            let clicked = pressedHere && inside
            pressedHere = false
            guard clicked else { return event }
            // After the event: closing the tab removes this view and its monitor.
            let action = action
            DispatchQueue.main.async { action() }
            return nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
