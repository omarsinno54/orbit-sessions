// Draws the Orbit app icon (1024x1024 PNG): a center "you" with sessions on an orbit ring.
// Usage: swift make_icon.swift out.png
import AppKit

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Rounded-square tile on the standard macOS icon grid (824pt tile, 100pt margin).
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(srgbRed: 0.42, green: 0.40, blue: 0.95, alpha: 1),
                    NSColor(srgbRed: 0.16, green: 0.11, blue: 0.48, alpha: 1)])!
    .draw(in: tile, angle: -90)

// Tilted orbit ring.
let c = NSPoint(x: size / 2, y: size / 2)
ctx.saveGState()
ctx.translateBy(x: c.x, y: c.y)
ctx.rotate(by: -0.42)
let ringW = 640.0, ringH = 300.0
let ring = NSBezierPath(ovalIn: NSRect(x: -ringW / 2, y: -ringH / 2, width: ringW, height: ringH))
ring.lineWidth = 22
NSColor.white.withAlphaComponent(0.55).setStroke()
ring.stroke()

// Sessions (planets) sitting on the ring.
for (angle, r, alpha) in [(0.35, 46.0, 1.0), (2.45, 38.0, 0.9), (4.2, 32.0, 0.8)] {
    let p = NSPoint(x: cos(angle) * ringW / 2, y: sin(angle) * ringH / 2)
    NSColor.white.withAlphaComponent(alpha).setFill()
    NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
}
ctx.restoreGState()

// You, in the middle.
NSColor.white.setFill()
let hub = 210.0
NSBezierPath(ovalIn: NSRect(x: c.x - hub / 2, y: c.y - hub / 2, width: hub, height: hub)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
