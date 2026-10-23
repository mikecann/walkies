// Makes the website's images (web/public/img) from the app's own art: the boot icon
// at the sizes browsers want, the walking sneaker and a few secret stickers, and the
// link-preview card (og.jpg, 1200 × 630) with two of the phone screenshots. Run it from
// the repo root after changing any of the art or the screenshots
// (web/public/screens, from scripts/make-web-screens.mjs):
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

func save(_ image: CGImage, _ name: String) {
    let url = out.appending(path: name)
    let jpeg = name.hasSuffix(".jpg")
    let type = (jpeg ? UTType.jpeg : UTType.png).identifier as CFString
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { fatalError("Can't write \(name)") }
    CGImageDestinationAddImage(dest, image, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary : nil)
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

// Art for the page: the Start walk sneaker, and the stickers stuck round the secrets phone.
save(resized(load("Walkies/Assets.xcassets/Icons/icon-walk.imageset/icon.png"), 200), "badge-walk.png")
for sticker in ["a-rest-stop-for-whales", "the-windmill-that-waited", "a-piano-on-a-truck"] {
    save(resized(load("Walkies/Assets.xcassets/Stickers/sticker-\(sticker).imageset/sticker.png"), 280), "sticker-\(sticker).png")
}

// The link-preview card, like Poddle's: the icon and name, the home page's headline and a
// plain line on the site's cream, with two of the phones on the right. A JPEG, since the
// satellite map makes a PNG nearly 900 KB and some apps won't show a preview that big.
let cream = CGColor(srgbRed: 0.984, green: 0.957, blue: 0.902, alpha: 1)
let sand = CGColor(srgbRed: 0.918, green: 0.859, blue: 0.753, alpha: 1)
let ink = CGColor(srgbRed: 0.231, green: 0.192, blue: 0.169, alpha: 1)
let inkSoft = CGColor(srgbRed: 0.42, green: 0.365, blue: 0.32, alpha: 1)
let burnt = CGColor(srgbRed: 0.79, green: 0.34, blue: 0.23, alpha: 1)
let W = 1200.0, H = 630.0
let og = context(Int(W), Int(H))
og.setFillColor(cream)
og.fill(CGRect(x: 0, y: 0, width: W, height: H))

// Faint hex tiles, like the map's (and the site's background).
og.setStrokeColor(sand.copy(alpha: 0.7)!)
og.setLineWidth(1.5)
let r = 42.0
for row in 0..<12 {
    for col in 0..<18 {
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

/// Core Graphics measures from the bottom; the layout below is easier from the top.
func fromTop(_ y: Double, _ height: Double = 0) -> Double { H - y - height }

// A patch of sky behind the phones, like the home page's hero.
let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
    CGColor(srgbRed: 0.827, green: 0.914, blue: 0.969, alpha: 1),
    CGColor(srgbRed: 0.812, green: 0.902, blue: 0.969, alpha: 0),
] as CFArray, locations: [0, 1])!
og.drawRadialGradient(sky, startCenter: CGPoint(x: 900, y: fromTop(300)), startRadius: 0,
                      endCenter: CGPoint(x: 900, y: fromTop(300)), endRadius: 330, options: [])

// The icon on its white die-cut edge, and the name beside it.
let iconRect = CGRect(x: 80, y: fromTop(78, 104), width: 104, height: 104)
og.saveGState()
og.setShadow(offset: CGSize(width: 0, height: -5), blur: 16, color: CGColor(srgbRed: 0.27, green: 0.18, blue: 0.1, alpha: 0.22))
og.setFillColor(.white)
og.addPath(CGPath(roundedRect: iconRect.insetBy(dx: -5, dy: -5), cornerWidth: 29, cornerHeight: 29, transform: nil))
og.fillPath()
og.restoreGState()
og.saveGState()
og.addPath(CGPath(roundedRect: iconRect, cornerWidth: 24, cornerHeight: 24, transform: nil))
og.clip()
og.draw(icon, in: iconRect)
og.restoreGState()

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
}

/// Text wrapped to `width`, its first line's top `top` from the top of the card.
func draw(_ text: String, font: CTFont, colour: CGColor, x: Double, top: Double, width: Double, lineHeight: Double? = nil) {
    let paragraph = NSMutableParagraphStyle()
    if let lineHeight {
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
    }
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .paragraphStyle: paragraph]
    let frame = CTFramesetterCreateFrame(
        CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)),
        CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: x, y: fromTop(top, 400), width: width, height: 400), transform: nil), nil)
    CTFrameDraw(frame, og)
}

draw("Walkies", font: rounded(66, .heavy), colour: ink, x: 210, top: 92, width: 400)
// Broken by hand, so "suburb" isn't left on a line of its own.
draw("An app for walking\nevery street in\nyour suburb", font: rounded(54, .heavy), colour: ink,
     x: 80, top: 222, width: 560, lineHeight: 60)
draw("It's free on iPhone, and there's no ads.", font: rounded(27, .medium), colour: inkSoft, x: 82, top: 428, width: 560)
draw("walkies.mikecann.app", font: rounded(27, .bold), colour: burnt, x: 82, top: 494, width: 560)

/// A screenshot in a phone, centred on (x, y from the top) and turned by `degrees`
/// (clockwise, like CSS).
func phone(_ name: String, x: Double, y: Double, width: Double, degrees: Double) {
    let shot = load("web/public/screens/\(name).webp")
    let inset = width * 0.03
    let screen = CGSize(width: width - inset * 2, height: (width - inset * 2) * Double(shot.height) / Double(shot.width))
    let frame = CGRect(x: -width / 2, y: -(screen.height / 2 + inset), width: width, height: screen.height + inset * 2)
    og.saveGState()
    og.translateBy(x: x, y: fromTop(y))
    og.rotate(by: -degrees * .pi / 180)
    og.saveGState()
    og.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: CGColor(srgbRed: 0.27, green: 0.17, blue: 0.1, alpha: 0.35))
    og.setFillColor(CGColor(srgbRed: 0.17, green: 0.14, blue: 0.12, alpha: 1))
    og.addPath(CGPath(roundedRect: frame, cornerWidth: width * 0.165, cornerHeight: width * 0.165, transform: nil))
    og.fillPath()
    og.restoreGState()
    let screenRect = frame.insetBy(dx: inset, dy: inset)
    og.addPath(CGPath(roundedRect: screenRect, cornerWidth: width * 0.135, cornerHeight: width * 0.135, transform: nil))
    og.clip()
    og.draw(shot, in: screenRect)
    og.restoreGState()
}

phone("map", x: 800, y: 372, width: 262, degrees: -7)
phone("recap", x: 990, y: 342, width: 272, degrees: 4)
save(og.makeImage()!, "og.jpg")
