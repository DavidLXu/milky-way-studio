import Foundation
import Metal
import simd

enum GalaxyError: LocalizedError {
    case noDevice
    case noShader
    case shaderCompile(String)
    case pipeline(String)
    case texture(String)
    case export(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: return "这台 Mac 没有可用的 Metal 设备。"
        case .noShader: return "找不到 Shaders.metal。"
        case .shaderCompile(let message): return "Metal 着色器编译失败：\(message)"
        case .pipeline(let message): return "渲染管线创建失败：\(message)"
        case .texture(let message): return "纹理创建失败：\(message)"
        case .export(let message): return "图像导出失败：\(message)"
        }
    }
}

final class GalaxyEngine {
    static let galaxyWidth = 640
    static let galaxyHeight = 320
    static let galaxyDepth = 640
    static let detailSize = 128
    static let dustHighWidth = 1024
    static let dustHighHeight = 256
    static let dustHighDepth = 1024
    static let bloomLevels = 5

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var library: MTLLibrary!
    var galaxyTexture: MTLTexture!
    var detailTexture: MTLTexture!
    var dustHighTexture: MTLTexture!
    var starBuffer: MTLBuffer!
    var starCount: Int = 0
    var starInitialParticles: [StarParticle] = []

    var scenePipeline: MTLRenderPipelineState!
    var blackHolePipeline: MTLRenderPipelineState!
    var solarPipeline: MTLRenderPipelineState!
    var starPipeline: MTLRenderPipelineState!
    var bloomPipeline: MTLRenderPipelineState!
    var compositePipeline8: MTLRenderPipelineState!
    var compositePipeline16: MTLRenderPipelineState!
    var buildGalaxyPipeline: MTLComputePipelineState!
    var buildDetailPipeline: MTLComputePipelineState!
    var buildDustHighPipeline: MTLComputePipelineState!
    var starSimPipeline: MTLComputePipelineState!

    var accumFormat: MTLPixelFormat = .rgba32Float
    var buildSeconds: Double = 0
    var compileSeconds: Double = 0

    private var bloomA: [MTLTexture] = []
    private var bloomB: [MTLTexture] = []
    private var bloomSize: (Int, Int) = (0, 0)

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw GalaxyError.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw GalaxyError.noDevice
        }
        self.device = device
        self.commandQueue = queue

        let source = try Self.loadShaderSource()
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        options.fastMathEnabled = true

        let compileStart = CFAbsoluteTimeGetCurrent()
        do {
            self.library = try device.makeLibrary(source: source, options: options)
        } catch {
            throw GalaxyError.shaderCompile(error.localizedDescription)
        }
        self.compileSeconds = CFAbsoluteTimeGetCurrent() - compileStart

        func function(_ name: String) throws -> MTLFunction {
            guard let fn = library.makeFunction(name: name) else {
                throw GalaxyError.pipeline("缺少函数 \(name)")
            }
            return fn
        }

        func makeRenderPipeline(_ vertex: String,
                                _ fragment: String,
                                _ format: MTLPixelFormat,
                                blending: Bool) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = try function(vertex)
            desc.fragmentFunction = try function(fragment)
            desc.colorAttachments[0].pixelFormat = format
            if blending {
                let a = desc.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .one
            }
            do {
                return try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                throw GalaxyError.pipeline(error.localizedDescription)
            }
        }

        // Additive accumulation into RGBA32F is ideal; fall back to RGBA16F
        // on devices that do not expose 32-bit float blending.
        var chosenFormat = MTLPixelFormat.rgba32Float
        var scene: MTLRenderPipelineState
        do {
            scene = try makeRenderPipeline("fullscreen_vertex", "galaxy_fragment", chosenFormat, blending: true)
        } catch {
            chosenFormat = .rgba16Float
            scene = try makeRenderPipeline("fullscreen_vertex", "galaxy_fragment", chosenFormat, blending: true)
        }
        self.accumFormat = chosenFormat
        self.scenePipeline = scene
        self.blackHolePipeline = try makeRenderPipeline("fullscreen_vertex", "blackhole_fragment", chosenFormat, blending: true)
        self.solarPipeline = try makeRenderPipeline("fullscreen_vertex", "solar_fragment", chosenFormat, blending: true)
        self.starPipeline = try makeRenderPipeline("star_vertex", "star_fragment", chosenFormat, blending: true)
        self.bloomPipeline = try makeRenderPipeline("fullscreen_vertex", "bloom_fragment", .rgba16Float, blending: false)
        self.compositePipeline8 = try makeRenderPipeline("fullscreen_vertex", "composite_fragment", .bgra8Unorm, blending: false)
        self.compositePipeline16 = try makeRenderPipeline("fullscreen_vertex", "composite_fragment", .rgba16Unorm, blending: false)

        guard let buildGalaxyFn = library.makeFunction(name: "build_galaxy"),
              let buildDetailFn = library.makeFunction(name: "build_detail"),
              let buildDustHighFn = library.makeFunction(name: "build_dust_high"),
              let starSimFn = library.makeFunction(name: "integrate_stars") else {
            throw GalaxyError.pipeline("缺少体数据生成函数")
        }
        do {
            self.buildGalaxyPipeline = try device.makeComputePipelineState(function: buildGalaxyFn)
            self.buildDetailPipeline = try device.makeComputePipelineState(function: buildDetailFn)
            self.buildDustHighPipeline = try device.makeComputePipelineState(function: buildDustHighFn)
            self.starSimPipeline = try device.makeComputePipelineState(function: starSimFn)
        } catch {
            throw GalaxyError.pipeline(error.localizedDescription)
        }

        let galaxyDesc = MTLTextureDescriptor()
        galaxyDesc.textureType = .type3D
        galaxyDesc.pixelFormat = .rgba16Float
        galaxyDesc.width = Self.galaxyWidth
        galaxyDesc.height = Self.galaxyHeight
        galaxyDesc.depth = Self.galaxyDepth
        galaxyDesc.usage = [.shaderRead, .shaderWrite]
        galaxyDesc.storageMode = .private
        guard let galaxy = device.makeTexture(descriptor: galaxyDesc) else {
            throw GalaxyError.texture("无法创建银河体纹理")
        }
        self.galaxyTexture = galaxy

        let detailDesc = MTLTextureDescriptor()
        detailDesc.textureType = .type3D
        detailDesc.pixelFormat = .rgba8Unorm
        detailDesc.width = Self.detailSize
        detailDesc.height = Self.detailSize
        detailDesc.depth = Self.detailSize
        detailDesc.usage = [.shaderRead, .shaderWrite]
        detailDesc.storageMode = .private
        guard let detail = device.makeTexture(descriptor: detailDesc) else {
            throw GalaxyError.texture("无法创建细节噪声纹理")
        }
        self.detailTexture = detail

        let highDesc = MTLTextureDescriptor()
        highDesc.textureType = .type3D
        highDesc.pixelFormat = .r16Float
        highDesc.width = Self.dustHighWidth
        highDesc.height = Self.dustHighHeight
        highDesc.depth = Self.dustHighDepth
        highDesc.usage = [.shaderRead, .shaderWrite]
        highDesc.storageMode = .private
        guard let highDust = device.makeTexture(descriptor: highDesc) else {
            throw GalaxyError.texture("无法创建高清尘埃纹理")
        }
        self.dustHighTexture = highDust

        let buildStart = CFAbsoluteTimeGetCurrent()
        try Self.buildVolumes(device: device,
                              queue: queue,
                              galaxy: galaxy,
                              detail: detail,
                              highDust: highDust,
                              galaxyPipeline: buildGalaxyPipeline,
                              detailPipeline: buildDetailPipeline,
                              dustHighPipeline: buildDustHighPipeline)
        self.buildSeconds = CFAbsoluteTimeGetCurrent() - buildStart

        let stars = try Self.buildStarBuffer(device: device, count: 120_000)
        self.starBuffer = stars.0
        self.starCount = stars.1
        self.starInitialParticles = stars.2
    }

    private static func buildStarBuffer(device: MTLDevice, count: Int) throws -> (MTLBuffer, Int, [StarParticle]) {
        struct LCG {
            var state: UInt64
            mutating func next() -> UInt64 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return state
            }
            mutating func unit() -> Double {
                Double(next() >> 11) / Double(1 << 53)
            }
            mutating func gaussian() -> Double {
                let u1 = max(unit(), 1e-9)
                let u2 = unit()
                return sqrt(-2.0 * log(u1)) * cos(2.0 * Double.pi * u2)
            }
        }

        var rng = LCG(state: 0x9E3779B97F4A7C15)
        var particles = [StarParticle]()
        particles.reserveCapacity(count)

        let twoPi = 2.0 * Double.pi
        let pitchA = tan(24.0 * Double.pi / 180.0)
        let pitchB = tan(31.0 * Double.pi / 180.0)
        let oldColor = SIMD3<Float>(1.00, 0.60, 0.32)
        let youngColor = SIMD3<Float>(0.46, 0.66, 1.00)
        let hiiColor = SIMD3<Float>(1.00, 0.35, 0.50)

        func wrapPi(_ x: Double) -> Double {
            x - twoPi * floor((x + Double.pi) / twoPi)
        }

        while particles.count < count {
            let r = min(17.8, -3.15 * log(max(1e-6, 1.0 - rng.unit())))
            if r < 0.35 { continue }
            let phi = rng.unit() * twoPi

            let baseA = phi + log(max(r, 1.8) / 3.2) / pitchA
            let baseB = phi + log(max(r, 1.8) / 3.2) / pitchB
            let dA = wrapPi(2.0 * baseA + 4.24)
            let dB = wrapPi(2.0 * baseB + 4.24 + Double.pi)
            let armA = exp(-0.5 * pow(dA / 0.24, 2.0))
            let armB = exp(-0.5 * pow(dB / 0.20, 2.0))
            let arm = max(armA, 0.72 * armB)
            let accept = 0.24 + 0.76 * arm
            if rng.unit() > accept { continue }

            let warp = 0.24 * pow(r / 16.0, 1.7) * sin(phi + 0.65)
            let thin = rng.unit() < 0.86
            let h = (thin ? 0.11 : 0.52) * rng.gaussian() + warp
            let youngFactor = min(1.0, arm * 0.85 + rng.unit() * 0.35)
            let baseColor = youngColor * Float(youngFactor) +
                            oldColor * Float(1.0 - youngFactor)
            let hiiChance = arm * 0.10 * rng.unit()
            let color = hiiChance > 0.055
                ? hiiColor
                : baseColor

            let luminosity = rng.unit()
            let brightness = 0.005 + 0.24 * pow(luminosity, 9.0)
            let size = 0.60 + 1.35 * pow(rng.unit(), 5.0)

            let vCircular = AstroModel.circularSpeed(r) * AstroModel.kmPerSecToKpcPerMyr
            let tangential = SIMD3<Double>(-sin(phi), 0.0, cos(phi))
            let dispersion = 3.0 * 0.0010227
            let vel = SIMD4<Float>(
                Float(tangential.x * vCircular + rng.gaussian() * dispersion),
                Float(rng.gaussian() * dispersion * 0.6),
                Float(tangential.z * vCircular + rng.gaussian() * dispersion),
                0
            )
            let p = SIMD4<Float>(Float(r * cos(phi)), Float(h), Float(r * sin(phi)), Float(size))
            let c = SIMD4<Float>(color.x, color.y, color.z, Float(brightness))
            particles.append(StarParticle(posSize: p, colorBrightness: c, velocity: vel))
        }

        let length = MemoryLayout<StarParticle>.stride * particles.count
        guard let buffer = device.makeBuffer(bytes: particles,
                                             length: length,
                                             options: .storageModeShared) else {
            throw GalaxyError.texture("无法创建星粒子缓冲区")
        }
        return (buffer, particles.count, particles)
    }

    func resetStars() {
        guard !starInitialParticles.isEmpty else { return }
        let length = MemoryLayout<StarParticle>.stride * starInitialParticles.count
        if let buffer = device.makeBuffer(bytes: starInitialParticles,
                                          length: length,
                                          options: .storageModeShared) {
            starBuffer = buffer
        }
    }

    func encodeStarSimulation(commandBuffer: MTLCommandBuffer,
                              dt: Float,
                              time: Float) {
        guard starCount > 0, starBuffer != nil, dt > 0 else { return }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Restricted N-body stars"
        encoder.setComputePipelineState(starSimPipeline)
        encoder.setBuffer(starBuffer, offset: 0, index: 0)
        var uniforms = BuildUniforms(params: SIMD4<Float>(dt, time, 0, 0))
        encoder.setBytes(&uniforms, length: MemoryLayout<BuildUniforms>.stride, index: 1)
        encoder.dispatchThreads(MTLSize(width: starCount, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        encoder.endEncoding()
    }

    private static func loadShaderSource() throws -> String {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "Shaders", withExtension: "metal") {
            candidates.append(bundled)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Sources/Shaders.metal"))
        candidates.append(cwd.appendingPathComponent("../Sources/Shaders.metal"))
        candidates.append(URL(fileURLWithPath: "/Users/xulixin/Downloads/MilkyWayStudio/Sources/Shaders.metal"))

        for url in candidates {
            if let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty {
                return source
            }
        }
        throw GalaxyError.noShader
    }

    private static func buildVolumes(device: MTLDevice,
                                     queue: MTLCommandQueue,
                                     galaxy: MTLTexture,
                                     detail: MTLTexture,
                                     highDust: MTLTexture,
                                     galaxyPipeline: MTLComputePipelineState,
                                     detailPipeline: MTLComputePipelineState,
                                     dustHighPipeline: MTLComputePipelineState) throws {
        guard let cb = queue.makeCommandBuffer() else {
            throw GalaxyError.pipeline("无法创建命令缓冲区")
        }

        if let enc = cb.makeComputeCommandEncoder() {
            enc.label = "Build detail volume"
            enc.setComputePipelineState(detailPipeline)
            enc.setTexture(detail, index: 0)
            enc.dispatchThreads(
                MTLSize(width: detailSize, height: detailSize, depth: detailSize),
                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4)
            )
            enc.endEncoding()
        }

        if let enc = cb.makeComputeCommandEncoder() {
            enc.label = "Build high-resolution dust"
            enc.setComputePipelineState(dustHighPipeline)
            enc.setTexture(highDust, index: 0)
            enc.dispatchThreads(
                MTLSize(width: dustHighWidth, height: dustHighHeight, depth: dustHighDepth),
                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4)
            )
            enc.endEncoding()
        }

        if let enc = cb.makeComputeCommandEncoder() {
            enc.label = "Build galaxy volume"
            enc.setComputePipelineState(galaxyPipeline)
            enc.setTexture(galaxy, index: 0)
            var uniforms = BuildUniforms(params: SIMD4<Float>(0, 1, 1, 0))
            enc.setBytes(&uniforms, length: MemoryLayout<BuildUniforms>.stride, index: 0)
            enc.dispatchThreads(
                MTLSize(width: galaxyWidth, height: galaxyHeight, depth: galaxyDepth),
                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4)
            )
            enc.endEncoding()
        }

        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error {
            throw GalaxyError.pipeline("体数据生成失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Textures

    func makeAccumulationTexture(width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: accumFormat,
            width: max(1, width),
            height: max(1, height),
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw GalaxyError.texture("无法创建累积缓冲区 \(width)x\(height)")
        }
        return texture
    }

    private func ensureBloom(width: Int, height: Int) {
        let bw = max(1, width / 2)
        let bh = max(1, height / 2)
        if bloomSize == (bw, bh), bloomA.count == Self.bloomLevels {
            return
        }
        bloomSize = (bw, bh)
        bloomA.removeAll(keepingCapacity: true)
        bloomB.removeAll(keepingCapacity: true)

        var w = bw
        var h = bh
        for _ in 0..<Self.bloomLevels {
            for _ in 0..<2 {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba16Float,
                    width: max(1, w),
                    height: max(1, h),
                    mipmapped: false
                )
                desc.usage = [.shaderRead, .renderTarget]
                desc.storageMode = .private
                if let a = device.makeTexture(descriptor: desc) {
                    bloomA.append(a)
                }
            }
            // The loop above appends twice; move one to B.
            if bloomB.count < bloomA.count {
                bloomB.append(bloomA.removeLast())
            }
            w = max(1, w / 2)
            h = max(1, h / 2)
        }
    }

    func ensureBloomReady(width: Int, height: Int) {
        ensureBloom(width: width, height: height)
    }

    // MARK: - Encoding

    private func makeSceneUniforms(settings: RenderSettings,
                                   width: Int,
                                   height: Int,
                                   sampleIndex: UInt32,
                                   aspect: Double) -> SceneUniforms {
        let camera = CameraBasis.make(settings: settings, aspect: aspect)
        var u = SceneUniforms()
        u.resolution = SIMD4<Float>(Float(width), Float(height), 1.0 / Float(max(width, 1)), 1.0 / Float(max(height, 1)))
        let patternAngle = Float(settings.time * 0.0240)
        u.cameraPos = SIMD4<Float>(camera.position.x, camera.position.y, camera.position.z, patternAngle)
        u.cameraRight = SIMD4<Float>(camera.right.x, camera.right.y, camera.right.z, camera.tanHalfFov)
        u.cameraUp = SIMD4<Float>(camera.up.x, camera.up.y, camera.up.z, Float(aspect))
        u.cameraForward = SIMD4<Float>(camera.forward.x, camera.forward.y, camera.forward.z, Float(settings.time))
        u.params0 = SIMD4<Float>(Float(settings.dust), settings.steps >= 256 ? 1 : 0, settings.shearEnabled ? 1 : 0, settings.dustHighEnabled ? 1 : 0)
        u.params1 = SIMD4<Float>(Float(settings.exposure), settings.starDynamicsEnabled ? 1 : 0, 0, 0)
        u.params2 = SIMD4<Float>(Float(settings.steps), Float(sampleIndex), Float(settings.seed), 0)
        if settings.mode == .solarSystem {
            u.params3 = SIMD4<Float>(Float(settings.solarPlanetScale),
                                     (settings.solarOrbitLines && settings.solarFocus < 0) ? 1 : 0,
                                     settings.solarBelts ? 1 : 0,
                                     settings.solarMoons ? 1 : 0)
            let auPerPixel = Float(2.0 * settings.distance *
                                   tan(settings.fov * .pi / 360.0) /
                                   Double(max(height, 1)))
            u.params4 = SIMD4<Float>(Float(max(0.0012, settings.distance * 0.00045)),
                                     1.0, auPerPixel, 0)
        } else {
            u.params3 = SIMD4<Float>(Float(settings.bhTemp),
                                     Float(settings.bhBrightness),
                                     Float(settings.bhDiskOuter),
                                     settings.bhDoppler ? 1 : 0)
            u.params4 = SIMD4<Float>(settings.bhJets ? 1 : 0,
                                     Float(settings.bhThickness), 0, 0)
        }
        return u
    }

    private func makeCompositeUniforms(settings: RenderSettings,
                                       width: Int,
                                       height: Int,
                                       sampleCount: Int) -> CompositeUniforms {
        var u = CompositeUniforms()
        u.resolution = SIMD4<Float>(Float(width), Float(height), 1.0 / Float(max(width, 1)), 1.0 / Float(max(height, 1)))
        u.params0 = SIMD4<Float>(Float(settings.exposure), Float(settings.bloom), Float(settings.vignette), Float(settings.grain))
        u.params1 = SIMD4<Float>(Float(sampleCount), Float(settings.time), Float(settings.chromatic), 0)
        u.params2 = SIMD4<Float>(settings.mode == .blackHole ? Float(settings.bhSoftness) : 0, 0, 0, 0)
        return u
    }

    func encodeScene(commandBuffer: MTLCommandBuffer,
                     target: MTLTexture,
                     settings: RenderSettings,
                     samples: [UInt32],
                     clear: Bool,
                     stars: Bool = true) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = clear ? .clear : .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let isBlackHole = settings.mode == .blackHole
        let isSolar = settings.mode == .solarSystem
        encoder.label = isBlackHole ? "Black hole geodesic trace" :
                        (isSolar ? "Solar system ray trace" : "Galaxy ray march")
        encoder.setRenderPipelineState(isBlackHole ? blackHolePipeline :
                                       (isSolar ? solarPipeline : scenePipeline))
        if !isBlackHole && !isSolar {
            encoder.setFragmentTexture(galaxyTexture, index: 0)
            encoder.setFragmentTexture(detailTexture, index: 1)
            encoder.setFragmentTexture(dustHighTexture, index: 2)
        }
        if isSolar {
            let planets = SolarSystem.renderPlanets(days: settings.time,
                                                    scale: settings.solarPlanetScale)
            planets.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    encoder.setFragmentBytes(base, length: raw.count, index: 1)
                }
            }
        }
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(target.width), height: Double(target.height),
                                        znear: 0, zfar: 1))

        let aspect = Double(target.width) / Double(max(target.height, 1))
        for sampleIndex in samples {
            var uniforms = makeSceneUniforms(settings: settings,
                                             width: target.width,
                                             height: target.height,
                                             sampleIndex: sampleIndex,
                                             aspect: aspect)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        if !isBlackHole && !isSolar && stars && starCount > 0 && starBuffer != nil {
            encoder.setRenderPipelineState(starPipeline)
            encoder.setVertexBuffer(starBuffer, offset: 0, index: 0)
            encoder.setVertexTexture(galaxyTexture, index: 0)
            encoder.setVertexTexture(dustHighTexture, index: 1)
            for sampleIndex in samples {
                var uniforms = makeSceneUniforms(settings: settings,
                                                 width: target.width,
                                                 height: target.height,
                                                 sampleIndex: sampleIndex,
                                                 aspect: aspect)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle,
                                       vertexStart: 0,
                                       vertexCount: 6,
                                       instanceCount: starCount)
            }
        }
        encoder.endEncoding()
    }

    func encodeBloom(commandBuffer: MTLCommandBuffer,
                     scene: MTLTexture,
                     sampleCount: Int,
                     settings: RenderSettings) {
        ensureBloom(width: scene.width, height: scene.height)
        guard bloomA.count >= Self.bloomLevels, bloomB.count >= Self.bloomLevels else { return }

        // Prefilter the HDR accumulation at half resolution.
        var pre = BloomUniforms()
        pre.texel = SIMD4<Float>(1.0 / Float(scene.width), 1.0 / Float(scene.height), 0, 0)
        pre.params = SIMD4<Float>(0, 0.72, 0.30, 1.0 / Float(max(sampleCount, 1)))
        encodeBloomPass(commandBuffer: commandBuffer,
                        target: bloomA[0],
                        source: scene,
                        uniforms: &pre)

        // Downsample chain.
        for level in 1..<Self.bloomLevels {
            var u = BloomUniforms()
            u.texel = SIMD4<Float>(1.0 / Float(bloomA[level - 1].width),
                                   1.0 / Float(bloomA[level - 1].height), 0, 0)
            u.params = SIMD4<Float>(1, 0.72, 0.30, 1)
            encodeBloomPass(commandBuffer: commandBuffer,
                            target: bloomA[level],
                            source: bloomA[level - 1],
                            uniforms: &u)
        }

        // Blur every level; widest possible kernel without extra passes.
        for level in 0..<Self.bloomLevels {
            let w = bloomA[level].width
            let h = bloomA[level].height
            var horizontal = BloomUniforms()
            horizontal.texel = SIMD4<Float>(1.0 / Float(w), 1.0 / Float(h), 1, 0)
            horizontal.params = SIMD4<Float>(2, 0.72, 0.30, 1)
            encodeBloomPass(commandBuffer: commandBuffer,
                            target: bloomB[level],
                            source: bloomA[level],
                            uniforms: &horizontal)

            var vertical = BloomUniforms()
            vertical.texel = SIMD4<Float>(1.0 / Float(w), 1.0 / Float(h), 0, 1)
            vertical.params = SIMD4<Float>(2, 0.72, 0.30, 1)
            encodeBloomPass(commandBuffer: commandBuffer,
                            target: bloomA[level],
                            source: bloomB[level],
                            uniforms: &vertical)
        }
    }

    private func encodeBloomPass(commandBuffer: MTLCommandBuffer,
                                 target: MTLTexture,
                                 source: MTLTexture,
                                 uniforms: inout BloomUniforms) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Bloom"
        encoder.setRenderPipelineState(bloomPipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BloomUniforms>.stride, index: 0)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(target.width), height: Double(target.height),
                                        znear: 0, zfar: 1))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func encodeComposite(commandBuffer: MTLCommandBuffer,
                         renderPass: MTLRenderPassDescriptor,
                         width: Int,
                         height: Int,
                         sampleCount: Int,
                         settings: RenderSettings,
                         scene: MTLTexture,
                         viewport: MTLViewport? = nil) {
        guard let target = renderPass.colorAttachments[0].texture else { return }
        guard bloomA.count >= Self.bloomLevels else { return }
        let pipeline: MTLRenderPipelineState
        if target.pixelFormat == .rgba16Unorm {
            pipeline = compositePipeline16
        } else {
            pipeline = compositePipeline8
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }
        encoder.label = "Composite"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(scene, index: 0)
        for level in 0..<Self.bloomLevels {
            encoder.setFragmentTexture(bloomA[level], index: level + 1)
        }
        var uniforms = makeCompositeUniforms(settings: settings, width: width, height: height, sampleCount: sampleCount)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
        if let viewport {
            encoder.setViewport(viewport)
        } else {
            encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                            width: Double(width), height: Double(height),
                                            znear: 0, zfar: 1))
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: - Offscreen / CLI

    struct OffscreenResult {
        var url: URL
        var seconds: Double
        var buildSeconds: Double
        var compileSeconds: Double
    }

    func renderOffscreen(width: Int,
                         height: Int,
                         samples: Int,
                         settings: RenderSettings,
                         outputURL: URL,
                         progress: ((Double) -> Void)? = nil) throws -> OffscreenResult {
        let start = CFAbsoluteTimeGetCurrent()
        let scene = try makeAccumulationTexture(width: width, height: height)
        let total = max(1, samples)
        var done = 0

        while done < total {
            let count = min(4, total - done)
            let indices = (0..<count).map { UInt32(done + $0) }
            guard let cb = commandQueue.makeCommandBuffer() else {
                throw GalaxyError.pipeline("无法创建命令缓冲区")
            }
            encodeScene(commandBuffer: cb, target: scene, settings: settings, samples: indices, clear: done == 0, stars: settings.starLayerEnabled)
            cb.commit()
            cb.waitUntilCompleted()
            if let error = cb.error {
                throw GalaxyError.pipeline(error.localizedDescription)
            }
            done += count
            progress?(Double(done) / Double(total))
        }

        ensureBloom(width: width, height: height)

        let exportDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        exportDesc.usage = [.renderTarget, .shaderRead]
        exportDesc.storageMode = .private
        guard let exportTexture = device.makeTexture(descriptor: exportDesc) else {
            throw GalaxyError.texture("无法创建导出纹理")
        }

        let stagingDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        stagingDesc.usage = [.shaderRead]
        stagingDesc.storageMode = .shared
        guard let staging = device.makeTexture(descriptor: stagingDesc) else {
            throw GalaxyError.texture("无法创建导出暂存纹理")
        }

        guard let cb = commandQueue.makeCommandBuffer() else {
            throw GalaxyError.pipeline("无法创建导出命令缓冲区")
        }
        encodeBloom(commandBuffer: cb, scene: scene, sampleCount: total, settings: settings)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = exportTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        encodeComposite(commandBuffer: cb,
                        renderPass: pass,
                        width: width,
                        height: height,
                        sampleCount: total,
                        settings: settings,
                        scene: scene)

        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: exportTexture,
                      sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: staging,
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error {
            throw GalaxyError.pipeline(error.localizedDescription)
        }

        try ImageExporter.saveRGBA16(texture: staging, to: outputURL)
        progress?(1.0)
        return OffscreenResult(url: outputURL,
                               seconds: CFAbsoluteTimeGetCurrent() - start,
                               buildSeconds: buildSeconds,
                               compileSeconds: compileSeconds)
    }
}
