// Draws the Calendar Cleanup icon: a duplicate calendar page fading behind a checked one.
// Usage: make-icon <output.png>  (writes a 1024 x 1024 image)

import AppKit

let color = { (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) in
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func page(_ rect: NSRect, header: NSColor, body: NSColor) {
    let shape = NSBezierPath(roundedRect: rect, xRadius: 56, yRadius: 56)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    body.setFill()
    rect.fill()
    header.setFill()
    NSRect(x: rect.minX, y: rect.maxY - 120, width: rect.width, height: 120).fill()
    NSGraphicsContext.restoreGraphicsState()
}

let image = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)

// Background: the standard macOS icon shape, inset from the 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tileShape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
tileShape.addClip()
NSGradient(starting: color(38, 130, 240, 1), ending: color(22, 72, 170, 1))!.draw(in: tile, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// The duplicate behind.
page(
    NSRect(x: 318, y: 320, width: 470, height: 470),
    header: NSColor.white.withAlphaComponent(0.42),
    body: NSColor.white.withAlphaComponent(0.26)
)

// The page that stays, with a soft shadow.
let front = NSRect(x: 236, y: 234, width: 470, height: 470)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 34
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
NSColor.white.setFill()
NSBezierPath(roundedRect: front, xRadius: 56, yRadius: 56).fill()
NSGraphicsContext.restoreGraphicsState()
page(front, header: color(235, 72, 62, 1), body: .white)

// Binder rings on the header.
NSColor.white.setFill()
for x in [front.minX + 130, front.maxX - 130] {
    NSBezierPath(ovalIn: NSRect(x: x - 19, y: front.maxY - 79, width: 38, height: 38)).fill()
}

// The check mark.
let check = NSBezierPath()
check.move(to: NSPoint(x: front.minX + 118, y: front.minY + 182))
check.line(to: NSPoint(x: front.minX + 205, y: front.minY + 92))
check.line(to: NSPoint(x: front.minX + 358, y: front.minY + 268))
check.lineWidth = 58
check.lineCapStyle = .round
check.lineJoinStyle = .round
color(35, 170, 95, 1).setStroke()
check.stroke()

NSGraphicsContext.current = nil
try! image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
