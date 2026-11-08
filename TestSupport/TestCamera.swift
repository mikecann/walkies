import CoreGraphics
import MapKit
@testable import Walkies

// Shared by both test targets, WalkiesTests and WalkiesTimingTests.

/// A stand-in for MapKit's camera: looking down on `centre` from above, turned to
/// `heading` and tipped back by `pitch`, `zoom` screen points to the map point.
struct TestCamera {
    var centre = MKMapPoint(CLLocationCoordinate2D(latitude: -33.64, longitude: 115.39))
    var zoom = 0.5
    var heading = 0.0
    var pitch = 0.0
    var size = CGSize(width: 414, height: 896)
    /// How far the camera is from the middle of the screen, in screen points.
    static let distance = 1000.0

    func pan(_ dx: Double, _ dy: Double) -> TestCamera {
        var c = self
        // A drag of (dx, dy) points moves the ground the other way.
        let h = heading * .pi / 180
        let gx = (cos(h) * dx - sin(h) * dy) / zoom, gy = (sin(h) * dx + cos(h) * dy) / zoom
        c.centre = MKMapPoint(x: centre.x + gx, y: centre.y + gy)
        return c
    }

    func zoomed(_ f: Double) -> TestCamera { var c = self; c.zoom *= f; return c }
    func turned(_ degrees: Double) -> TestCamera { var c = self; c.heading += degrees; return c }
    func tipped(_ degrees: Double) -> TestCamera { var c = self; c.pitch = degrees; return c }

    /// A ground point on screen, or nil if it's behind the camera.
    func screen(_ p: MKMapPoint) -> CGPoint? {
        let h = heading * .pi / 180, t = pitch * .pi / 180
        let dx = p.x - centre.x, dy = p.y - centre.y
        let rx = (cos(h) * dx + sin(h) * dy) * zoom
        let ry = (-sin(h) * dx + cos(h) * dy) * zoom
        let w = 1 - ry * sin(t) / Self.distance
        guard w > 0 else { return nil }
        return CGPoint(x: rx / w + size.width / 2, y: ry * cos(t) / w + size.height / 2)
    }

    /// The ground under a screen point.
    func ground(_ s: CGPoint) -> MKMapPoint {
        let h = heading * .pi / 180, t = pitch * .pi / 180
        let x = Double(s.x - size.width / 2), y = Double(s.y - size.height / 2)
        let ry = y / (cos(t) + y * sin(t) / Self.distance)
        let w = 1 - ry * sin(t) / Self.distance
        let rx = x * w
        let dx = (cos(h) * rx - sin(h) * ry) / zoom, dy = (sin(h) * rx + cos(h) * ry) / zoom
        return MKMapPoint(x: centre.x + dx, y: centre.y + dy)
    }

    /// Measured as the app measures MapKit's.
    var projection: Projection {
        let screen = Projection.spots.map { CGPoint(x: $0.0 * size.width, y: $0.1 * size.height) }
        return Projection(ground: screen.map(ground), screen: screen, width: Double(size.width), centre: centre)
    }
}

/// The alpha of every pixel of an image, rows from the top.
struct Alphas {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(_ image: CGImage) {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        width = w
        height = h
        data = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
    }

    /// At a point given as fractions of the width and height.
    func at(_ fx: Double, _ fy: Double) -> Int {
        let x = min(width - 1, max(0, Int(fx * Double(width)))), y = min(height - 1, max(0, Int(fy * Double(height))))
        return Int(data[y * width + x])
    }
}
