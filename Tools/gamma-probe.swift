// Probe: does macOS keep gamma table values > 1.0 while an EDR surface is on screen?
import AppKit
import MetalKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
let factor = Float(CommandLine.arguments.dropFirst().first ?? "1.05")!
let hold = Double(CommandLine.arguments.dropFirst(2).first ?? "0.5")!

func table() -> [CGGammaValue] {
    var r = [CGGammaValue](repeating: 0, count: 256), g = r, b = r, n: UInt32 = 0
    CGGetDisplayTransferByTable(id, 256, &r, &g, &b, &n)
    return Array(r.prefix(Int(n)))
}

let device = MTLCreateSystemDefaultDevice()!
let win = NSWindow(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
win.level = .screenSaver; win.isOpaque = false; win.backgroundColor = .clear; win.ignoresMouseEvents = true
let v = MTKView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), device: device)
v.colorPixelFormat = .rgba16Float
v.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
(v.layer as! CAMetalLayer).wantsExtendedDynamicRangeContent = true
v.clearColor = MTLClearColor(red: Double(factor), green: Double(factor), blue: Double(factor), alpha: 1)
class R: NSObject, MTKViewDelegate {
    let q: MTLCommandQueue; init(_ d: MTLDevice) { q = d.makeCommandQueue()! }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let p = view.currentRenderPassDescriptor, let d = view.currentDrawable, let c = q.makeCommandBuffer(),
              let e = c.makeRenderCommandEncoder(descriptor: p) else { return }
        e.endEncoding(); c.present(d); c.commit()
    }
}
let r = R(device); v.delegate = r; win.contentView = v

let base = table()
print("base mid:", base[base.count / 2], "count:", base.count)
print("headroom before:", screen.maximumExtendedDynamicRangeColorComponentValue, "table max:", base.last!)
win.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
    print("headroom with EDR pixel:", screen.maximumExtendedDynamicRangeColorComponentValue)
    let t = base.map { $0 * factor }
    let err = CGSetDisplayTransferByTable(id, UInt32(t.count), t, t, t)
    print("set ×\(factor):", err == .success ? "ok" : "err \(err.rawValue)", "readback max:", table().last!)
    for i in 1...Int(hold * 4) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) {
            let t = table()
            print(String(format: "t+%.2fs  mid %.4f  last %.4f  headroom %.2f", Double(i) * 0.25, t[t.count / 2], t.last!, screen.maximumExtendedDynamicRangeColorComponentValue))
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + hold + 0.1) {
        print("readback after \(hold)s:", table().last!, "headroom:", screen.maximumExtendedDynamicRangeColorComponentValue)
        CGDisplayRestoreColorSyncSettings()
        exit(0)
    }
}
app.run()
