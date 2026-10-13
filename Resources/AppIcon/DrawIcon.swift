import AppKit

// Render the procedural icon at explicit pixel sizes so generation is
// independent of the display's Retina scale. No fonts or external assets.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(srgbRed: 23/255, green: 28/255, blue: 48/255, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 192, yRadius: 192).fill()
NSColor(srgbRed: 122/255, green: 225/255, blue: 194/255, alpha: 1).setFill()
for rect in [NSRect(x: 288, y: 270, width: 104, height: 484),
             NSRect(x: 632, y: 270, width: 104, height: 484),
             NSRect(x: 340, y: 460, width: 344, height: 104)] {
    NSBezierPath(roundedRect: rect, xRadius: 52, yRadius: 52).fill()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
