import Foundation
import Metal
import MetalKit
import QuartzCore
import AppKit

final class GalaxyRenderer: NSObject, MTKViewDelegate {
    struct FinalJob {
        let id: UUID
        let url: URL
        let longEdge: Int
        let samples: Int
        let width: Int
        let height: Int
        let started: CFTimeInterval
    }

    private let engine: GalaxyEngine
    private weak var view: MTKView?

    private let lock = NSLock()
    private var settings: RenderSettings
    private var patternTime: Double = 0
    private var finalJob: FinalJob?
    private var isExporting = false

    private var accum: MTLTexture?
    private var accumWidth = 0
    private var accumHeight = 0
    private var accumCount = 0
    private var lastSceneKey: SceneKey?
    private var bloomValid = false

    private var lastTime: CFTimeInterval = 0
    private var lastResetCounter: Int = -1
    private var lastSimResetCounter: Int = -1
    private var lastStatusTime: CFTimeInterval = 0
    private var fpsSmoothed: Double = 0
    private var framesSinceStatus = 0

    var onStatus: ((Double, Int, Int, Int) -> Void)?
    var onTime: ((Double) -> Void)?
    var onProgress: ((Int, Int, Double) -> Void)?
    var onSaving: ((Int, Int) -> Void)?
    var onComplete: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    init(view: MTKView) throws {
        self.view = view
        self.settings = RenderSettings()
        self.engine = try GalaxyEngine()
        super.init()
        self.lastTime = CACurrentMediaTime()
        view.delegate = self
    }

    var isRenderingFinal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finalJob != nil
    }

    func update(settings newSettings: RenderSettings) {
        lock.lock()
        if newSettings.resetCounter != lastResetCounter {
            lastResetCounter = newSettings.resetCounter
            patternTime = 0
            accumCount = 0
            lastSceneKey = nil
            bloomValid = false
        }
        if newSettings.simResetCounter != lastSimResetCounter {
            lastSimResetCounter = newSettings.simResetCounter
            engine.resetStars()
            accumCount = 0
            lastSceneKey = nil
            bloomValid = false
        }
        var s = newSettings
        s.time = patternTime
        if finalJob != nil {
            s.autoRotate = false
            s.steps = 384
        }
        settings = s
        lock.unlock()
    }

    func startFinal(_ request: FinalRequest, viewportAspect: Double) {
        lock.lock()
        if finalJob?.id == request.id {
            lock.unlock()
            return
        }
        let aspect = max(0.5, min(2.4, viewportAspect))
        let width: Int
        let height: Int
        if aspect >= 1.0 {
            width = request.longEdge
            height = max(2, Int((Double(request.longEdge) / aspect).rounded()))
        } else {
            height = request.longEdge
            width = max(2, Int((Double(request.longEdge) * aspect).rounded()))
        }
        finalJob = FinalJob(id: request.id,
                            url: request.url,
                            longEdge: request.longEdge,
                            samples: request.samples,
                            width: width,
                            height: height,
                            started: CACurrentMediaTime())
        settings.autoRotate = false
        settings.steps = 384
        accumCount = 0
        lastSceneKey = nil
        bloomValid = false
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(0, request.samples, 0)
        }
    }

    func cancelFinal() {
        lock.lock()
        if !isExporting {
            finalJob = nil
            accumCount = 0
            lastSceneKey = nil
            bloomValid = false
        }
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lock.lock()
        accumCount = 0
        lastSceneKey = nil
        bloomValid = false
        lock.unlock()
    }

    func draw(in view: MTKView) {
        lock.lock()
        defer { lock.unlock() }

        guard let device = view.device,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor else {
            return
        }
        _ = device

        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTime, 0.0), 0.15)
        lastTime = now

        if settings.autoRotate && finalJob == nil {
            patternTime += dt * settings.rotationSpeed
        }

        var s = settings
        s.time = patternTime
        if finalJob != nil {
            s.autoRotate = false
            s.steps = 384
        }

        let targetWidth: Int
        let targetHeight: Int
        if let job = finalJob {
            targetWidth = job.width
            targetHeight = job.height
        } else {
            let backing = view.window?.backingScaleFactor ?? 2.0
            let boundsW = max(1.0, Double(view.bounds.width) * backing)
            let boundsH = max(1.0, Double(view.bounds.height) * backing)
            let aspect = max(0.55, min(2.2, boundsW / boundsH))
            var w = max(320, Int(boundsW * s.previewScale))
            var h = max(200, Int(Double(w) / aspect))
            let cap = 2400
            let longEdge = max(w, h)
            if longEdge > cap {
                let f = Double(cap) / Double(longEdge)
                w = max(320, Int(Double(w) * f))
                h = max(200, Int(Double(h) * f))
            }
            targetWidth = w
            targetHeight = h
        }

        let key = SceneKey(settings: s, width: targetWidth, height: targetHeight)
        if key != lastSceneKey || accum == nil || accumWidth != targetWidth || accumHeight != targetHeight {
            do {
                accum = try engine.makeAccumulationTexture(width: targetWidth, height: targetHeight)
                accumWidth = targetWidth
                accumHeight = targetHeight
                accumCount = 0
                bloomValid = false
                lastSceneKey = key
            } catch {
                DispatchQueue.main.async { [weak self] in self?.onError?(error.localizedDescription) }
                return
            }
        }

        guard let accum else { return }

        let targetSamples: Int
        if let job = finalJob {
            targetSamples = job.samples
        } else {
            targetSamples = s.previewSamples
        }

        let shouldAddSample = accumCount < targetSamples
        let clear = accumCount == 0

        guard let cb = engine.commandQueue.makeCommandBuffer() else { return }
        cb.label = finalJob == nil ? "Preview frame" : "Final frame"

        if s.starDynamicsEnabled && finalJob == nil && s.autoRotate {
            let simDt = min(dt * s.rotationSpeed, 0.12)
            if simDt > 0 {
                engine.encodeStarSimulation(commandBuffer: cb,
                                            dt: Float(simDt),
                                            time: Float(s.time))
            }
        }

        if shouldAddSample {
            let spp = finalJob == nil ? max(1, min(4, s.previewSPP)) : 1
            let remaining = max(0, targetSamples - accumCount)
            let count = min(spp, remaining)
            let indices = (0..<count).map { UInt32(accumCount + $0) }
            engine.encodeScene(commandBuffer: cb,
                               target: accum,
                               settings: s,
                               samples: indices,
                               clear: clear,
                               stars: s.starLayerEnabled)
            accumCount += count
            bloomValid = false
        }

        if !bloomValid {
            engine.encodeBloom(commandBuffer: cb,
                               scene: accum,
                               sampleCount: accumCount,
                               settings: s)
            bloomValid = true
        }

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let dw = Double(drawable.texture.width)
        let dh = Double(drawable.texture.height)
        let sceneAspect = Double(targetWidth) / Double(max(targetHeight, 1))
        var vw = dw
        var vh = dh
        if sceneAspect > dw / dh {
            vh = dw / sceneAspect
        } else {
            vw = dh * sceneAspect
        }
        let vp = MTLViewport(originX: (dw - vw) * 0.5,
                             originY: (dh - vh) * 0.5,
                             width: vw, height: vh,
                             znear: 0, zfar: 1)
        engine.encodeComposite(commandBuffer: cb,
                               renderPass: pass,
                               width: drawable.texture.width,
                               height: drawable.texture.height,
                               sampleCount: max(accumCount, 1),
                               settings: s,
                               scene: accum,
                               viewport: vp)

        cb.present(drawable)
        cb.commit()

        framesSinceStatus += 1
        if now - lastStatusTime > 0.45 {
            let fps = Double(framesSinceStatus) / max(now - lastStatusTime, 0.001)
            fpsSmoothed = fpsSmoothed == 0 ? fps : fpsSmoothed * 0.65 + fps * 0.35
            framesSinceStatus = 0
            lastStatusTime = now
            let fpsValue = fpsSmoothed
            let samples = accumCount
            let w = targetWidth
            let h = targetHeight
            DispatchQueue.main.async { [weak self] in
                self?.onStatus?(fpsValue, w, h, samples)
                self?.onTime?(self?.patternTime ?? 0)
            }
        }

        if let job = finalJob {
            DispatchQueue.main.async { [weak self] in
                self?.onProgress?(self?.accumCount ?? 0,
                                  job.samples,
                                  CACurrentMediaTime() - job.started)
            }
            if accumCount >= job.samples && !isExporting {
                isExporting = true
                let exportWidth = job.width
                let exportHeight = job.height
                let sampleCount = accumCount
                let url = job.url
                let finalSamples = job.samples
                DispatchQueue.main.async { [weak self] in
                    self?.onSaving?(exportWidth, exportHeight)
                }
                cb.waitUntilCompleted()
                exportAndSave(url: url,
                              width: exportWidth,
                              height: exportHeight,
                              sampleCount: sampleCount,
                              settings: s,
                              finalSamples: finalSamples)
            }
        }
    }

    private func exportAndSave(url: URL,
                               width: Int,
                               height: Int,
                               sampleCount: Int,
                               settings: RenderSettings,
                               finalSamples: Int) {
        guard let scene = accum,
              let exportTexture = makeExportTexture(width: width, height: height),
              let staging = makeStagingTexture(width: width, height: height),
              let cb = engine.commandQueue.makeCommandBuffer() else {
            finalJob = nil
            isExporting = false
            DispatchQueue.main.async { [weak self] in
                self?.onError?("无法创建最终帧导出缓冲区")
            }
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = exportTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        engine.encodeComposite(commandBuffer: cb,
                               renderPass: pass,
                               width: width,
                               height: height,
                               sampleCount: sampleCount,
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
            finalJob = nil
            isExporting = false
            DispatchQueue.main.async { [weak self] in
                self?.onError?(error.localizedDescription)
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try ImageExporter.saveRGBA16(texture: staging, to: url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.lock.lock()
                    self.finalJob = nil
                    self.isExporting = false
                    self.accumCount = 0
                    self.lock.unlock()
                    self.onComplete?(url)
                }
            } catch {
                self?.finishWithError(error.localizedDescription)
            }
        }
    }

    private func finishWithError(_ message: String) {
        lock.lock()
        finalJob = nil
        isExporting = false
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    private func makeExportTexture(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm,
                                                        width: width, height: height,
                                                        mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return engine.device.makeTexture(descriptor: d)
    }

    private func makeStagingTexture(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm,
                                                        width: width, height: height,
                                                        mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        return engine.device.makeTexture(descriptor: d)
    }
}
