import AppKit
import AxonCore
import Foundation

/// The badge the AX tree inspector draws over the element a person selects, so they can see which
/// on-screen control a tree node is. A plain borderless panel: it reads nothing from the screen
/// and needs no privacy grant.
enum VisualTargetState: String, Codable, Equatable, Sendable {
    case planned
}

struct VisualTarget: Equatable, Sendable {
    let frame: AXFrame
    let label: String
    let state: VisualTargetState
    let duration: TimeInterval

    init(frame: AXFrame, label: String, state: VisualTargetState, duration: TimeInterval) {
        self.frame = frame
        self.label = label
        self.state = state
        self.duration = duration
    }
}


final class AppKitTargetBadgeOverlay {
    private var panel: NSPanel?
    private var view: TargetBadgeView?

    init() {}

    @MainActor
    func showTarget(_ target: VisualTarget) {
        guard target.frame.width > 0, target.frame.height > 0 else {
            return
        }
        showTargetOnMainActor(target)
    }

    @MainActor
    private func showTargetOnMainActor(_ target: VisualTarget) {
        bootstrapApplication()

        let geometry = geometry(for: target.frame)

        let panel = panel ?? makePanel()
        let view = view ?? TargetBadgeView(frame: CGRect(origin: .zero, size: geometry.panelFrame.size))
        self.panel = panel
        self.view = view

        view.frame = CGRect(origin: .zero, size: geometry.panelFrame.size)
        view.targetRect = geometry.targetRect.offsetBy(dx: -geometry.panelFrame.minX, dy: -geometry.panelFrame.minY)
        view.labelRect = geometry.labelRect.offsetBy(dx: -geometry.panelFrame.minX, dy: -geometry.panelFrame.minY)
        view.label = target.label
        view.state = target.state
        panel.contentView = view
        panel.setFrame(geometry.panelFrame, display: true)
        panel.orderFrontRegardless()
        view.needsDisplay = true

        RunLoop.current.run(until: Date().addingTimeInterval(target.duration))
        panel.orderOut(nil)
    }

    @MainActor
    private func bootstrapApplication() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
    }

    @MainActor
    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    private func geometry(for frame: AXFrame) -> TargetBadgeGeometry {
        let virtualFrame = virtualScreenFrame()
        let targetRect = CGRect(
            x: frame.x,
            y: virtualFrame.maxY - frame.y - frame.height,
            width: frame.width,
            height: frame.height
        )
        let padding: CGFloat = 10
        let labelHeight: CGFloat = 24
        let labelWidth = max(targetRect.width + padding * 2, 120)
        let labelX = clamp(
            targetRect.minX - padding,
            lowerBound: virtualFrame.minX,
            upperBound: virtualFrame.maxX - labelWidth
        )
        let preferredAboveY = targetRect.maxY + 3
        let preferredBelowY = targetRect.minY - labelHeight - 3
        let preferredLabelY = preferredAboveY + labelHeight <= virtualFrame.maxY ? preferredAboveY : preferredBelowY
        let labelY = clamp(
            preferredLabelY,
            lowerBound: virtualFrame.minY,
            upperBound: virtualFrame.maxY - labelHeight
        )
        let labelRect = CGRect(x: labelX, y: labelY, width: labelWidth, height: labelHeight)
        let panelFrame = targetRect.insetBy(dx: -padding, dy: -padding)
            .union(labelRect)
            .integral
        return TargetBadgeGeometry(panelFrame: panelFrame, targetRect: targetRect, labelRect: labelRect)
    }

    private func virtualScreenFrame() -> CGRect {
        let screenFrames = NSScreen.screens.map(\.frame)
        guard var virtualFrame = screenFrames.first ?? NSScreen.main?.frame else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        for frame in screenFrames.dropFirst() {
            virtualFrame = virtualFrame.union(frame)
        }
        return virtualFrame
    }

    private func clamp(_ value: CGFloat, lowerBound: CGFloat, upperBound: CGFloat) -> CGFloat {
        if upperBound < lowerBound {
            return lowerBound
        }
        return min(max(value, lowerBound), upperBound)
    }
}

private struct TargetBadgeGeometry {
    let panelFrame: CGRect
    let targetRect: CGRect
    let labelRect: CGRect
}

private final class TargetBadgeView: NSView {
    var targetRect: CGRect = .zero
    var labelRect: CGRect = .zero
    var label: String = ""
    var state: VisualTargetState = .planned

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let color = color(for: state)
        let path = NSBezierPath(roundedRect: targetRect, xRadius: 7, yRadius: 7)
        color.withAlphaComponent(0.22).setFill()
        path.fill()
        color.setStroke()
        path.lineWidth = 3
        path.stroke()

        drawLabel(color: color)
    }

    private func drawLabel(color: NSColor) {
        let text = label.isEmpty ? "Axon" : label
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let textSize = text.size(withAttributes: attributes)
        let drawnLabelRect = CGRect(
            x: labelRect.minX,
            y: labelRect.minY,
            width: min(labelRect.width, textSize.width + 18),
            height: min(labelRect.height, 22)
        )

        let labelPath = NSBezierPath(roundedRect: drawnLabelRect, xRadius: 11, yRadius: 11)
        color.setFill()
        labelPath.fill()
        text.draw(
            in: CGRect(
                x: drawnLabelRect.minX + 9,
                y: drawnLabelRect.minY + 4,
                width: max(0, drawnLabelRect.width - 18),
                height: 14
            ),
            withAttributes: attributes
        )
    }

    private func color(for state: VisualTargetState) -> NSColor {
        NSColor.systemCyan
    }
}
