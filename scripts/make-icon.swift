// Draws the app icon: a foggy hex grid with a trail of uncovered tiles and a paw.
// Usage: swift scripts/make-icon.swift Walkies/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let s = 1024.0
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func rgb(_ hex: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: a)
}

// Night-fog background.
let gradient = CGGradient(colorsSpace: space, colors: [rgb(0x283566), rgb(0x141A36)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

// The trail the tiles get uncovered along, bottom left to top right.
func trail(_ t: Double) -> CGPoint {
    CGPoint(x: 90 + t * 860, y: 120 + t * 790 + sin(t * .pi * 2.2) * 120)
}
func distanceToTrail(_ p: CGPoint) -> (Double, Double) {
    var best = (Double.infinity, 0.0)
    for i in 0...400 {
        let t = Double(i) / 400
        let q = trail(t)
        let d = hypot(p.x - q.x, p.y - q.y)
        if d < best.0 { best = (d, t) }
    }
    return best
}

// Pointy-top hexes.
let r = 66.0
let w = r * 3.0.squareRoot()
for row in -1...10 {
    for col in -1...9 {
        let cx = Double(col) * w + (row % 2 == 0 ? 0 : w / 2)
        let cy = Double(row) * r * 1.5
        let path = CGMutablePath()
        for i in 0..<6 {
            let a = (60 * Double(i) - 30) * .pi / 180
            let inset = r - 5
            let p = CGPoint(x: cx + inset * cos(a), y: cy + inset * sin(a))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        let (d, t) = distanceToTrail(CGPoint(x: cx, y: cy))
        ctx.addPath(path)
        if d < r * 0.9 {
            ctx.setFillColor(t > 0.72 ? rgb(0xFF782E) : rgb(0x22A699))
        } else {
            ctx.setFillColor(rgb(0xFFFFFF, 0.07))
        }
        ctx.fillPath()
    }
}

// The paw.
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let config = NSImage.SymbolConfiguration(pointSize: 380, weight: .black)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let paw = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let pawSize = paw.size
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
paw.draw(in: NSRect(x: (s - pawSize.width) / 2, y: (s - pawSize.height) / 2, width: pawSize.width, height: pawSize.height))

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("Wrote \(url.path)")
