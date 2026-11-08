import MapKit
import Metal
import Testing
@testable import Walkies

/// The prototype's shader has to agree with `CloudScene`, or the clouds would sit in the
/// wrong place and the walked tiles wouldn't line up with their holes.
@MainActor
struct GPUCloudsTests {
    @Test func theShaderDrawsTheCloudsWhereTheBakeDoes() throws {
        let field = CloudFixtures.clearingField().after
        for (zoom, tilt) in [(0.2, 0.0), (0.2, 40.0), (1.0, 40.0)] {
            var camera = TestCamera().zoomed(zoom).tipped(tilt)
            camera.centre = field.clearings[0].centre
            let bounds = CGRect(origin: .zero, size: camera.size)
            let gpu = try #require(GPUClouds())
            let picture = try #require(gpu.picture(
                GPUClouds.Scene(field: field, key: "a", theme: "clouds.classic", projection: camera.projection, size: camera.size, clock: 1000),
                scale: 1
            ))
            let scene = CloudScene(field: field, projection: camera.projection, bounds: bounds, clock: 1000)
            let baked = try #require(CloudBakery.render(bounds, scale: 1) { scene.drawClouds(in: $0, sprites: CloudSprites.sprites(for: "clouds.classic")) })

            let w = picture.width, h = picture.height
            var drawn = [UInt8](repeating: 0, count: w * h * 4)
            picture.getBytes(&drawn, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            var expected = [UInt8](repeating: 0, count: w * h * 4)
            expected.withUnsafeMutableBytes { raw in
                let c = CGContext(
                    data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                )
                c?.draw(baked, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            var total = 0, big = 0, count = 0, solid = 0
            for y in stride(from: 0, to: h, by: 4) {
                for x in stride(from: 0, to: w, by: 4) {
                    let i = (y * w + x) * 4 + 3
                    let d = abs(Int(drawn[i]) - Int(expected[i]))
                    total += d
                    if d > 64 { big += 1 }
                    if expected[i] > 200 { solid += 1 }
                    count += 1
                }
            }
            #expect(solid > count / 20, "zoom \(zoom) tilt \(tilt): should have plenty of cloud, has \(solid) of \(count)")
            #expect(Double(total) / Double(count) < 12, "zoom \(zoom) tilt \(tilt): differs by \(Double(total) / Double(count)) of 255 on average")
            #expect(Double(big) / Double(count) < 0.03, "zoom \(zoom) tilt \(tilt): \(big) of \(count) spots are far off")
        }
    }
}
