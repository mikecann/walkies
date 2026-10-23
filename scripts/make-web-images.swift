// Makes the website's images (web/public/img) from the app's own art: the boot icon
// at the sizes browsers want, a few stickers and badges, and the link-preview card
// (og.png, 1200 × 630). Run from the repo root after changing any of the art:
//
//   xcrun swiftc -O scripts/make-web-images.swift -o /tmp/make-web-images && /tmp/make-web-images
//
// Only ImageIO, Core Graphics and Core Text, so it needs nothing installed.
import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: "web/public/img", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Can't read \(path)") }
    return image
}

func save(_ image: CGImage, _ name: String, jpeg: Bool = false) {
    let url = out.appending(path: name)
    let type = (jpeg ? UTType.jpeg : UTType.png).identifier as CFString
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { fatalError("Can't write \(name)") }
    CGImageDestinationAddImage(dest, image, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary : nil)
    CGImageDestinationFinalize(dest)
    print("  \(url.path)")
}

func context(_ width: Int, _ height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    return ctx
}

/// Scaled to fit `size` on its longest side, keeping its transparency.
func resized(_ image: CGImage, _ size: Int) -> CGImage {
    let scale = Double(size) / Double(max(image.width, image.height))
    let w = Int((Double(image.width) * scale).rounded()), h = Int((Double(image.height) * scale).rounded())
    let ctx = context(w, h)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

// The boot icon, for tabs, home screens and the header.
let icon = load("Walkies/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
for (name, size) in [("icon-512.png", 512), ("icon-192.png", 192), ("apple-touch-icon.png", 180), ("favicon-32.png", 32)] {
    save(resized(icon, size), name)
}

// Art for the page.
let art: [(String, String, Int)] = [
    ("design/app-icon/icon-badge.jpg", "hero-badge.jpg", 900),
    ("Walkies/Assets.xcassets/Icons/icon-map.imageset/icon.png", "badge-map.png", 200),
    ("Walkies/Assets.xcassets/Icons/icon-walk.imageset/icon.png", "badge-walk.png", 200),
    ("Walkies/Assets.xcassets/Icons/icon-book.imageset/icon.png", "badge-book.png", 200),
    ("design/progression-art/shell.png", "shell.png", 200),
    ("design/progression-art/spyglass.png", "spyglass.png", 200),
    ("design/progression-art/level-star.png", "level-star.png", 200),
]
for (path, name, size) in art { save(resized(load(path), size), name, jpeg: name.hasSuffix(".jpg")) }
for sticker in ["a-piano-on-a-truck", "a-rest-stop-for-whales", "wrecked-against-the-jetty", "the-windmill-that-waited",
                "possums-in-the-peppermints", "a-house-built-from-a-whaler"] {
    let path = "Walkies/Assets.xcassets/Stickers/sticker-\(sticker).imageset/sticker.png"
    guard FileManager.default.fileExists(atPath: path) else { print("  (no sticker art for \(sticker))"); continue }
    save(resized(load(path), 280), "sticker-\(sticker).png")
}

// The link-preview card: cream paper, the icon on a white die-cut edge, and the name.
let cream = CGColor(srgbRed: 0.984, green: 0.957, blue: 0.902, alpha: 1)
let sand = CGColor(srgbRed: 0.918, green: 0.859, blue: 0.753, alpha: 1)
let ink = CGColor(srgbRed: 0.231, green: 0.192, blue: 0.169, alpha: 1)
let burnt = CGColor(srgbRed: 0.79, green: 0.34, blue: 0.23, alpha: 1)
let og = context(1200, 630)
og.setFillColor(cream)
og.fill(CGRect(x: 0, y: 0, width: 1200, height: 630))
// Faint hex tiles, like the map's.
og.setStrokeColor(sand)
og.setLineWidth(2)
let r = 46.0
for row in 0..<12 {
    for col in 0..<16 {
        let cx = Double(col) * r * 3.0.squareRoot() + (row % 2 == 0 ? 0 : r * 3.0.squareRoot() / 2)
        let cy = Double(row) * r * 1.5
        og.beginPath()
        for i in 0..<6 {
            let a = (60 * Double(i) - 90) * .pi / 180
            let p = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            i == 0 ? og.move(to: p) : og.addLine(to: p)
        }
        og.closePath()
        og.strokePath()
    }
}
let iconRect = CGRect(x: 90, y: 135, width: 360, height: 360)
og.saveGState()
og.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: CGColor(gray: 0, alpha: 0.22))
og.setFillColor(.white)
og.addPath(CGPath(roundedRect: iconRect.insetBy(dx: -10, dy: -10), cornerWidth: 90, cornerHeight: 90, transform: nil))
og.fillPath()
og.restoreGState()
og.saveGState()
og.addPath(CGPath(roundedRect: iconRect, cornerWidth: 80, cornerHeight: 80, transform: nil))
og.clip()
og.draw(icon, in: iconRect)
og.restoreGState()

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
}

func draw(_ text: String, font: CTFont, colour: CGColor, x: CGFloat, y: CGFloat, width: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
    let frame = CTFramesetterCreateFrame(
        CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)),
        CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: x, y: y, width: width, height: 400), transform: nil), nil)
    CTFrameDraw(frame, og)
}
draw("Walkies", font: rounded(112, .heavy), colour: ink, x: 520, y: 75, width: 640)
draw("Go for a walk and the clouds lift off your suburb.", font: rounded(44, .semibold), colour: burnt,
     x: 524, y: -75, width: 600)
save(og.makeImage()!, "og.png")
