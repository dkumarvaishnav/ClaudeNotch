// Draws Resources/AppIcon.icns: a black notch hanging over a dark tile with the Claude spark.
// Run: swift tools/make-icon.swift  (from the project folder)
import AppKit

func spark(in rect: CGRect, rays: Int = 10) -> CGPath {
    let path = CGMutablePath()
    let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) / 2, w = r * 0.30
    for i in 0..<rays {
        let len = i % 2 == 0 ? r : r * 0.74
        let ray = CGPath(roundedRect: CGRect(x: -w / 2, y: -len, width: w, height: len + w * 0.2), cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)
        path.addPath(ray, transform: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: CGFloat(i) / CGFloat(rays) * 2 * .pi))
    }
    return path
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0.20, alpha: 1), CGColor(gray: 0.08, alpha: 1)] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // The notch, hanging from the top edge.
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 262, y: 590, width: 500, height: 400), cornerWidth: 110, cornerHeight: 110, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(CGColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1))
    ctx.addPath(spark(in: CGRect(x: 432, y: 680, width: 160, height: 160)))
    ctx.fillPath()
    // Session dots below.
    let dots: [CGColor] = [CGColor(red: 1, green: 0.76, blue: 0.27, alpha: 1), CGColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1), CGColor(red: 0.32, green: 0.82, blue: 0.53, alpha: 1)]
    for (i, color) in dots.enumerated() {
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: 342 + CGFloat(i) * 130, y: 330, width: 80, height: 80))
    }
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
