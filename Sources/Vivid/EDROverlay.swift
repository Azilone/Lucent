import AppKit
import MetalKit

/// Tiny always-on-top window that renders one EDR (>1.0) pixel.
/// Its presence makes macOS put the display into extended-range mode,
/// which is what lets the boosted gamma table go beyond SDR white.
final class EDROverlay {
    private var window: NSWindow?
    private var view: MTKView?
    private var renderer: Renderer?

    func show(on screen: NSScreen) {
        hide()
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - 2, width: 2, height: 2)
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let mtk = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        mtk.colorPixelFormat = .rgba16Float
        mtk.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        mtk.clearColor = MTLClearColor(red: 2, green: 2, blue: 2, alpha: 1)
        mtk.framebufferOnly = true
        mtk.preferredFramesPerSecond = 10
        (mtk.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true

        let r = Renderer(device: device)
        mtk.delegate = r
        win.contentView = mtk
        win.orderFrontRegardless()

        window = win; view = mtk; renderer = r
    }

    func hide() {
        view?.isPaused = true
        window?.orderOut(nil)
        window = nil; view = nil; renderer = nil
    }
}

private final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    init(device: MTLDevice) { queue = device.makeCommandQueue()! }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
