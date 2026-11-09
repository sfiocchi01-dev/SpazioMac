import AppKit
let output = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 968, height: 968), xRadius: 215, yRadius: 215)
NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.38, blue: 0.85, alpha: 1),
           ending: NSColor(srgbRed: 0.04, green: 0.11, blue: 0.34, alpha: 1))!.draw(in: background, angle: 60)
for (i, width) in [600.0, 430.0, 250.0].enumerated() {
    NSColor(white: 1, alpha: 1 - Double(i) * 0.13).setFill()
    NSBezierPath(roundedRect: NSRect(x: 212, y: 640 - Double(i) * 170, width: width, height: 105), xRadius: 30, yRadius: 30).fill()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
