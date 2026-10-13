import AppKit
import Metal
import QuartzCore
import ScreenCaptureKit

/// Captures a display with ScreenCaptureKit (excluding itself) and redraws it in a
/// full-screen, click-through EDR window, multiplied in linear light by `factor`.
/// Rendering happens on the capture queue, never on the main thread, and frames are
/// dropped rather than queued when the GPU is busy. The window is only shown once a
/// real frame is on screen, and the Watchdog kills the app if anything stalls.
final class EDROverlay: NSObject, SCStreamDelegate {
    private(set) var displayID: CGDirectDisplayID?
    private var window: NSWindow?
    private var renderer: Renderer?
    private var stream: SCStream?
    private var output: FrameOutput?
    private var generation = 0
    private let watchdog = Watchdog()
    private let renderQueue = DispatchQueue(label: "vivid.render", qos: .userInteractive)

    var factor: Float = 1 {
        didSet { renderer?.setFactor(factor) }
    }

    @MainActor
    func start(on screen: NSScreen, displayID id: CGDirectDisplayID) async throws {
        stop()
        generation += 1
        let gen = generation
        displayID = id
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let pixelSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                               height: screen.frame.height * screen.backingScaleFactor)
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = true
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        layer.contentsScale = screen.backingScaleFactor
        layer.drawableSize = pixelSize

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.layer = layer
        host.wantsLayer = true

        let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.sharingType = .none
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        win.contentView = host

        let renderer = try Renderer(device: device, layer: layer, queue: renderQueue, watchdog: watchdog)
        renderer.setFactor(factor)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard gen == generation else { return } // superseded by a newer start/stop
        guard let display = content.displays.first(where: { $0.displayID == id }) else { return }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.width = Int(pixelSize.width)
        cfg.height = Int(pixelSize.height)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.displayP3
        cfg.showsCursor = false
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 3

        let output = FrameOutput { [weak renderer, weak win] buffer in
            guard let renderer, renderer.render(buffer) else { return }
            if renderer.firstFrame {
                renderer.firstFrame = false
                DispatchQueue.main.async { win?.orderFrontRegardless() }
            }
        }
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: renderQueue)

        self.window = win; self.renderer = renderer
        self.stream = stream; self.output = output
        watchdog.start()
        try await stream.startCapture()
        if gen != generation { stream.stopCapture { _ in } }
    }

    func stop() {
        generation += 1
        watchdog.stop()
        window?.orderOut(nil)
        stream?.stopCapture { _ in }
        window = nil; renderer = nil; stream = nil; output = nil; displayID = nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Vivid: capture stopped: \(error)")
        DispatchQueue.main.async { if stream === self.stream { self.stop() } }
    }
}

private final class FrameOutput: NSObject, SCStreamOutput {
    let onFrame: (CVPixelBuffer) -> Void
    init(onFrame: @escaping (CVPixelBuffer) -> Void) { self.onFrame = onFrame }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sample.imageBuffer else { return }
        onFrame(buffer)
    }
}

/// All methods except setFactor run on the render queue.
private final class Renderer {
    var firstFrame = true
    private let layer: CAMetalLayer
    private let queue: DispatchQueue
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let watchdog: Watchdog
    private let inFlight = DispatchSemaphore(value: 2)
    private var cache: CVMetalTextureCache?
    private var factor: Float = 1
    private var last: CVPixelBuffer?

    // Full-screen triangle; uv origin top-left like the captured buffer.
    // The _srgb texture view decodes to linear, so the multiply happens in linear light.
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 pos [[position]]; float2 uv; };
    vertex V vtx(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        V o; o.pos = float4(p * 2 - 1, 0, 1); o.uv = float2(p.x, 1 - p.y); return o;
    }
    fragment float4 frag(V in [[stage_in]], texture2d<float> tex [[texture(0)]], constant float &k [[buffer(0)]]) {
        constexpr sampler s(filter::nearest);
        return float4(tex.sample(s, in.uv).rgb * k, 1);
    }
    """

    init(device: MTLDevice, layer: CAMetalLayer, queue: DispatchQueue, watchdog: Watchdog) throws {
        self.layer = layer
        self.queue = queue
        self.watchdog = watchdog
        commandQueue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: Self.shader, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vtx")
        desc.fragmentFunction = lib.makeFunction(name: "frag")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    func setFactor(_ k: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            self.factor = k
            if let last = self.last { _ = self.render(last) }
        }
    }

    /// Returns false when the frame was dropped.
    @discardableResult
    func render(_ buffer: CVPixelBuffer) -> Bool {
        last = buffer
        watchdog.framePending()
        // GPU still busy with previous frames: drop this one instead of piling up.
        guard inFlight.wait(timeout: .now()) == .success else { return false }

        var cvTex: CVMetalTexture?
        guard let cache,
              CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm_srgb,
                  CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let tex = CVMetalTextureGetTexture(cvTex),
              let drawable = layer.nextDrawable(),
              let cmd = commandQueue.makeCommandBuffer() else { inFlight.signal(); return false }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return false }
        var k = factor
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentBytes(&k, length: MemoryLayout<Float>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        let watchdog = self.watchdog, sem = inFlight
        drawable.addPresentedHandler { _ in watchdog.framePresented() }
        cmd.addCompletedHandler { _ in _ = cvTex; sem.signal() }
        cmd.present(drawable)
        cmd.commit()
        return true
    }
}
