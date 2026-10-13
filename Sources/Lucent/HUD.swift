import AppKit

/// Small brightness HUD in the top-right corner, styled like the system one.
final class HUD {
    private var panel: NSPanel?
    private let bar = Bar()
    private let label = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "Brightness")
    private var hideWork: DispatchWorkItem?

    func show(nits: Double, fraction: Double, xdr: Bool, on screen: NSScreen) {
        let panel = self.panel ?? build()
        label.stringValue = "\(Int(nits.rounded())) nits"
        title.stringValue = xdr ? "XDR Brightness" : "Brightness"
        bar.fraction = fraction
        let size = panel.frame.size
        let vis = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vis.maxX - size.width - 12, y: vis.maxY - size.height - 10))
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel?.animator().alphaValue = 0 },
                                                 completionHandler: { if panel?.alphaValue == 0 { panel?.orderOut(nil) } })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func build() -> NSPanel {
        let rect = NSRect(x: 0, y: 0, width: 280, height: 64)
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let fx = NSVisualEffectView(frame: rect)
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 18
        fx.layer?.masksToBounds = true

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 16, y: 36, width: 150, height: 18)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.frame = NSRect(x: 150, y: 37, width: 114, height: 16)

        let icon = NSImageView(image: NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = .labelColor
        icon.frame = NSRect(x: 14, y: 11, width: 18, height: 18)
        bar.frame = NSRect(x: 40, y: 15, width: 224, height: 10)

        [title, label, icon, bar].forEach(fx.addSubview)
        p.contentView = fx
        panel = p
        return p
    }

    private final class Bar: NSView {
        var fraction: Double = 0 { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.height / 2
            NSColor.labelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
            var fill = bounds; fill.size.width = max(bounds.height, bounds.width * fraction)
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
            // Mark the native maximum (500 nits) in the middle of the bar.
            let mid = NSRect(x: bounds.midX - 0.75, y: 1, width: 1.5, height: bounds.height - 2)
            (fraction > 0.5 ? NSColor.windowBackgroundColor : NSColor.labelColor).withAlphaComponent(0.6).setFill()
            mid.fill()
        }
    }
}
