// Generates the macOS app icon from the bundled Lucide waveform. No network or third-party runtime required.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
let source = try String(contentsOf: resources.appendingPathComponent("IconSource/audio-lines.svg"), encoding: .utf8)
let pathPattern = try NSRegularExpression(pattern: #"d="M(\d+) (\d+)v(\d+)""#)
let bars = pathPattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { match in
    (1...3).map { CGFloat(Double(source[Range(match.range(at: $0), in: source)!])!) }
}
precondition(bars.count == 6, "Expected six vertical waveform paths in the bundled Lucide source")

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func render(size: Int, to destination: URL) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: scale, y: -scale)
    let tile = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
                      cornerWidth: 200, cornerHeight: 200, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 12), blur: 22, color: color(0x032E3A, alpha: 0.28))
    context.setFillColor(color(0x087E83))
    context.addPath(tile); context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile); context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x27C7B5), color(0x0A8990), color(0x07546B)] as CFArray, locations: [0, 0.48, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 150, y: 80), end: CGPoint(x: 900, y: 1000), options: [])
    context.restoreGState()
    context.addPath(tile); context.setLineWidth(2)
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.22)); context.strokePath()

    let page = CGPath(roundedRect: CGRect(x: 264, y: 202, width: 496, height: 620),
                      cornerWidth: 56, cornerHeight: 56, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 18), blur: 32, color: color(0x003946, alpha: 0.28))
    context.setFillColor(color(0xF4FFFD)); context.addPath(page); context.fillPath()
    context.restoreGState()
    context.setLineCap(.round)

    // Lucide audio-lines.svg, positioned in the upper part of the sheet.
    context.saveGState()
    context.translateBy(x: 320, y: 296)
    context.scaleBy(x: 16, y: 16)
    context.setStrokeColor(color(0x0B8D91)); context.setLineWidth(2)
    for bar in bars {
        context.move(to: CGPoint(x: bar[0], y: bar[1]))
        context.addLine(to: CGPoint(x: bar[0], y: bar[1] + bar[2]))
    }
    context.strokePath()
    context.restoreGState()

    context.setStrokeColor(color(0x89C9C6)); context.setLineWidth(22)
    context.move(to: CGPoint(x: 354, y: 702)); context.addLine(to: CGPoint(x: 670, y: 702))
    context.move(to: CGPoint(x: 354, y: 754)); context.addLine(to: CGPoint(x: 574, y: 754))
    context.strokePath()

    let image = context.makeImage()!
    let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingRecord-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for size in [16, 32, 128, 256, 512] {
    try render(size: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(size: 1024, to: resources.appendingPathComponent("AppIcon.png"))
try render(size: 256, to: resources.appendingPathComponent("AppIcon-preview.png"))
let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try converter.run()
converter.waitUntilExit()
guard converter.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
print("Generated AppIcon.png, AppIcon-preview.png and AppIcon.icns")
