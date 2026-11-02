import MapKit
import Metal
import QuartzCore

/// A prototype of drawing the clouds on the GPU every frame rather than baking pictures.
/// Every puff, hole and patch of mist is a quad from a sprite array, placed by the vertex
/// shader from one buffer that only changes when the tiles do and the camera's homography,
/// so moving the map or drifting the clouds does no per-puff work on the CPU at all.
///
/// Only the clouds: the dashed lines still come from a bake, warped over this.
///
/// One known difference from the baked clouds, as it's a prototype: holes aren't clipped
/// to the places' outlines, so one on an edge can cut into a puff that spills over it.
nonisolated final class GPUClouds: @unchecked Sendable {
    /// What to draw.
    struct Scene {
        var field: CloudField
        var key: String
        var theme: String
        var projection: Projection
        var size: CGSize
        var clock: Double
        var reveal: Reveal?

        /// Tiles clearing.
        struct Reveal {
            /// Tells one lot of tiles clearing from the next.
            var started: Double
            var progress: Double
            var leaving: [CloudField.Puff]
            var leavingMist: [CloudField.MistPatch]
            var fresh: Set<CloudField.Tile>
        }
    }

    /// The most pixels a point. The clouds are soft, and each extra pixel is many puffs' fill.
    static let maxScale = 1.5

    let layer = CAMetalLayer()
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let over: any MTLRenderPipelineState
    private let erase: any MTLRenderPipelineState
    private let under: any MTLRenderPipelineState
    private let mistWash: any MTLRenderPipelineState
    private let mistUnder: any MTLRenderPipelineState

    private struct Instances {
        var buffer: (any MTLBuffer)?
        var count = 0

        init(device: any MTLDevice, _ puffs: [PuffData]) {
            count = puffs.count
            guard !puffs.isEmpty else { return }
            buffer = device.makeBuffer(bytes: puffs, length: puffs.count * MemoryLayout<PuffData>.stride, options: .storageModeShared)
        }
    }

    private var sprites: [String: any MTLTexture] = [:]
    private let spriteLock = NSLock()
    private var built: (key: String, puffs: Instances, clearings: Instances, mist: Instances, radius: Double?, freshKey: Double?)?
    private var builtReveal: (started: Double, leaving: Instances, mist: Instances)?
    private var mistTarget: (any MTLTexture)?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: gpuCloudsShader, options: nil)
        else { return nil }
        self.device = device
        self.queue = queue

        func pipeline(_ vertex: String, _ fragment: String, _ configure: (MTLRenderPipelineColorAttachmentDescriptor) -> Void) -> (any MTLRenderPipelineState)? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            let colour = d.colorAttachments[0]!
            colour.pixelFormat = .bgra8Unorm
            colour.isBlendingEnabled = true
            configure(colour)
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        func both(_ c: MTLRenderPipelineColorAttachmentDescriptor, _ source: MTLBlendFactor, _ destination: MTLBlendFactor) {
            c.sourceRGBBlendFactor = source
            c.sourceAlphaBlendFactor = source
            c.destinationRGBBlendFactor = destination
            c.destinationAlphaBlendFactor = destination
        }
        guard let over = pipeline("puffVertex", "puffFragment", { both($0, .one, .oneMinusSourceAlpha) }),
              // Soft holes: takes away from what's there by how solid the eraser is.
              let erase = pipeline("puffVertex", "puffFragment", { both($0, .zero, .oneMinusSourceAlpha) }),
              // Under everything already drawn, so shadows are on the ground without a
              // whole extra picture to composite the clouds in. The same result.
              let under = pipeline("puffVertex", "puffFragment", { both($0, .oneMinusDestinationAlpha, .one) }),
              // Where patches of mist overlap, one even wash rather than building up.
              let mistWash = pipeline("puffVertex", "puffFragment", {
                  both($0, .one, .one)
                  $0.rgbBlendOperation = .max
                  $0.alphaBlendOperation = .max
              }),
              let mistUnder = pipeline("wholeVertex", "wholeFragment", { both($0, .oneMinusDestinationAlpha, .one) })
        else { return nil }
        self.over = over
        self.erase = erase
        self.under = under
        self.mistWash = mistWash
        self.mistUnder = mistUnder

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.maximumDrawableCount = 3
        // In step with the Core Animation transaction the lines' warp is in, or the
        // clouds would be a frame off the lines, and the map, as you drag.
        layer.presentsWithTransaction = true
    }

    /// Makes a look's sprite array ahead of time, off the main thread: it's the slow part
    /// of the first frame.
    func prepare(theme: String) {
        spriteLock.lock()
        defer { spriteLock.unlock() }
        _ = spriteArray(theme)
    }

    /// Draws to the layer, in the current Core Animation transaction.
    @MainActor
    func present(_ scene: Scene, displayScale: Double) {
        let scale = min(displayScale, Self.maxScale)
        let drawable = CGSize(width: (scene.size.width * scale).rounded(), height: (scene.size.height * scale).rounded())
        layer.bounds = CGRect(origin: .zero, size: scene.size)
        if layer.drawableSize != drawable {
            layer.contentsScale = scale
            layer.drawableSize = drawable
        }
        guard drawable.width > 0, let target = layer.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        let started = CACurrentMediaTime()
        guard encode(scene, into: target.texture, on: commands) else { return }
        commands.addCompletedHandler { buffer in
            let gpu = buffer.gpuEndTime - buffer.gpuStartTime
            DispatchQueue.main.async {
                let stats = CloudRenderStats.shared
                stats.gpuFrames += 1
                stats.gpuMilliseconds += gpu * 1000
                stats.gpuLongest = max(stats.gpuLongest, gpu * 1000)
            }
        }
        commands.commit()
        commands.waitUntilScheduled()
        target.present()
        CloudRenderStats.shared.gpuEncodeMilliseconds += (CACurrentMediaTime() - started) * 1000
    }

    /// Draws to a new texture and waits, for tests.
    func picture(_ scene: Scene, scale: Double) -> (any MTLTexture)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Int(scene.size.width * scale), height: Int(scene.size.height * scale), mipmapped: false
        )
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d), let commands = queue.makeCommandBuffer(),
              encode(scene, into: target, on: commands)
        else { return nil }
        commands.commit()
        commands.waitUntilCompleted()
        return target
    }

    // MARK: Drawing

    /// Blanket first, then holes, then what goes under it, which is why there's no layer
    /// to composite: the same picture `CloudScene` makes with one.
    private func encode(_ scene: Scene, into target: any MTLTexture, on commands: any MTLCommandBuffer) -> Bool {
        spriteLock.lock()
        let array = spriteArray(scene.theme)
        spriteLock.unlock()
        guard let uniforms = FrameData(scene), let atlas = array else { return false }
        let data = instances(scene)
        var frame = uniforms
        let centreScale = scene.projection.centreScale
        frame.centreScale = Float(centreScale)

        let reveal = scene.reveal
        let ease = reveal.map { 1 - pow(1 - $0.progress, 3) } ?? 1
        frame.ease = Float(ease)
        let leaving = revealInstances(reveal)

        // Mist on its own first, to go under as one wash.
        let misty = data.mist.count > 0 || leaving.mist.count > 0
        if misty, let mist = mistTexture(like: target) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = mist
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pass.colorAttachments[0].storeAction = .store
            if let e = commands.makeRenderCommandEncoder(descriptor: pass) {
                e.setVertexBytes(&frame, length: MemoryLayout<FrameData>.stride, index: 1)
                e.setFragmentTexture(atlas, index: 0)
                e.setRenderPipelineState(mistWash)
                draw(e, data.mist, PassData(slice: Sprite.mist))
                draw(e, leaving.mist, PassData(slice: Sprite.mist, alpha: Float(1 - ease)))
                e.endEncoding()
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        guard let e = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        e.setVertexBytes(&frame, length: MemoryLayout<FrameData>.stride, index: 1)
        e.setFragmentTexture(atlas, index: 0)

        // Zoomed out, a puff is only a few points across, and its shadow and underside
        // barely show. CloudScene's detail, from the same reference radius.
        let radius = data.radius ?? (reveal?.leaving.first?.radius ?? 0)
        let puffSize = radius * 2 * centreScale
        let detail = Float(min(1, max(0, (puffSize - CloudScene.simplePuff) / CloudScene.simplePuff)))
        let leavingScale = Float(1 + 0.5 * ease)
        let leavingFade = Float(1 - ease)

        e.setRenderPipelineState(over)
        if detail > 0 {
            draw(e, data.puffs, PassData(slice: Sprite.bases, alpha: detail))
            draw(e, leaving.puffs, PassData(slice: Sprite.bases, alpha: leavingFade * detail, radiusScale: leavingScale))
        }
        draw(e, data.puffs, PassData(slice: Sprite.tops, phaseShift: 0.7))
        draw(e, leaving.puffs, PassData(slice: Sprite.tops, alpha: leavingFade, radiusScale: leavingScale, phaseShift: 0.7))

        e.setRenderPipelineState(erase)
        draw(e, data.clearings, PassData(slice: Sprite.eraser, drifts: 0))

        if misty, let mist = mistTarget {
            e.setRenderPipelineState(mistUnder)
            var alpha = Float(CloudScene.mistOpacity)
            e.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 0)
            e.setFragmentTexture(mist, index: 0)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            e.setFragmentTexture(atlas, index: 0)
        }
        if detail > 0 {
            e.setRenderPipelineState(under)
            let offset = (x: Float(0.15), y: Float(0.18))
            draw(e, data.puffs, PassData(slice: Sprite.shadows, alpha: 0.35 * detail, offsetX: offset.x, offsetY: offset.y))
            draw(e, leaving.puffs, PassData(slice: Sprite.shadows, alpha: 0.35 * leavingFade * detail, radiusScale: leavingScale, offsetX: offset.x, offsetY: offset.y))
        }
        e.endEncoding()
        return true
    }

    private func draw(_ e: any MTLRenderCommandEncoder, _ instances: Instances, _ pass: PassData) {
        guard instances.count > 0, let buffer = instances.buffer else { return }
        var pass = pass
        e.setVertexBuffer(buffer, offset: 0, index: 0)
        e.setVertexBytes(&pass, length: MemoryLayout<PassData>.stride, index: 2)
        e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }

    private func mistTexture(like target: any MTLTexture) -> (any MTLTexture)? {
        // A quarter the pixels: it's nothing but soft edges.
        let w = max(1, target.width / 2), h = max(1, target.height / 2)
        if let mistTarget, mistTarget.width == w, mistTarget.height == h { return mistTarget }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        mistTarget = device.makeTexture(descriptor: d)
        return mistTarget
    }

    private func instances(_ scene: Scene) -> (puffs: Instances, clearings: Instances, mist: Instances, radius: Double?) {
        let freshKey = scene.reveal?.started
        if let built, built.key == scene.key, built.freshKey == freshKey {
            return (built.puffs, built.clearings, built.mist, built.radius)
        }
        let field = scene.field
        let puffs: Instances
        let mist: Instances
        if let built, built.key == scene.key {
            // Only which holes are opening has changed.
            (puffs, mist) = (built.puffs, built.mist)
        } else {
            puffs = Instances(device: device, field.puffs.map { PuffData($0.centre, radius: $0.radius, phase: $0.phase, variant: $0.variant) })
            mist = Instances(device: device, field.mist.map { PuffData($0.centre, radius: $0.radius) })
        }
        let fresh = scene.reveal?.fresh ?? []
        let clearings = Instances(device: device, field.clearings.map { PuffData($0.centre, radius: $0.radius, fresh: fresh.contains($0.tile)) })
        let radius = field.puffs.first?.radius
        built = (scene.key, puffs, clearings, mist, radius, freshKey)
        return (puffs, clearings, mist, radius)
    }

    private func revealInstances(_ reveal: Scene.Reveal?) -> (puffs: Instances, mist: Instances) {
        guard let reveal else {
            builtReveal = nil
            return (Instances(device: device, []), Instances(device: device, []))
        }
        if let builtReveal, builtReveal.started == reveal.started { return (builtReveal.leaving, builtReveal.mist) }
        let puffs = Instances(device: device, reveal.leaving.map { PuffData($0.centre, radius: $0.radius, phase: $0.phase, variant: $0.variant) })
        let mist = Instances(device: device, reveal.leavingMist.map { PuffData($0.centre, radius: $0.radius) })
        builtReveal = (reveal.started, puffs, mist)
        return (puffs, mist)
    }

    // MARK: Sprites

    /// Where each kind of sprite starts in the array.
    private enum Sprite {
        static let bases: Float = 0
        static let tops = Float(CloudSprites.count)
        static let shadows = Float(CloudSprites.count * 2)
        static let eraser = Float(CloudSprites.count * 3)
        static let mist = eraser + 1
    }

    /// The look's sprites in one mipmapped texture array, made the first time it's used.
    private func spriteArray(_ theme: String) -> (any MTLTexture)? {
        if let made = sprites[theme] { return made }
        let source = CloudSprites.sprites(for: theme)
        let images = source.bases + source.tops + source.shadows + [source.eraser, source.mist]
        let side = 256
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .bgra8Unorm
        d.width = side
        d.height = side
        d.arrayLength = images.count
        d.mipmapLevelCount = 9
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder()
        else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for (slice, image) in images.enumerated() {
            bytes.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space, bitmapInfo: info)
                context?.clear(CGRect(x: 0, y: 0, width: side, height: side))
                context?.interpolationQuality = .high
                context?.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            }
            texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, slice: slice, withBytes: bytes, bytesPerRow: side * 4, bytesPerImage: 0)
        }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        sprites[theme] = texture
        return texture
    }
}

/// As `Puff` in GPUClouds.metal.
nonisolated private struct PuffData {
    var cell: SIMD2<Float>
    var offset: SIMD2<Float>
    var radius: Float
    var phase: Float
    var variant: Float
    var fresh: Float

    init(_ centre: MKMapPoint, radius: Double, phase: Double = 0, variant: Int = 0, fresh: Bool = false) {
        (cell, offset) = FrameData.split(centre.x, centre.y)
        self.radius = Float(radius)
        self.phase = Float(phase)
        self.variant = Float(variant)
        self.fresh = fresh ? 1 : 0
    }
}

/// As `Pass` in GPUClouds.metal. Which sprites to draw and how.
nonisolated private struct PassData {
    var slice: Float
    var alpha: Float = 1
    var radiusScale: Float = 1
    var phaseShift: Float = 0
    var drifts: Float = 1
    var offsetX: Float = 0
    var offsetY: Float = 0
    var pad: Float = 0
}

/// As `Frame` in GPUClouds.metal.
nonisolated private struct FrameData {
    var row0: (Float, Float, Float, Float)
    var row1: (Float, Float, Float, Float)
    var row2: (Float, Float, Float, Float)
    var originCell: SIMD2<Float>
    var originOffset: SIMD2<Float>
    var unit: Float
    var width: Float
    var points: SIMD2<Float>
    var centreScale: Float = 0
    var ease: Float = 1
    var clockX: Float
    var clockY: Float
    var clockSwell: Float
    var pad: Float = 0

    static let cell = 65536.0

    /// A map point as a whole cell and how far into it, which floats can hold exactly enough.
    static func split(_ x: Double, _ y: Double) -> (SIMD2<Float>, SIMD2<Float>) {
        let cx = (x / cell).rounded(.down), cy = (y / cell).rounded(.down)
        return (SIMD2(Float(cx), Float(cy)), SIMD2(Float(x - cx * cell), Float(y - cy * cell)))
    }

    init?(_ scene: GPUClouds.Scene) {
        guard let ground = scene.projection.groundMeasure else { return nil }
        let h = ground.h
        row0 = (Float(h[0]), Float(h[1]), Float(h[2]), 0)
        row1 = (Float(h[3]), Float(h[4]), Float(h[5]), 0)
        row2 = (Float(h[6]), Float(h[7]), 1, 0)
        (originCell, originOffset) = Self.split(ground.origin.x, ground.origin.y)
        unit = Float(ground.unit)
        width = Float(ground.width)
        points = SIMD2(Float(scene.size.width), Float(scene.size.height))
        // Wrapped here, as a date's far too big for a float in the shader.
        func wrapped(_ rate: Double) -> Float { Float((scene.clock * rate).truncatingRemainder(dividingBy: 2 * .pi)) }
        clockX = wrapped(0.23)
        clockY = wrapped(0.19)
        clockSwell = wrapped(0.31)
    }
}

/// Compiled when the app first needs it, so the prototype doesn't taskpolicy -b make every machine that
/// builds Walkies install Xcode's Metal toolchain. A real version would be a `.metal` file.
nonisolated private let gpuCloudsShader = #"""
#include <metal_stdlib>
using namespace metal;

// The GPU clouds prototype: every puff a textured quad worked out here in the vertex
// shader, from data that only changes when the tiles do. See GPUClouds.swift.

// Map points are too big for a float (a tile near the other side of the world would be
// tens of metres out), so positions are a whole cell and an offset into it.
constant float cellSize = 65536.0;
constant float near = 0.02;

struct Puff {
    float2 cell;
    float2 offset;
    float radius;
    float phase;
    // Which sprite of its kind.
    float variant;
    // 1 for a hole that's just been walked, which opens up rather than just appearing.
    float fresh;
};

struct Frame {
    // Normalised ground to screen over width, as Projection's h.
    packed_float4 row0;
    packed_float4 row1;
    packed_float4 row2;
    float2 originCell;
    float2 originOffset;
    float unit;
    float width;
    float2 points;
    // Screen points per map point mid-screen.
    float centreScale;
    float ease;
    // sin/cos arguments already wrapped to a full turn, as a date's too big for a float.
    float clockX;
    float clockY;
    float clockSwell;
    float pad;
};

struct Pass {
    float slice;
    float alpha;
    float radiusScale;
    float phaseShift;
    float drifts;
    float offsetX;
    float offsetY;
    float pad;
};

struct Out {
    float4 position [[position]];
    float2 uv;
    float alpha;
    float slice;
};

static float3 homogeneous(float2 cell, float2 offset, float2 extra, constant Frame &f) {
    // Differences first, so the big numbers cancel before anything's divided.
    float2 p = ((cell - f.originCell) * cellSize + (offset - f.originOffset) + extra) / f.unit;
    return float3(f.row0.x * p.x + f.row0.y * p.y + f.row0.z,
                  f.row1.x * p.x + f.row1.y * p.y + f.row1.z,
                  f.row2.x * p.x + f.row2.y * p.y + 1);
}

static float2 toScreen(float3 v, constant Frame &f) {
    return v.xy / max(v.z, near) * f.width;
}

vertex Out puffVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                      constant Puff *puffs [[buffer(0)]],
                      constant Frame &f [[buffer(1)]],
                      constant Pass &pass [[buffer(2)]]) {
    Puff puff = puffs[iid];
    Out out;
    float2 corner = float2(vid & 1, (vid >> 1) & 1);
    out.uv = corner;
    out.slice = pass.slice + puff.variant;
    out.alpha = pass.alpha;

    float grow = puff.fresh > 0 ? 0.3 + 0.7 * f.ease : 1.0;
    float radius = puff.radius * pass.radiusScale * grow;
    float3 centre = homogeneous(puff.cell, puff.offset, float2(0), f);
    if (centre.z < near) {
        // Behind the camera: a quad of nothing.
        out.position = float4(2, 2, 0, 1);
        return out;
    }
    float2 c = toScreen(centre, f);
    float rx = length(toScreen(homogeneous(puff.cell, puff.offset, float2(radius, 0), f), f) - c);
    float ry = length(toScreen(homogeneous(puff.cell, puff.offset, float2(0, radius), f), f) - c);
    // Clouds right by a tilted camera would balloon, so none get more than twice the
    // size they'd be mid-screen. CloudScene.capped.
    float limit = radius * 2 * f.centreScale * 2;
    float biggest = max(rx, ry) * 2;
    if (limit > 0 && biggest > limit) {
        float shrink = limit / biggest;
        rx *= shrink;
        ry *= shrink;
    }
    // Bobbing gently around its tile and swelling a touch. CloudScene's drift.
    if (pass.drifts > 0) {
        float phase = puff.phase + pass.phaseShift;
        c.x += sin(f.clockX + phase) * 0.07 * rx * 2;
        c.y += cos(f.clockY + phase * 1.7) * 0.06 * ry * 2;
        float swell = 1 + 0.05 * sin(f.clockSwell + phase * 2.3);
        rx *= swell;
        ry *= swell;
    }
    c.x += rx * 2 * pass.offsetX;
    c.y += ry * 2 * pass.offsetY;

    float2 p = c + (corner * 2 - 1) * float2(rx, ry);
    out.position = float4(p.x / f.points.x * 2 - 1, 1 - p.y / f.points.y * 2, 0, 1);
    return out;
}

fragment float4 puffFragment(Out in [[stage_in]], texture2d_array<float> sprites [[texture(0)]]) {
    // Mipmapped, so a small puff reads a small copy of its sprite.
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    return sprites.sample(s, in.uv, uint(in.slice + 0.5)) * in.alpha;
}

struct WholeOut {
    float4 position [[position]];
    float2 uv;
};

vertex WholeOut wholeVertex(uint vid [[vertex_id]]) {
    float2 corner = float2(vid & 1, (vid >> 1) & 1);
    WholeOut out;
    out.position = float4(corner.x * 2 - 1, 1 - corner.y * 2, 0, 1);
    out.uv = corner;
    return out;
}

fragment float4 wholeFragment(WholeOut in [[stage_in]], texture2d<float> picture [[texture(0)]], constant float &alpha [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return picture.sample(s, in.uv) * alpha;
}
"""#
