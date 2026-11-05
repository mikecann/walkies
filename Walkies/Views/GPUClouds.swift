import MapKit
import Metal
import QuartzCore

/// The clouds, drawn on the GPU every frame rather than baked into pictures. Every puff,
/// hole and patch of mist is a quad from a sprite array, placed by the vertex shader from
/// one buffer that only changes when the tiles do and the camera's homography, so moving
/// the map or drifting the clouds does no per-puff work on the CPU at all. On Mike's
/// iPhone 15 Pro Max, with 17,000 puffs, that took a still map from about 25% of a core
/// (baking every 2.5 s for the drift) to 5%, for 2 to 4 ms of GPU a frame.
///
/// Only the clouds: the dashed lines still come from a bake, warped over this.
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
        /// The clouds over the rest of the world too, outside your places.
        var world: World?
        /// The coloured honeycomb over the clouds while you drag, or nil when it's not showing.
        var honeycomb: Honeycomb?

        struct Honeycomb {
            var opacity: Double
            /// The tiles walked on this walk, drawn orange.
            var walkTiles: Set<CloudField.Tile>
            /// Tells one lot of `walkTiles` from another without comparing them.
            var walkKey: Int
        }

        struct World {
            /// Your places' outlines: no world clouds inside them.
            var rings: [WorldCloudLayout.Ring]
            var walked: [Int64: [MKMapPoint]]
            /// Changes whenever the walked tiles do.
            var revision: Int
        }

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
    /// The places' outlines into the stencil, and where holes may be cut.
    private let clipFill: any MTLRenderPipelineState
    private let invertStencil: any MTLDepthStencilState
    private let insideStencil: any MTLDepthStencilState
    private let anywhere: any MTLDepthStencilState
    private let outsideStencil: any MTLDepthStencilState
    private let hexFill: any MTLRenderPipelineState
    private let hexStroke: any MTLRenderPipelineState
    /// Each pixel of a style's outlines drawn once, so where two hexes share an edge it
    /// isn't twice as strong (as one path stroked in Core Graphics isn't).
    private let oncePerStyle: any MTLDepthStencilState
    /// The honeycomb's hexes for the tiles they were made for, by style.
    private var builtHexes: (key: String, walkKey: Int, styles: [Instances])?
    private lazy var hexStyles: (any MTLBuffer)? = {
        var styles: [SIMD4<Float>] = []
        for style in HoneycombScene.styles {
            func premultiplied(_ c: SceneColour, _ a: Double) -> SIMD4<Float> {
                SIMD4(Float(c.red * a), Float(c.green * a), Float(c.blue * a), Float(a))
            }
            styles.append(premultiplied(style.fill, style.fillAlpha))
            styles.append(premultiplied(style.stroke, style.strokeAlpha))
        }
        return device.makeBuffer(bytes: styles, length: styles.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
    }()
    /// The world's puffs for the camera they were laid out for, kept while it's near.
    private var builtWorld: (projection: Projection, size: CGSize, walked: Int, puffs: Instances, holes: Instances, radius: Double)?
    private var stencil: (any MTLTexture)?

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
    private var preparing: Set<String> = []
    private let spriteLock = NSLock()
    /// The last frame had clouds you could actually see: the world's, or your places'
    /// puffs at least a few points across (they're all drawn however far out you are, so
    /// with the map still on its first view of the whole country they're just specks).
    private(set) var lastShowedClouds = false
    private var built: (key: String, puffs: Instances, clearings: Instances, mist: Instances, radius: Double?, freshKey: Double?)?
    private var builtReveal: (started: Double, leaving: Instances, mist: Instances)?
    private var mistTarget: (any MTLTexture)?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: gpuCloudsShader, options: nil)
        else { return nil }
        self.device = device
        self.queue = queue

        /// `stencil` for the main pass, which has one to clip the holes with.
        func pipeline(_ vertex: String, _ fragment: String, stencil: Bool = true, _ configure: (MTLRenderPipelineColorAttachmentDescriptor) -> Void) -> (any MTLRenderPipelineState)? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            if stencil { d.stencilAttachmentPixelFormat = .stencil8 }
            let colour = d.colorAttachments[0]!
            colour.pixelFormat = .bgra8Unorm
            colour.isBlendingEnabled = true
            configure(colour)
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        func stencilState(_ compare: MTLCompareFunction, _ pass: MTLStencilOperation) -> (any MTLDepthStencilState)? {
            let s = MTLStencilDescriptor()
            s.stencilCompareFunction = compare
            s.depthStencilPassOperation = pass
            let d = MTLDepthStencilDescriptor()
            d.frontFaceStencil = s
            d.backFaceStencil = s
            return device.makeDepthStencilState(descriptor: d)
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
              let mistWash = pipeline("puffVertex", "puffFragment", stencil: false, {
                  both($0, .one, .one)
                  $0.rgbBlendOperation = .max
                  $0.alphaBlendOperation = .max
              }),
              let mistUnder = pipeline("wholeVertex", "wholeFragment", { both($0, .oneMinusDestinationAlpha, .one) }),
              let clipFill = pipeline("clipVertex", "clipFragment", { $0.writeMask = [] }),
              // Each outline as a fan of triangles, flipping the stencil as they overlap,
              // leaves it set inside the outline (even-odd) whatever its shape.
              let invertStencil = stencilState(.always, .invert),
              let insideStencil = stencilState(.notEqual, .keep),
              let anywhere = stencilState(.always, .keep),
              let outsideStencil = stencilState(.equal, .keep),
              let hexFill = pipeline("hexFillVertex", "hexFillFragment", { both($0, .one, .oneMinusSourceAlpha) }),
              let hexStroke = pipeline("hexStrokeVertex", "hexStrokeFragment", { both($0, .one, .oneMinusSourceAlpha) }),
              let oncePerStyle = stencilState(.notEqual, .replace)
        else { return nil }
        self.outsideStencil = outsideStencil
        self.hexFill = hexFill
        self.hexStroke = hexStroke
        self.oncePerStyle = oncePerStyle
        self.clipFill = clipFill
        self.invertStencil = invertStencil
        self.insideStencil = insideStencil
        self.anywhere = anywhere
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
        if readySprites(theme) != nil { return }
        let made = makeSpriteArray(theme)
        spriteLock.withLock {
            sprites[theme] = made
            preparing.remove(theme)
        }
    }

    private func readySprites(_ theme: String) -> (any MTLTexture)? {
        spriteLock.withLock { sprites[theme] }
    }

    /// Whether a look's sprites are made, so drawing it now draws it in its own colours.
    func hasSprites(for theme: String) -> Bool { readySprites(theme) != nil }

    /// The look's sprites if they're made, and otherwise any look's while they're made
    /// off the main thread: a moment of the old colours rather than a stutter.
    private func sprites(for theme: String) -> (any MTLTexture)? {
        let (ready, start) = spriteLock.withLock { () -> ((any MTLTexture)?, Bool) in
            if let made = sprites[theme] { return (made, false) }
            let start = !preparing.contains(theme)
            preparing.insert(theme)
            return (sprites.values.first, start)
        }
        if start { DispatchQueue.global(qos: .userInitiated).async { self.prepare(theme: theme) } }
        return ready
    }

    /// Draws to the layer, in the current Core Animation transaction.
    @MainActor
    @discardableResult
    func present(_ scene: Scene, displayScale: Double) -> Bool {
        let scale = min(displayScale, Self.maxScale)
        let drawable = CGSize(width: (scene.size.width * scale).rounded(), height: (scene.size.height * scale).rounded())
        layer.bounds = CGRect(origin: .zero, size: scene.size)
        if layer.drawableSize != drawable {
            layer.contentsScale = scale
            layer.drawableSize = drawable
        }
        guard drawable.width > 0, let target = layer.nextDrawable(), let commands = queue.makeCommandBuffer() else { return false }
        let started = CACurrentMediaTime()
        guard encode(scene, into: target.texture, on: commands) else { return false }
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
        return true
    }

    /// Draws to a new texture and waits, for tests.
    func picture(_ scene: Scene, scale: Double) -> (any MTLTexture)? {
        prepare(theme: scene.theme)
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
        guard let uniforms = FrameData(scene), let atlas = sprites(for: scene.theme), let stencil = stencilTexture(like: target) else { return false }
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
        pass.stencilAttachment.texture = stencil
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.clearStencil = 0
        pass.stencilAttachment.storeAction = .dontCare
        guard let e = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        e.setDepthStencilState(anywhere)
        e.setVertexBytes(&frame, length: MemoryLayout<FrameData>.stride, index: 1)
        e.setFragmentTexture(atlas, index: 0)

        // Zoomed out, a puff is only a few points across, and its shadow and underside
        // barely show. CloudScene's detail, from the same reference radius.
        let radius = data.radius ?? (reveal?.leaving.first?.radius ?? 0)
        let puffSize = radius * 2 * centreScale
        let detail = Float(min(1, max(0, (puffSize - CloudScene.simplePuff) / CloudScene.simplePuff)))
        lastShowedClouds = data.puffs.count > 0 && puffSize >= CloudScene.simplePuff
        let leavingScale = Float(1 + 0.5 * ease)
        let leavingFade = Float(1 - ease)

        // The world's clouds first, outside your places, under your places' own: drawn
        // as MapKit's tiles of them were, without drifting.
        let world = scene.world.map { worldInstances(scene, $0) }
        if let world, world.puffs.count > 0 { lastShowedClouds = true }
        let placesFilled = world != nil && fillRings(e, scene.world?.rings ?? [], scene: scene)
        if let world {
            e.setVertexBytes(&frame, length: MemoryLayout<FrameData>.stride, index: 1)
            e.setRenderPipelineState(over)
            e.setDepthStencilState(placesFilled ? outsideStencil : anywhere)
            draw(e, world.puffs, PassData(slice: Sprite.bases, drifts: 0))
            draw(e, world.puffs, PassData(slice: Sprite.tops, drifts: 0))
            e.setRenderPipelineState(erase)
            draw(e, world.holes, PassData(slice: Sprite.eraser, drifts: 0))
            e.setDepthStencilState(anywhere)
        }

        e.setRenderPipelineState(over)
        if detail > 0 {
            draw(e, data.puffs, PassData(slice: Sprite.bases, alpha: detail))
            draw(e, leaving.puffs, PassData(slice: Sprite.bases, alpha: leavingFade * detail, radiusScale: leavingScale))
        }
        draw(e, data.puffs, PassData(slice: Sprite.tops, phaseShift: 0.7))
        draw(e, leaving.puffs, PassData(slice: Sprite.tops, alpha: leavingFade, radiusScale: leavingScale, phaseShift: 0.7))

        // Zoomed in far enough for streets, the holes stop at the places' outlines as the
        // streets do, or one by an edge would cut into the puffs spilling over it.
        // CloudScene's road clip, made the same way.
        let clipped = data.clearings.count > 0 && centreScale > 0.05 && (placesFilled || fillOutlines(e, scene))
        e.setRenderPipelineState(erase)
        e.setDepthStencilState(clipped ? insideStencil : anywhere)
        e.setVertexBytes(&frame, length: MemoryLayout<FrameData>.stride, index: 1)
        draw(e, data.clearings, PassData(slice: Sprite.eraser, drifts: 0))
        e.setDepthStencilState(anywhere)

        if misty, let mist = mistTarget {
            e.setRenderPipelineState(mistUnder)
            var alpha = Float(CloudScene.mistOpacity)
            e.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 0)
            e.setFragmentTexture(mist, index: 0)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            e.setFragmentTexture(atlas, index: 0)
        }
        if let world {
            e.setRenderPipelineState(under)
            e.setDepthStencilState(placesFilled ? outsideStencil : anywhere)
            draw(e, world.puffs, PassData(slice: Sprite.shadows, alpha: 0.35, drifts: 0, offsetX: 0.15, offsetY: 0.18))
            e.setDepthStencilState(anywhere)
        }
        if detail > 0 {
            e.setRenderPipelineState(under)
            let offset = (x: Float(0.15), y: Float(0.18))
            draw(e, data.puffs, PassData(slice: Sprite.shadows, alpha: 0.35 * detail, offsetX: offset.x, offsetY: offset.y))
            draw(e, leaving.puffs, PassData(slice: Sprite.shadows, alpha: 0.35 * leavingFade * detail, radiusScale: leavingScale, offsetX: offset.x, offsetY: offset.y))
        }
        e.endEncoding()
        if let honeycomb = scene.honeycomb, honeycomb.opacity > 0 {
            encodeHoneycomb(scene, honeycomb, frame: frame, target: target, stencil: stencil, on: commands)
        }
        return true
    }

    /// The honeycomb, drawn live over the clouds every frame rather than baked, so as
    /// you drag there's no picture of it to run off the edge of or swap for the next.
    private func encodeHoneycomb(_ scene: Scene, _ honeycomb: Scene.Honeycomb, frame: FrameData, target: any MTLTexture, stencil: any MTLTexture, on commands: any MTLCommandBuffer) {
        guard let styles = hexStyles else { return }
        let hexes = hexInstances(scene, honeycomb)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.stencilAttachment.texture = stencil
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.clearStencil = 0
        pass.stencilAttachment.storeAction = .dontCare
        guard let e = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var frame = frame
        let scale = Double(target.width) / Double(scene.size.width)
        var uniforms = (Float(honeycomb.opacity), Float(0.6), Float(scale), Float(0))
        e.setVertexBytes(&frame, length: MemoryLayout<FrameData>.stride, index: 1)
        e.setVertexBytes(&uniforms, length: MemoryLayout<(Float, Float, Float, Float)>.size, index: 3)
        e.setFragmentBytes(&uniforms, length: MemoryLayout<(Float, Float, Float, Float)>.size, index: 0)
        e.setVertexBuffer(styles, offset: 0, index: 2)
        // As HoneycombScene draws them: each style's fills, then its outlines, in turn.
        for (index, instances) in hexes.enumerated() where instances.count > 0 {
            guard let buffer = instances.buffer else { continue }
            e.setVertexBuffer(buffer, offset: 0, index: 0)
            e.setRenderPipelineState(hexFill)
            e.setDepthStencilState(anywhere)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 12, instanceCount: instances.count)
            e.setRenderPipelineState(hexStroke)
            e.setDepthStencilState(oncePerStyle)
            e.setStencilReferenceValue(UInt32(index + 1))
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: instances.count)
        }
        e.endEncoding()
    }

    /// The place's hexes by style, made when the tiles or this walk's change.
    private func hexInstances(_ scene: Scene, _ honeycomb: Scene.Honeycomb) -> [Instances] {
        if let built = builtHexes, built.key == scene.key, built.walkKey == honeycomb.walkKey { return built.styles }
        var byStyle = Array(repeating: [HexData](), count: HoneycombScene.styles.count)
        for outline in scene.field.outlines where outline.corners.count == 6 {
            let style = honeycomb.walkTiles.contains(outline.tile) ? 4 : HoneycombScene.index(outline.kind)
            byStyle[style].append(HexData(outline, style: style))
        }
        let styles = byStyle.map { list -> Instances in
            var made = Instances(device: device, [])
            made.count = list.count
            if !list.isEmpty {
                made.buffer = device.makeBuffer(bytes: list, length: list.count * MemoryLayout<HexData>.stride, options: .storageModeShared)
            }
            return made
        }
        builtHexes = (scene.key, honeycomb.walkKey, styles)
        return styles
    }

    private func draw(_ e: any MTLRenderCommandEncoder, _ instances: Instances, _ pass: PassData) {
        guard instances.count > 0, let buffer = instances.buffer else { return }
        var pass = pass
        e.setVertexBuffer(buffer, offset: 0, index: 0)
        e.setVertexBytes(&pass, length: MemoryLayout<PassData>.stride, index: 2)
        e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    }

    /// The places' outlines on screen, into the stencil. False if there are none.
    private func fillOutlines(_ e: any MTLRenderCommandEncoder, _ scene: Scene) -> Bool {
        fillPolygons(e, scene.field.outline, scene: scene)
    }

    /// The world's holes (your places, and any holes in those) into the stencil.
    private func fillRings(_ e: any MTLRenderCommandEncoder, _ rings: [WorldCloudLayout.Ring], scene: Scene) -> Bool {
        fillPolygons(e, rings.map(\.points), scene: scene)
    }

    private func fillPolygons(_ e: any MTLRenderCommandEncoder, _ rings: [[MKMapPoint]], scene: Scene) -> Bool {
        var triangles: [SIMD2<Float>] = []
        for ring in rings {
            // Cut where it passes behind the camera, as the CPU's own clip is.
            let points = scene.projection.polygon(ring).map { SIMD2(Float($0.x), Float($0.y)) }
            guard points.count > 2 else { continue }
            for i in 1..<(points.count - 1) { triangles += [points[0], points[i], points[i + 1]] }
        }
        guard !triangles.isEmpty,
              let buffer = device.makeBuffer(bytes: triangles, length: triangles.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
        else { return false }
        var size = SIMD2(Float(scene.size.width), Float(scene.size.height))
        e.setRenderPipelineState(clipFill)
        e.setDepthStencilState(invertStencil)
        e.setVertexBuffer(buffer, offset: 0, index: 0)
        e.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)
        return true
    }

    /// The world's puffs and walked holes round the camera, laid out as MapKit's tiles of
    /// them were (`WorldCloudLayout`), each patch of ground at the spacing for how big
    /// it is on screen, so further off they're fewer and bigger. Laid out again only once
    /// the camera's moved a good way, as it's thousands of puffs.
    private func worldInstances(_ scene: Scene, _ world: Scene.World) -> (puffs: Instances, holes: Instances, radius: Double) {
        let p = scene.projection
        let walked = world.revision
        if let built = builtWorld, built.size == scene.size, built.walked == walked, p.matches(built.projection, size: scene.size, within: 30) {
            return (built.puffs, built.holes, built.radius)
        }
        let region = BakeFrame.region(p, size: scene.size, margin: 0.25)
        var area = MKMapRect.null
        for corner in [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY),
                       CGPoint(x: region.maxX, y: region.maxY), CGPoint(x: region.minX, y: region.maxY)] {
            guard let g = p.ground(at: corner) else { continue }
            area = area.union(MKMapRect(origin: g, size: MKMapSize(width: 0, height: 0)))
        }
        var puffs: [WorldCloudLayout.Puff] = []
        var seen = Set<SIMD2<Double>>()
        if !area.isNull {
            // Square, so the patches split evenly.
            let side = max(area.width, area.height)
            let root = MKMapRect(x: area.midX - side / 2, y: area.midY - side / 2, width: side, height: side)
            var patches: [(MKMapRect, Double)] = []
            func visit(_ rect: MKMapRect, depth: Int) {
                let corners = [MKMapPoint(x: rect.minX, y: rect.minY), MKMapPoint(x: rect.maxX, y: rect.minY),
                               MKMapPoint(x: rect.maxX, y: rect.maxY), MKMapPoint(x: rect.minX, y: rect.maxY)]
                let inFront = corners.filter(p.isInFront)
                guard !inFront.isEmpty else { return }
                let onScreen = inFront.map(p.point)
                let xs = onScreen.map(\.x), ys = onScreen.map(\.y)
                let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                // Partly behind the camera, or not on screen: only worth a look if it's split.
                if inFront.count < 4 || !box.intersects(region) {
                    if inFront.count < 4, depth < 10 { split(rect, depth) }
                    return
                }
                let middle = MKMapPoint(x: rect.midX, y: rect.midY)
                let scale = p.ellipse(centre: middle, radius: rect.width / 2).width / rect.width
                guard scale.isFinite, scale > 0 else { return }
                if rect.width * scale > 400, depth < 14 { split(rect, depth) } else { patches.append((rect, scale)) }
            }
            func split(_ rect: MKMapRect, _ depth: Int) {
                let w = rect.width / 2, h = rect.height / 2
                for (dx, dy) in [(0.0, 0.0), (w, 0), (0, h), (w, h)] {
                    visit(MKMapRect(x: rect.minX + dx, y: rect.minY + dy, width: w, height: h), depth: depth + 1)
                }
            }
            visit(root, depth: 0)
            for (rect, scale) in patches {
                for puff in WorldCloudLayout.puffs(in: rect, zoomScale: scale) where seen.insert(SIMD2(puff.centre.x, puff.centre.y)).inserted {
                    puffs.append(puff)
                }
            }
        }
        // North first, so further south sits in front, as in each of MapKit's tiles.
        puffs.sort { $0.centre.y < $1.centre.y }
        let holes = area.isNull ? [] : WorldCloudLayout.walked(near: area, in: world.walked)
        let radius = puffs.first.map { $0.box.width / 2 } ?? 0
        let built = (
            projection: p, size: scene.size, walked: walked,
            puffs: Instances(device: device, puffs.map { PuffData($0.centre, radius: $0.box.width / 2, variant: $0.variant) }),
            holes: Instances(device: device, holes.map { PuffData($0, radius: WorldCloudLayout.clearing) }),
            radius: radius
        )
        builtWorld = built
        return (built.puffs, built.holes, built.radius)
    }

    private func stencilTexture(like target: any MTLTexture) -> (any MTLTexture)? {
        if let stencil, stencil.width == target.width, stencil.height == target.height { return stencil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .stencil8, width: target.width, height: target.height, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        stencil = device.makeTexture(descriptor: d)
        return stencil
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

    /// The look's sprites in one mipmapped texture array.
    private func makeSpriteArray(_ theme: String) -> (any MTLTexture)? {
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
        return texture
    }
}

/// As `Puff` in the shader.
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

/// As `HexTile` in the shader.
nonisolated private struct HexData {
    var cell: SIMD2<Float>
    var offset: SIMD2<Float>
    var corners: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
    var style: Float
    var pad: Float = 0

    init(_ outline: CloudField.Outline, style: Int) {
        (cell, offset) = FrameData.split(outline.centre.x, outline.centre.y)
        let c = outline.centre
        func rel(_ i: Int) -> SIMD2<Float> { SIMD2(Float(outline.corners[i].x - c.x), Float(outline.corners[i].y - c.y)) }
        corners = (rel(0), rel(1), rel(2), rel(3), rel(4), rel(5))
        self.style = Float(style)
    }
}

/// As `Pass` in the shader. Which sprites to draw and how.
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

/// As `Frame` in the shader.
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

/// Compiled when the app first needs it (off the main thread, and quick), so that no
/// machine building Walkies needs Xcode's separate Metal toolchain installed. The shader
/// test compiles it too, so a mistake in it fails the tests rather than leaving the map bare.
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

// The honeycomb: each hex an instance, its six corners relative to its centre, filled
// as four triangles and outlined as six thin quads, antialiased across their width.
struct HexTile {
    float2 cell;
    float2 offset;
    float2 corners[6];
    float style;
    float pad;
};

struct HexStyle {
    float4 fill;
    float4 stroke;
};

struct HexUniforms {
    float opacity;
    // Half the line's width in points, and how many pixels a point is.
    float halfWidth;
    float pixelsPerPoint;
    float pad;
};

struct HexOut {
    float4 position [[position]];
    float4 colour;
    // Across the line, in points from its middle.
    float across;
};

static bool hexCorner(constant HexTile &h, int i, constant Frame &f, thread float2 &out) {
    float3 v = homogeneous(h.cell, h.offset, h.corners[i], f);
    if (v.z < near) return false;
    out = toScreen(v, f);
    return true;
}

static float4 toClip(float2 p, constant Frame &f) {
    return float4(p.x / f.points.x * 2 - 1, 1 - p.y / f.points.y * 2, 0, 1);
}

vertex HexOut hexFillVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            constant HexTile *hexes [[buffer(0)]], constant Frame &f [[buffer(1)]],
                            constant HexStyle *styles [[buffer(2)]], constant HexUniforms &u [[buffer(3)]]) {
    constant HexTile &h = hexes[iid];
    int t = int(vid) / 3, k = int(vid) % 3;
    int corner = k == 0 ? 0 : t + k;
    HexOut out;
    float2 p;
    out.across = 0;
    out.colour = styles[int(h.style)].fill * u.opacity;
    // A hex partly behind the camera is skipped whole: one corner moved off on its own
    // would stretch a triangle across the screen.
    for (int i = 0; i < 6; i++) {
        if (homogeneous(h.cell, h.offset, h.corners[i], f).z < near) { out.position = float4(2, 2, 0, 1); return out; }
    }
    hexCorner(h, corner, f, p);
    out.position = toClip(p, f);
    return out;
}

vertex HexOut hexStrokeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              constant HexTile *hexes [[buffer(0)]], constant Frame &f [[buffer(1)]],
                              constant HexStyle *styles [[buffer(2)]], constant HexUniforms &u [[buffer(3)]]) {
    constant HexTile &h = hexes[iid];
    int edge = int(vid) / 6, k = int(vid) % 6;
    // Two triangles: a and b along the edge, either side of it.
    const int atB[6] = {0, 1, 0, 0, 1, 1};
    const float side[6] = {-1, -1, 1, 1, -1, 1};
    HexOut out;
    out.colour = styles[int(h.style)].stroke * u.opacity;
    float2 a, b;
    if (!hexCorner(h, edge, f, a) || !hexCorner(h, (edge + 1) % 6, f, b) || distance(a, b) < 1e-4) {
        out.position = float4(2, 2, 0, 1);
        out.across = 0;
        return out;
    }
    float2 dir = normalize(b - a);
    float2 normal = float2(-dir.y, dir.x);
    // Room for a pixel of soft edge either side.
    float reach = u.halfWidth + 1 / u.pixelsPerPoint;
    float2 p = (atB[k] ? b : a) + normal * side[k] * reach;
    out.position = toClip(p, f);
    out.across = side[k] * reach;
    return out;
}

fragment float4 hexFillFragment(HexOut in [[stage_in]]) {
    return in.colour;
}

fragment float4 hexStrokeFragment(HexOut in [[stage_in]], constant HexUniforms &u [[buffer(0)]]) {
    float d = abs(in.across);
    float coverage = clamp((u.halfWidth - d) * u.pixelsPerPoint + 0.5, 0.0, 1.0);
    return in.colour * coverage;
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

vertex WholeOut clipVertex(uint vid [[vertex_id]], constant float2 *points [[buffer(0)]], constant float2 &size [[buffer(1)]]) {
    float2 p = points[vid];
    WholeOut out;
    out.position = float4(p.x / size.x * 2 - 1, 1 - p.y / size.y * 2, 0, 1);
    out.uv = float2(0);
    return out;
}

fragment float4 clipFragment() {
    return float4(0);
}

fragment float4 wholeFragment(WholeOut in [[stage_in]], texture2d<float> picture [[texture(0)]], constant float &alpha [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return picture.sample(s, in.uv) * alpha;
}
"""#
