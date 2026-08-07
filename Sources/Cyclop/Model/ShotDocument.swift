import AppKit

/// What can be drawn on a shot.
enum ShotTool: String, CaseIterable, Identifiable {
    case select, rectangle, ellipse, arrow, line, pen, highlighter, text, pixelate

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .pixelate: return "mosaic"
        }
    }

    var title: String {
        switch self {
        case .select: return localized("Move")
        case .rectangle: return localized("Rectangle")
        case .ellipse: return localized("Ellipse")
        case .arrow: return localized("Arrow")
        case .line: return localized("Line")
        case .pen: return localized("Pen")
        case .highlighter: return localized("Highlighter")
        case .text: return localized("Text")
        case .pixelate: return localized("Pixelate")
        }
    }

    /// Shapes drawn by dragging a box out. The freehand ones and text are not.
    var isDragged: Bool {
        switch self {
        case .rectangle, .ellipse, .arrow, .line, .pixelate: return true
        case .select, .pen, .highlighter, .text: return false
        }
    }
}

/// One thing the user drew.
///
/// A value, not a view. Everything on the canvas is one of these in an ordered
/// list, which is what makes the two requirements the drawing itself does not
/// give you — moving something after it was drawn, and undoing — a matter of
/// editing an array rather than of repainting history.
struct ShotElement: Identifiable, Equatable {
    let id = UUID()
    var tool: ShotTool
    /// Where the shape lives, in the canvas's own coordinates. Boxes, text and
    /// pixelation live here, always standardised.
    ///
    /// Arrows and lines deliberately do *not*: they are two points, not a box,
    /// and a `CGRect` cannot hold them. `CGRect.maxX` reports the larger edge
    /// whatever sign the width has, so an arrow drawn up and to the left came
    /// back out of its own rectangle pointing down and to the right — which is
    /// why arrows used to snap to a corner of the region they were drawn in.
    var frame: CGRect = .zero
    /// Arrows and lines: the tail and the head, in that order and kept apart.
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    /// Freehand only.
    var points: [CGPoint] = []
    var text: String = ""
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3

    /// Whether a click at `point` should grab this element.
    ///
    /// Outlines are hit by their edge and not by the empty middle: a rectangle
    /// drawn around something is drawn *around* it, and grabbing it by the
    /// hole would make the thing inside unreachable. Filled ones — text,
    /// highlighter, pixelation — are hit anywhere, because there is no hole.
    func hits(_ point: CGPoint, tolerance: CGFloat = 6) -> Bool {
        switch tool {
        case .text, .highlighter, .pixelate:
            return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .rectangle:
            guard frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
            return !frame.insetBy(dx: tolerance, dy: tolerance).contains(point)
        case .ellipse:
            guard frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
            return !frame.insetBy(dx: tolerance * 2, dy: tolerance * 2).contains(point)
        case .arrow, .line:
            return distanceToSegment(point, start, end) < tolerance + lineWidth
        case .pen:
            guard frame.insetBy(dx: -tolerance * 2, dy: -tolerance * 2).contains(point) else { return false }
            return points.contains { hypot($0.x - point.x, $0.y - point.y) < tolerance + lineWidth }
        case .select:
            return false
        }
    }

    mutating func move(by delta: CGSize) {
        frame = frame.offsetBy(dx: delta.width, dy: delta.height)
        start = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
        end = CGPoint(x: end.x + delta.width, y: end.y + delta.height)
        for index in points.indices {
            points[index].x += delta.width
            points[index].y += delta.height
        }
    }

    /// Two ends rather than a box.
    var isDirected: Bool { tool == .arrow || tool == .line }

    /// What the selection outline is drawn around, and what a resize works on.
    var bounds: CGRect {
        guard isDirected else { return frame }
        return CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

private func distanceToSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
    let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
    return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
}

/// The annotations on one shot, and the ability to take them back.
///
/// Undo is a stack of whole snapshots rather than of inverse operations. The
/// list is small — a screenshot carries a handful of arrows, not a document —
/// and a snapshot cannot get out of step with the thing it is undoing, which
/// is the failure mode that makes hand-written inverse operations expensive.
@MainActor
final class ShotDocument: ObservableObject {
    @Published private(set) var elements: [ShotElement] = []
    @Published var selection: UUID?
    @Published var tool: ShotTool = .rectangle
    /// The colour and thickness new shapes are born with — and, when
    /// something is selected, the colour and thickness *it* takes on. A
    /// palette that only ever affects the next shape means the way to recolour
    /// the arrow you just drew is to delete it and draw it again.
    @Published var color: NSColor = .systemRed {
        didSet { applyStyleToSelection() }
    }
    @Published var lineWidth: CGFloat = 3 {
        didSet { applyStyleToSelection() }
    }

    /// Whether the style change should be its own undo step. It should not:
    /// dragging a slider is one intention, and one intention is one step.
    private var isRestyling = false

    private func applyStyleToSelection() {
        guard let selection, !isRestyling,
              let index = elements.firstIndex(where: { $0.id == selection }) else { return }
        isRestyling = true
        defer { isRestyling = false }
        elements[index].color = color
        elements[index].lineWidth = lineWidth
    }

    /// Picking something up adopts its style, the way every drawing tool does:
    /// select a red arrow and the palette shows red, so the next change starts
    /// from what is actually there rather than from what was last chosen.
    func adoptStyle(of element: ShotElement) {
        isRestyling = true
        color = element.color
        lineWidth = element.lineWidth
        isRestyling = false
    }

    private var undoStack: [[ShotElement]] = []
    private var redoStack: [[ShotElement]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEmpty: Bool { elements.isEmpty }

    func add(_ element: ShotElement) {
        checkpoint()
        elements.append(element)
        selection = element.id
    }

    /// For the element currently being dragged out, which is not on the list
    /// yet — it is drawn live and committed on mouse-up.
    func replaceLast(_ element: ShotElement) {
        guard let index = elements.firstIndex(where: { $0.id == element.id }) else { return }
        elements[index] = element
    }

    func update(_ element: ShotElement) {
        guard let index = elements.firstIndex(where: { $0.id == element.id }) else { return }
        elements[index] = element
    }

    /// Taken once at the start of a gesture, not per mouse-moved event —
    /// otherwise one drag of one arrow leaves fifty steps to undo.
    func beginGesture() {
        checkpoint()
    }

    func element(_ id: UUID?) -> ShotElement? {
        guard let id else { return nil }
        return elements.first { $0.id == id }
    }

    /// Topmost first: what is drawn last is on top, and what is on top is what
    /// a click means.
    func hitTest(_ point: CGPoint) -> ShotElement? {
        elements.reversed().first { $0.hits(point) }
    }

    func removeSelected() {
        guard let selection else { return }
        checkpoint()
        elements.removeAll { $0.id == selection }
        self.selection = nil
    }

    func removeAll() {
        guard !elements.isEmpty else { return }
        checkpoint()
        elements.removeAll()
        selection = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(elements)
        elements = previous
        selection = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(elements)
        elements = next
        selection = nil
    }

    private func checkpoint() {
        undoStack.append(elements)
        redoStack.removeAll()
        // Deep enough to cover any session with a screenshot, shallow enough
        // that nothing accumulates: this object dies with the shot anyway.
        if undoStack.count > 50 { undoStack.removeFirst() }
    }
}
