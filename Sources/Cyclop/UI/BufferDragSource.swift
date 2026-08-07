import AppKit
import SwiftUI

/// Drag handle for the file rows of the buffer.
///
/// SwiftUI's `onDrag` hands back a single `NSItemProvider`, so it can never
/// carry more than one file. Dragging a selection needs an AppKit dragging
/// session with one `NSDraggingItem` per URL, which is what this overlay
/// starts. It also owns the click handling, because selection and dragging
/// come from the same mouse-down.
struct BufferDragSource: NSViewRepresentable {
    /// Files to drag: the whole selection if this row is part of it, else
    /// just this row.
    var urls: () -> [URL]
    var onClick: (NSEvent.ModifierFlags) -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.urls = urls
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.urls = urls
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
    }

    final class DragView: NSView, NSDraggingSource {
        var urls: () -> [URL] = { [] }
        var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
        var onDoubleClick: () -> Void = {}

        private var mouseDownPoint: NSPoint?
        private var dragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let start = mouseDownPoint else { return }
            let delta = hypot(
                event.locationInWindow.x - start.x,
                event.locationInWindow.y - start.y
            )
            guard delta > 3 else { return }

            let files = urls()
            guard !files.isEmpty else { return }
            dragging = true

            let items = files.enumerated().map { index, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                // Fan the icons out slightly so a group reads as a stack.
                let offset = CGFloat(index) * 9
                item.setDraggingFrame(
                    NSRect(x: offset, y: -offset, width: 48, height: 48),
                    contents: icon
                )
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                mouseDownPoint = nil
                dragging = false
            }
            guard !dragging else { return }
            if event.clickCount >= 2 {
                onDoubleClick()
            } else {
                onClick(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            }
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .move, .link, .generic] : []
        }
    }
}
