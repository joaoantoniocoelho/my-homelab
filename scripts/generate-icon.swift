import AppKit

let output = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 55, y: 55, width: 914, height: 914), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(red: 0.12, green: 0.19, blue: 0.22, alpha: 1), ending: NSColor(red: 0.035, green: 0.06, blue: 0.08, alpha: 1))!.draw(in: background, angle: -75)
        let mint = NSColor(red: 0.40, green: 0.89, blue: 0.71, alpha: 1)
        for y in [CGFloat(320), 530] {
            let rack = NSBezierPath(roundedRect: NSRect(x: 240, y: y, width: 544, height: 170), xRadius: 35, yRadius: 35)
            mint.withAlphaComponent(0.08).setFill(); rack.fill()
            mint.setStroke(); rack.lineWidth = 16; rack.stroke()
            mint.setFill(); NSBezierPath(ovalIn: NSRect(x: 293, y: y + 66, width: 38, height: 38)).fill()
            for x in [CGFloat(590), 646, 702] {
                let vent = NSBezierPath(roundedRect: NSRect(x: x, y: y + 60, width: 13, height: 50), xRadius: 6, yRadius: 6)
                mint.withAlphaComponent(0.65).setFill(); vent.fill()
            }
        }
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
try FileManager.default.removeItem(at: iconset)
