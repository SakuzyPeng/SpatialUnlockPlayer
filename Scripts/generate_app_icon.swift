import AppKit

// Vector artwork for the app icon. Render each macOS size directly so small
// icons don't depend on resampling a large bitmap or on an installed font.
func renderIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.coderInvalidValue)
    }
    let context = graphics.cgContext
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)

    let tile = CGPath(roundedRect: CGRect(x: 84, y: 84, width: 856, height: 856),
                      cornerWidth: 192, cornerHeight: 192, transform: nil)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.addPath(tile)
    context.fillPath()

    let ink = CGColor(red: 0.12, green: 0.42, blue: 0.90, alpha: 1)
    context.setStrokeColor(ink)
    context.setLineWidth(64)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 390, y: 520))
    context.addLine(to: CGPoint(x: 390, y: 680))
    context.addCurve(to: CGPoint(x: 512, y: 804),
                     control1: CGPoint(x: 390, y: 750), control2: CGPoint(x: 442, y: 804))
    context.addCurve(to: CGPoint(x: 634, y: 680),
                     control1: CGPoint(x: 582, y: 804), control2: CGPoint(x: 634, y: 750))
    context.addLine(to: CGPoint(x: 634, y: 654))
    context.strokePath()

    let body = CGMutablePath()
    body.addRoundedRect(in: CGRect(x: 286, y: 236, width: 452, height: 312),
                        cornerWidth: 56, cornerHeight: 56)
    // One closed keyhole contour keeps its opening continuous at every size.
    body.move(to: CGPoint(x: 512, y: 450))
    body.addCurve(to: CGPoint(x: 546, y: 416),
                  control1: CGPoint(x: 531, y: 450), control2: CGPoint(x: 546, y: 435))
    body.addCurve(to: CGPoint(x: 528, y: 386),
                  control1: CGPoint(x: 546, y: 403), control2: CGPoint(x: 539, y: 392))
    body.addLine(to: CGPoint(x: 536, y: 338))
    body.addLine(to: CGPoint(x: 488, y: 338))
    body.addLine(to: CGPoint(x: 496, y: 386))
    body.addCurve(to: CGPoint(x: 478, y: 416),
                  control1: CGPoint(x: 485, y: 392), control2: CGPoint(x: 478, y: 403))
    body.addCurve(to: CGPoint(x: 512, y: 450),
                  control1: CGPoint(x: 478, y: 435), control2: CGPoint(x: 493, y: 450))
    body.closeSubpath()
    context.addPath(body)
    context.setFillColor(ink)
    context.fillPath(using: .evenOdd)

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appendingPathComponent("Resources/Assets.xcassets")
let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
let info: [String: Any] = ["author": "xcode", "version": 1]
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try renderIcon(size: points * scale).write(to: iconSet.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(points)x\(points)",
                       "scale": "\(scale)x", "filename": filename])
    }
}
for (url, contents) in [
    (catalog.appendingPathComponent("Contents.json"), ["info": info]),
    (iconSet.appendingPathComponent("Contents.json"), ["images": images, "info": info]),
] {
    let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}
print("Generated \(images.count) app icon assets at \(iconSet.path)")
