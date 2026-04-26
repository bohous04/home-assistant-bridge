// Generate DMG background: 720x460 image with vertical gradient + arrow + text.
// Usage: make-dmg-bg <output.png>
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("usage: make-dmg-bg <out.png>\n", stderr); exit(1) }
let output = args[1]

let W: CGFloat = 720, H: CGFloat = 460

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                  pixelsWide: Int(W), pixelsHigh: Int(H),
                                  bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB,
                                  bytesPerRow: Int(W) * 4, bitsPerPixel: 32) else {
    fputs("bitmap rep failed\n", stderr); exit(1)
}
rep.size = NSSize(width: W, height: H)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 0, y: 0, width: W, height: H)

// Vertical gradient — dark teal to slightly brighter teal, matching the logo's palette.
let top = NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.18, alpha: 1.0)
let bot = NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.14, alpha: 1.0)
let gradient = NSGradient(starting: top, ending: bot)!
gradient.draw(in: rect, angle: -90)

// Subtle accent: a hint of teal in the middle (matches logo).
let accent = NSColor(calibratedRed: 0.27, green: 0.78, blue: 0.78, alpha: 0.04)
accent.setFill()
NSBezierPath(ovalIn: NSRect(x: W/2 - 240, y: H/2 - 120, width: 480, height: 240)).fill()

// Arrow from .app to Applications (centered between icons at y=230 in DMG window).
// Icons are at x=180 and x=540 in container coords (which maps roughly to same in image).
// The bg image is the entire window's content area.
// Draw arrow from x≈260 to x≈460, y center.
let arrowY: CGFloat = H - 230  // image y-axis is flipped vs DMG window y
let arrowStart = NSPoint(x: 260, y: arrowY)
let arrowEnd = NSPoint(x: 460, y: arrowY)

NSColor(white: 1.0, alpha: 0.55).setStroke()
let arrow = NSBezierPath()
arrow.move(to: arrowStart)
arrow.line(to: NSPoint(x: arrowEnd.x - 18, y: arrowEnd.y))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.stroke()

// Arrow head (triangle)
let head = NSBezierPath()
head.move(to: arrowEnd)
head.line(to: NSPoint(x: arrowEnd.x - 18, y: arrowEnd.y - 9))
head.line(to: NSPoint(x: arrowEnd.x - 18, y: arrowEnd.y + 9))
head.close()
NSColor(white: 1.0, alpha: 0.7).setFill()
head.fill()

// Top title
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
    .foregroundColor: NSColor(white: 1.0, alpha: 0.95),
    .kern: 0.4
]
let title = "macbook-ha-bridge"
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(at: NSPoint(x: (W - titleSize.width) / 2, y: H - 80),
           withAttributes: titleAttrs)

// Subtitle
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
    .foregroundColor: NSColor(white: 1.0, alpha: 0.65)
]
let sub = "Drag the app to Applications to install"
let subSize = sub.size(withAttributes: subAttrs)
sub.draw(at: NSPoint(x: (W - subSize.width) / 2, y: H - 110),
         withAttributes: subAttrs)

// Bottom hint
let hintAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
    .foregroundColor: NSColor(white: 1.0, alpha: 0.40)
]
let hint = "First launch: right-click → Open (unsigned developer)"
let hintSize = hint.size(withAttributes: hintAttrs)
hint.draw(at: NSPoint(x: (W - hintSize.width) / 2, y: 30),
          withAttributes: hintAttrs)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr); exit(1)
}
try data.write(to: URL(fileURLWithPath: output))
fputs("wrote \(output) (\(data.count) bytes)\n", stderr)
