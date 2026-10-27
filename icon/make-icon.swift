// Draws the SMC Sampler app icon at 1024×1024.
// Usage: swiftc icon/make-icon.swift -o /tmp/make-icon -framework AppKit && /tmp/make-icon out.png
import AppKit

let size: CGFloat = 1024

func squircle(center: NSPoint, half: CGFloat, n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 1440
    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle), sine = sin(angle)
        let x = center.x + half * copysign(pow(abs(cosine), 2 / n), cosine)
        let y = center.y + half * copysign(pow(abs(sine), 2 / n), sine)
        if step == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

guard CommandLine.arguments.count > 1 else {
    print("usage: make-icon <output.png>")
    exit(1)
}

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else {
    print("could not create bitmap")
    exit(2)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

// macOS 26+ masks app icons itself, so the artwork is a full-bleed square.
NSGradient(colors: [
    NSColor(calibratedRed: 0.23, green: 0.24, blue: 0.27, alpha: 1),
    NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
])?.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])?
    .draw(in: NSRect(x: 0, y: 540, width: size, height: 484), angle: -90)

// Eight bars: one per slot, heights locked so the mark reads at 16 px.
let heights: [CGFloat] = [175, 285, 220, 390, 310, 240, 340, 195]
let width: CGFloat = 38, gap: CGFloat = 30
let total = 8 * width + 7 * gap
var x = (size - total) / 2
let baseline = size / 2 - 190
for height in heights {
    let bar = NSBezierPath(roundedRect: NSRect(x: x, y: baseline, width: width, height: height),
                           xRadius: width / 2, yRadius: width / 2)
    NSColor.white.withAlphaComponent(0.95).setFill()
    bar.fill()
    x += width + gap
}

NSGraphicsContext.restoreGraphicsState()
if let png = rep.representation(using: .png, properties: [:]) {
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("wrote \(CommandLine.arguments[1])")
}
