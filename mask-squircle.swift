// Clip an image to a rounded-rectangle (squircle approximation) and write transparent PNG.
// Usage: mask-squircle <input> <output> [radius-pct=22.5]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: mask-squircle <input> <output> [radius-pct=22.5]\n", stderr)
    exit(1)
}
let input = args[1], output = args[2]
let radiusPct = args.count > 3 ? (Double(args[3]) ?? 22.5) : 22.5

guard let src = NSImage(contentsOfFile: input) else {
    fputs("cannot read \(input)\n", stderr); exit(1)
}

let size = NSSize(width: 1024, height: 1024)
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                  pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                  bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB,
                                  bytesPerRow: Int(size.width) * 4, bitsPerPixel: 32) else {
    fputs("bitmap rep failed\n", stderr); exit(1)
}
rep.size = size

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

let radius = size.width * radiusPct / 100.0
let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                        xRadius: radius, yRadius: radius)
path.addClip()
src.draw(in: NSRect(origin: .zero, size: size),
         from: .zero, operation: .copy, fraction: 1.0)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    fputs("png encode failed\n", stderr); exit(1)
}
try data.write(to: URL(fileURLWithPath: output))
fputs("wrote \(output) (\(data.count) bytes, radius=\(radiusPct)%)\n", stderr)
