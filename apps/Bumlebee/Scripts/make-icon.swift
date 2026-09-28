// Draws Bumlebee's app icon and writes a macOS .iconset folder.
// Usage: swift Scripts/make-icon.swift build/AppIcon.iconset
import AppKit
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let honeyLight = CGColor(red: 1.0, green: 0.86, blue: 0.42, alpha: 1)
let honey = CGColor(red: 0.98, green: 0.74, blue: 0.13, alpha: 1)
let honeyDeep = CGColor(red: 0.89, green: 0.55, blue: 0.05, alpha: 1)
let ink = CGColor(red: 0.12, green: 0.10, blue: 0.06, alpha: 1)
let inkSoft = CGColor(red: 0.24, green: 0.20, blue: 0.12, alpha: 1)
let wax = CGColor(red: 1.0, green: 0.96, blue: 0.85, alpha: 1)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Pointy-top hexagon with rounded corners.
func hexagon(center: CGPoint, radius: CGFloat, corner: CGFloat) -> CGPath {
    let corners = (0..<6).map { index -> CGPoint in
        let angle = CGFloat(index) * .pi / 3 + .pi / 2
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }
    let path = CGMutablePath()
    for index in 0..<6 {
        let previous = corners[(index + 5) % 6], current = corners[index], next = corners[(index + 1) % 6]
        if index == 0 { path.move(to: CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)) }
        path.addArc(tangent1End: current, tangent2End: next, radius: corner)
    }
    path.closeSubpath()
    return path
}

func fillGradient(_ context: CGContext, path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func drawIcon(pixels: Int) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    let center = CGPoint(x: 512, y: 512)

    // Rounded-square tile with a soft drop shadow.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(tile)
    context.setFillColor(ink)
    context.fillPath()
    context.restoreGState()
    fillGradient(context, path: tile, colors: [inkSoft, ink], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))

    // The ring of honeycomb cells, like the wheel.
    for index in 0..<6 {
        let angle = CGFloat(index) * .pi / 3 + .pi / 2
        let cellCenter = CGPoint(x: center.x + 312 * cos(angle), y: center.y + 312 * sin(angle))
        let cell = hexagon(center: cellCenter, radius: 74, corner: 14)
        context.addPath(cell)
        context.setFillColor(index % 2 == 0 ? wax : honeyLight)
        context.fillPath()
    }

    // The big centre cell.
    let body = hexagon(center: center, radius: 232, corner: 38)
    fillGradient(context, path: body, colors: [honeyLight, honey, honeyDeep], from: CGPoint(x: 512, y: 744), to: CGPoint(x: 512, y: 280))
    context.addPath(body)
    context.setStrokeColor(ink)
    context.setLineWidth(12)
    context.strokePath()

    // Bee stripes.
    context.setFillColor(ink)
    for (y, width) in [(548.0, 250.0), (468.0, 290.0), (388.0, 214.0)] {
        let stripe = CGPath(roundedRect: CGRect(x: 512 - width / 2, y: y - 24, width: width, height: 48), cornerWidth: 24, cornerHeight: 24, transform: nil)
        context.addPath(stripe)
        context.fillPath()
    }

    // Wings.
    context.setFillColor(CGColor(gray: 1, alpha: 0.92))
    for side in [-1.0, 1.0] {
        context.saveGState()
        context.translateBy(x: 512 + side * 88, y: 652)
        context.rotate(by: side * 0.45)
        context.addEllipse(in: CGRect(x: -64, y: -40, width: 128, height: 80))
        context.fillPath()
        context.restoreGState()
    }
    return context.makeImage()!
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (pixels, name) in sizes {
    let url = output.appendingPathComponent("\(name).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, drawIcon(pixels: pixels), nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
}
print("Wrote \(sizes.count) icons to \(output.path)")
