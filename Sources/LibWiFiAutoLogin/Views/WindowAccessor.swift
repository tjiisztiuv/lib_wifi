import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    @Binding var isAlwaysOnTop: Bool
    let snapLeftTrigger: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.configureIfNeeded(window: window, isAlwaysOnTop: isAlwaysOnTop)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            context.coordinator.configureIfNeeded(window: window, isAlwaysOnTop: isAlwaysOnTop)
            window.level = isAlwaysOnTop ? .floating : .normal
            if context.coordinator.lastSnapTrigger != snapLeftTrigger {
                context.coordinator.lastSnapTrigger = snapLeftTrigger
                context.coordinator.moveToLeftEdge(window: window)
            }
        }
    }

    final class Coordinator {
        private var hasPositioned = false
        var lastSnapTrigger = 0

        func configureIfNeeded(window: NSWindow, isAlwaysOnTop: Bool) {
            window.level = isAlwaysOnTop ? .floating : .normal
            guard !hasPositioned else { return }
            hasPositioned = true
            moveToLeftEdge(window: window)
        }

        func moveToLeftEdge(window: NSWindow) {
            guard let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            let size = window.frame.size
            let x = visible.minX + 36
            let y = max(visible.minY + 20, visible.midY - size.height / 2)
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}
