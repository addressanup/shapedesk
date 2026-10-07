import AppKit
import SwiftUI

/// The menu bar icon and the panel that drops down from it.
///
/// This replaces SwiftUI's `MenuBarExtra(.window)`, which places its window
/// from the status item's reported frame. That frame can be stale or
/// off-screen (full-screen spaces, an auto-hiding menu bar, menu bar managers,
/// status items drawn by the system's MenuBarAgent), and the window then opens
/// far outside the display. Here the panel is placed each time it opens and
/// kept inside the visible area of the screen that was clicked.
@MainActor
final class MenuBarPanel: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = DropDownPanel(contentRect: .zero,
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: true)
    private let onOpen: () -> Void
    private var clickMonitor: Any?
    /// Uptime when a click elsewhere or a focus change last closed the panel.
    private var dismissedAt: TimeInterval = 0

    init(symbolName: String, label: String, onOpen: @escaping () -> Void,
         @ViewBuilder content: () -> some View) {
        self.onOpen = onOpen
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: content().background(PanelBackground()))
    }

    @objc private func toggle() {
        if panel.isVisible {
            close()
        } else if ProcessInfo.processInfo.systemUptime - dismissedAt > 0.3 {
            open()
        }
        // Otherwise this click is the one that just dismissed the panel: on
        // recent macOS another process draws the menu bar, so a click on the
        // icon also counts as a click outside. Leave the panel closed.
    }

    func open() {
        guard !panel.isVisible else { return }
        onOpen()

        let mouseTypes: [NSEvent.EventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        let clicked = NSApp.currentEvent.map { mouseTypes.contains($0.type) } ?? false
        let placement = PanelPlacement(itemFrame: itemFrame,
                                       click: clicked ? NSEvent.mouseLocation : nil,
                                       screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) })
        // Later content height changes keep this top edge; AppKit resizes
        // hosting-view windows downward.
        panel.setFrame(placement.frame(for: panel.contentView?.fittingSize ?? .zero), display: false)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)

        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    func windowDidResize(_ notification: Notification) {
        panel.invalidateShadow()
    }

    /// The status item's frame in screen coordinates, as AppKit reports it.
    private var itemFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func dismiss() {
        guard panel.isVisible else { return }
        dismissedAt = ProcessInfo.processInfo.systemUptime
        close()
    }
}

/// Where the panel goes: left-aligned just under the status item, or under
/// the click when the item's reported frame can't be trusted, and always
/// inside the visible area (menu bar and Dock excluded) of that screen.
struct PanelPlacement {
    private let left: CGFloat
    private let top: CGFloat
    private let bounds: NSRect

    init(itemFrame: NSRect?, click: NSPoint?, screens: [(frame: NSRect, visible: NSRect)]) {
        let anchor: NSRect?
        if let item = itemFrame,
           screens.contains(where: { $0.frame.intersects(item) }),
           click.map({ item.insetBy(dx: -8, dy: -20).contains($0) }) ?? true {
            anchor = item
        } else if let click {
            anchor = NSRect(origin: click, size: .zero)
        } else {
            anchor = nil
        }

        let screen = anchor.flatMap { anchor in
            let mid = NSPoint(x: anchor.midX, y: anchor.midY)
            return screens.min { Self.distance(mid, $0.frame) < Self.distance(mid, $1.frame) }
        } ?? screens.first ?? (frame: .zero, visible: .zero)

        bounds = screen.visible.insetBy(dx: 4, dy: 0)
        left = anchor?.minX ?? bounds.maxX
        top = min(anchor?.minY ?? bounds.maxY, bounds.maxY) - 1
    }

    func frame(for size: NSSize) -> NSRect {
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        return NSRect(x: max(bounds.minX, min(left, bounds.maxX - width)),
                      y: max(bounds.minY, top - height),
                      width: width, height: height)
    }

    private static func distance(_ point: NSPoint, _ rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

private final class DropDownPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Rounded, translucent backing like the system's own menu bar panels.
private struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.roundedMask(radius: 12)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
