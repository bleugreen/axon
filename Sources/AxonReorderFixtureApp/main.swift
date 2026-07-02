import AppKit

@main
final class ReorderFixtureApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = ReorderFixtureApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 360, height: 280),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Axon Reorder Fixture"
        window.contentView = ReorderListView(frame: NSRect(x: 0, y: 0, width: 360, height: 280))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

final class ReorderListView: NSView {
    private var rows = ["Alpha", "Bravo", "Charlie", "Delta"]
    private var draggedIndex: Int?
    private let rowHeight: CGFloat = 44
    private let inset: CGFloat = 24

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityIdentifier("reorder-list")
        setAccessibilityRole(.list)
        setAccessibilityLabel("Reorderable list")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        for (index, title) in rows.enumerated() {
            let rect = rowRect(index)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).stroke()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 17, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
            title.draw(at: NSPoint(x: rect.minX + 14, y: rect.minY + 12), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        draggedIndex = rowIndex(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let source = draggedIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let target = rowIndex(at: point), target != source else { return }
        let row = rows.remove(at: source)
        rows.insert(row, at: target)
        draggedIndex = target
        setNeedsDisplay(bounds)
        setAccessibilityValue(rows.joined(separator: ", "))
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func mouseUp(with event: NSEvent) {
        draggedIndex = nil
    }

    override func accessibilityValue() -> Any? {
        rows.joined(separator: ", ")
    }

    override func accessibilityChildren() -> [Any]? {
        rows.enumerated().map { index, title in
            let row = NSAccessibilityElement()
            row.setAccessibilityRole(.row)
            row.setAccessibilityLabel(title)
            row.setAccessibilityValue(title)
            row.setAccessibilityFrameInParentSpace(rowRect(index))
            row.setAccessibilityParent(self)
            return row
        }
    }

    private func rowRect(_ index: Int) -> NSRect {
        NSRect(
            x: inset,
            y: inset + CGFloat(index) * (rowHeight + 10),
            width: bounds.width - inset * 2,
            height: rowHeight
        )
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        rows.indices.first { rowRect($0).contains(point) }
    }
}
