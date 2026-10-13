import AppKit
import MetalKit
import ScreenCaptureKit

/// Captures a display with ScreenCaptureKit (excluding itself) and redraws it in a
/// full-screen, click-through EDR window, multiplied in linear light by `factor`.
/// The window is only ordered front once a real frame is available, and is hidden
/// as soon as the stream stops, so it can never cover the screen with stale/blank content.
final class EDROverlay: NSObject, SCStreamDelegate {
    private(set) var displayID: CGDirectDisplayID?
    private var window: NSWindow?
    private var view: MTKView?
    private var renderer: Renderer?
    private var stream: SCStream?
    private var output: FrameOutput?
    private let captureQueue = DispatchQueue(label: "vivid.capture", qos: .userInteractive)

    var factor: Float = 1 {
        didSet { renderer?.factor = factor; view?.draw() }
    }

    @MainActor
    func start(on screen: NSScreen, displayID id: CGDirectDisplayID) async throws {
        stop()
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try Renderer(device: device)
        renderer.factor = factor

        let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.sharingType = .none
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let mtk = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        mtk.autoresizingMask = [.width, .height]
        mtk.colorPixelFormat = .rgba16Float
        mtk.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        mtk.isPaused = true
        mtk.enableSetNeedsDisplay = false
        mtk.delegate = renderer
        if let layer = mtk.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false
        }
        win.contentView = mtk

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { return }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.width = Int(screen.frame.width * screen.backingScaleFactor)
        cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.displayP3
        cfg.showsCursor = false
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        cfg.queueDepth = 4

        let output = FrameOutput { [weak self] buffer in
            DispatchQueue.main.async {
                guard let self, let view = self.view, let renderer = self.renderer else { return }
                renderer.latest = buffer
                view.draw()
                if self.window?.isVisible == false { self.window?.orderFrontRegardless() }
            }
        }
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)

        self.window = win; self.view = mtk; self.renderer = renderer
        self.stream = stream; self.output = output; self.displayID = id
        try await stream.startCapture()
    }

    func stop() {
        window?.orderOut(nil)
        stream?.stopCapture { _ in }
        window = nil; view = nil; renderer = nil; stream = nil; output = nil; displayID = nil
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

private final class Renderer: NSObject, MTKViewDelegate {
    var factor: Float = 1
    var latest: CVPixelBuffer?
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?

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
        constexpr sampler s(filter::linear);
        return float4(tex.sample(s, in.uv).rgb * k, 1);
    }
    """

    init(device: MTLDevice) throws {
        queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: Self.shader, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vtx")
        desc.fragmentFunction = lib.makeFunction(name: "frag")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let buffer = latest, let cache else { return }
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm_srgb,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTex)
        guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex),
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        var k = factor
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentBytes(&k, length: MemoryLayout<Float>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.addCompletedHandler { _ in _ = cvTex }
        cmd.present(drawable)
        cmd.commit()
    }
}
