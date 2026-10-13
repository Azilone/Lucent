import AppKit
import MetalKit

/// Extends brightness past SDR white without capturing the screen:
/// a 1-pt EDR pixel puts the panel in extended-range mode, then the display's gamma
/// table is scaled above 1.0. macOS restores gamma tables itself when the process
/// exits, so a crash can never leave the screen boosted.
final class Booster {
    static let sdrNits: Double = 500
    /// Hard ceiling (1000 nits): the XDR panel's sustained full-screen limit.
    static let maxLinearRatio: Double = 2.0

    private(set) var displayID: CGDirectDisplayID?
    private var screen: NSScreen?
    private var base: (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])?
    private var current: Double = 1
    private var target: Double = 1
    private var animation: Timer?
    private var keepAlive: Timer?
    private let pixel = EDRPixel()
    /// Called when the safety net trips; the owner should disable boosting.
    var onSafetyStop: (() -> Void)?

    /// The built-in XDR panel (or any display reporting EDR headroom).
    static func xdrScreen() -> (NSScreen, CGDirectDisplayID)? {
        NSScreen.screens
            .filter { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
            .compactMap { s in (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { (s, $0) } }
            .sorted { a, _ in CGDisplayIsBuiltin(a.1) != 0 }
            .first
    }

    func attach() {
        guard let (screen, id) = Self.xdrScreen() else { detach(); return }
        let changed = id != displayID
        self.screen = screen; displayID = id
        if changed { base = nil; pixel.hide() }
        apply(current)
        if keepAlive == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.maintain() }
            t.tolerance = 0.3
            RunLoop.main.add(t, forMode: .common)
            keepAlive = t
        }
    }

    func detach() {
        animation?.invalidate(); animation = nil
        keepAlive?.invalidate(); keepAlive = nil
        pixel.hide()
        if current > 1 { CGDisplayRestoreColorSyncSettings() }
        current = 1; target = 1; displayID = nil; screen = nil; base = nil
    }

    /// Smoothly moves to `nits` (≥ 500).
    func set(nits: Double, animated: Bool = true) {
        target = max(1, nits / Self.sdrNits)
        animation?.invalidate(); animation = nil
        guard animated, displayID != nil else { apply(target); return }
        let from = current, start = CACurrentMediaTime(), duration = 0.18
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let p = min(1, (CACurrentMediaTime() - start) / duration)
            let eased = 1 - pow(1 - p, 3)
            self.apply(from + (self.target - from) * eased)
            if p >= 1 {
                timer.invalidate(); self.animation = nil
                NSLog("Lucent: boost ×%.3f (%.0f nits)", self.current, self.current * Self.sdrNits)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        animation = t
    }

    private func apply(_ factor: Double) {
        current = factor
        guard let id = displayID, let screen else { return }
        if factor <= 1.0001 {
            pixel.hide()
            if let base { CGSetDisplayTransferByTable(id, UInt32(base.r.count), base.r, base.g, base.b) }
            return
        }
        if base == nil { base = Self.sdrBase(id) }
        guard let base else { return }
        // `factor` is a linear luminance ratio. Never ask for more than the panel can
        // currently show (that clips to white), and convert to the table's encoded
        // space: the gamma table is applied to gamma-encoded values (≈ 2.2).
        let headroom = max(1, Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
        let linear = min(factor, headroom, Self.maxLinearRatio)
        pixel.show(on: screen, value: linear)
        let k = Float(pow(linear, 1 / 2.2))
        CGSetDisplayTransferByTable(id, UInt32(base.r.count), base.r.map { $0 * k }, base.g.map { $0 * k }, base.b.map { $0 * k })
    }

    /// macOS (ColorSync, display wake…) can reset the gamma table: put the boost back.
    /// Always recomputed from the stored SDR `base`, never from the live table, so it
    /// can't compound even if the system rewrites the table while in EDR mode.
    private func maintain() {
        guard animation == nil, current > 1.0001, let id = displayID, let base, let t = Self.readTable(id) else { return }
        // Safety net: the live table must never exceed our ceiling.
        let ceiling = (base.r.last ?? 1) * Float(pow(Self.maxLinearRatio, 1 / 2.2)) + 0.02
        if let last = t.r.last, last > ceiling {
            NSLog("Lucent: SAFETY gamma %.3f above ceiling %.3f, restoring", last, ceiling)
            onSafetyStop?()
            return
        }
        let expected = (base.r.last ?? 1) * Float(pow(min(current, Self.maxLinearRatio), 1 / 2.2))
        guard abs((t.r.last ?? 0) - expected) > 0.01 else { return }
        NSLog("Lucent: gamma table changed (last %.3f, expected %.3f), reapplying", t.r.last ?? -1, expected)
        apply(current)
    }

    /// The display's normal (SDR) table. Captured only when it looks like one; otherwise
    /// ColorSync defaults are restored first so a boosted table is never taken as base.
    private static func sdrBase(_ id: CGDirectDisplayID) -> (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])? {
        if let t = readTable(id), let last = t.r.last, (0.9...1.0001).contains(last) { return t }
        CGDisplayRestoreColorSyncSettings()
        guard let t = readTable(id), let last = t.r.last, (0.9...1.0001).contains(last) else { return nil }
        return t
    }

    private static func readTable(_ id: CGDirectDisplayID) -> (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])? {
        var r = [CGGammaValue](repeating: 0, count: 1024), g = r, b = r, n: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, 1024, &r, &g, &b, &n) == .success, n > 0 else { return nil }
        let c = Int(n)
        return (Array(r.prefix(c)), Array(g.prefix(c)), Array(b.prefix(c)))
    }
}

/// 1×1 pt window in the bottom-left corner showing a single EDR value.
private final class EDRPixel: NSObject, MTKViewDelegate {
    private var window: NSWindow?
    private var view: MTKView?
    private var queue: MTLCommandQueue?

    func show(on screen: NSScreen, value: Double) {
        if window == nil || window?.screen != screen { build(on: screen) }
        view?.clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: 1)
        view?.draw()
    }

    func hide() {
        window?.orderOut(nil)
        window = nil; view = nil
    }

    private func build(on screen: NSScreen) {
        hide()
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        queue = device.makeCommandQueue()
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1)
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.sharingType = .none
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let mtk = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        mtk.colorPixelFormat = .rgba16Float
        mtk.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        mtk.isPaused = true
        mtk.enableSetNeedsDisplay = false
        mtk.delegate = self
        (mtk.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        win.contentView = mtk
        win.orderFrontRegardless()
        window = win; view = mtk
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue?.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
