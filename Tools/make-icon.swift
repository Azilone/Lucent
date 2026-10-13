// Builds AppIcon.icns from the source artwork: finds the glass squircle, masks it,
// and lays it out on the macOS icon grid (824 pt body on a 1024 canvas).
import AppKit

let src = NSImage(contentsOfFile: CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
var rect = CGRect(origin: .zero, size: src.size)
let cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil)!

// The squircle body inside the 1254 px artwork (measured; excludes the outer glow).
let crop = CGRect(x: 184, y: 190, width: 884, height: 884)
let body = cg.cropping(to: crop)!

func render(_ px: Int) -> NSBitmapImageRep {
    let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
    let s = CGFloat(px) / 1024
    let frame = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: frame, xRadius: 215 * s, yRadius: 215 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 20 * s
    NSGraphicsContext.saveGraphicsState(); shadow.set(); NSColor.black.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
    path.addClip()
    // Slight overscan hides the anti-aliased white edge of the source squircle.
    NSGraphicsContext.current!.cgContext.draw(body, in: frame.insetBy(dx: -2 * s, dy: -2 * s))
    NSGraphicsContext.restoreGraphicsState()
    return r
}

let iconset = out + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(base * scale).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
    }
}
try! render(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/icon.png"))
