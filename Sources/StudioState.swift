import Foundation
import SwiftUI

enum PreviewQuality: String, CaseIterable, Identifiable {
    case performance
    case balanced
    case quality

    var id: String { rawValue }

    var label: String {
        switch self {
        case .performance: return "流畅"
        case .balanced: return "均衡"
        case .quality: return "精细"
        }
    }

    var scale: Double {
        switch self {
        case .performance: return 0.34
        case .balanced: return 0.46
        case .quality: return 0.64
        }
    }
}

enum RenderPhase: Equatable {
    case idle
    case rendering
    case saving
    case done
    case failed

    var isBusy: Bool { self == .rendering || self == .saving }
}

struct FinalRequest: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var longEdge: Int
    var samples: Int
}

enum CameraPreset: String, CaseIterable, Identifiable {
    case portrait
    case faceOn
    case edgeOn
    case closeUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait: return "经典"
        case .faceOn: return "正面"
        case .edgeOn: return "侧视"
        case .closeUp: return "近景"
        }
    }

    var subtitle: String {
        switch self {
        case .portrait: return "35° 倾角"
        case .faceOn: return "俯视盘面"
        case .edgeOn: return "尘埃带"
        case .closeUp: return "核心与旋臂"
        }
    }

    var values: (azimuth: Double, elevation: Double, distance: Double, fov: Double) {
        switch self {
        case .portrait: return (34, 36, 54, 38)
        case .faceOn: return (34, 78, 60, 38)
        case .edgeOn: return (34, 7, 52, 38)
        case .closeUp: return (54, 25, 34, 43)
        }
    }
}

enum BHPreset: String, CaseIterable, Identifiable {
    case gargantua
    case inclined
    case topDown
    case close

    var id: String { rawValue }
    var title: String {
        switch self {
        case .gargantua: return "Gargantua"
        case .inclined: return "斜视"
        case .topDown: return "俯视"
        case .close: return "近景"
        }
    }
    var subtitle: String {
        switch self {
        case .gargantua: return "近侧视 · 经典"
        case .inclined: return "盘面与喷流"
        case .topDown: return "看吸积盘"
        case .close: return "事件视界"
        }
    }
    var values: (azimuth: Double, elevation: Double, distance: Double, fov: Double) {
        switch self {
        case .gargantua: return (34, 6, 27, 32)
        case .inclined: return (34, 26, 26, 34)
        case .topDown: return (34, 76, 34, 32)
        case .close: return (34, 10, 16, 46)
        }
    }
}

final class StudioState: ObservableObject {
    @Published var mode: SceneMode = .galaxy

    // Camera
    @Published var azimuth: Double = 34
    @Published var elevation: Double = 36
    @Published var distance: Double = 54
    @Published var fov: Double = 38
    @Published var autoRotate: Bool = true
    @Published var rotationSpeed: Double = 6.0
    @Published var shearEnabled: Bool = true
    @Published var starLayerEnabled: Bool = true
    @Published var dustHighEnabled: Bool = true
    @Published var starDynamicsEnabled: Bool = false
    @Published var simulationTime: Double = 0
    @Published var timeResetCounter: Int = 0
    @Published var simResetCounter: Int = 0

    // Look
    @Published var dust: Double = 0.85
    @Published var exposure: Double = 0.06
    @Published var bloom: Double = 0.30
    @Published var vignette: Double = 0.28
    @Published var grain: Double = 0.010

    // Black hole look
    @Published var bhTemp: Double = 5500
    @Published var bhBrightness: Double = 0.55
    @Published var bhDiskOuter: Double = 10.0
    @Published var bhExposure: Double = -2.1
    @Published var bhBloom: Double = 0.42
    @Published var bhDoppler: Bool = true
    @Published var bhJets: Bool = false
    @Published var bhSoftness: Double = 3.0

    // Preview
    @Published var previewQuality: PreviewQuality = .balanced
    @Published var previewFPS: Double = 0
    @Published var previewWidth: Int = 0
    @Published var previewHeight: Int = 0
    @Published var previewSamples: Int = 0
    @Published var isReady: Bool = false

    // Final
    @Published var finalLongEdge: Int = 3840
    @Published var finalSamples: Int = 96
    @Published var finalRequest: FinalRequest?
    @Published var phase: RenderPhase = .idle
    @Published var renderProgress: Double = 0
    @Published var renderSamplesDone: Int = 0
    @Published var renderSamplesTarget: Int = 0
    @Published var renderElapsed: Double = 0
    @Published var finalWidth: Int = 0
    @Published var finalHeight: Int = 0
    @Published var savedURL: URL?
    @Published var statusMessage: String = "实时预览"
    @Published var errorMessage: String?

    @Published var showSidebar: Bool = true
    @Published var showIntroOverlay: Bool = true

    var renderSettings: RenderSettings {
        var s = RenderSettings()
        s.mode = mode
        s.azimuth = azimuth
        s.elevation = elevation
        s.distance = distance
        s.fov = fov
        s.time = 0
        s.autoRotate = autoRotate
        s.rotationSpeed = rotationSpeed
        s.dust = dust
        s.shearEnabled = shearEnabled
        s.starDynamicsEnabled = starDynamicsEnabled
        s.simResetCounter = simResetCounter
        s.resetCounter = timeResetCounter
        s.grain = grain
        s.vignette = vignette
        s.targetSamples = finalSamples
        s.bhTemp = bhTemp
        s.bhBrightness = bhBrightness
        s.bhDiskOuter = bhDiskOuter
        s.bhDoppler = bhDoppler
        s.bhJets = bhJets
        s.bhSoftness = bhSoftness

        if mode == .blackHole {
            s.starLayerEnabled = false
            s.dustHighEnabled = false
            s.exposure = bhExposure
            s.bloom = bhBloom
            s.steps = phase == .rendering ? 768 : 320
            s.previewScale = 0.50
            s.previewSamples = 48
            s.previewSPP = 1
        } else {
            s.starLayerEnabled = starLayerEnabled
            s.dustHighEnabled = dustHighEnabled && !autoRotate
            s.exposure = exposure
            s.bloom = bloom
            s.steps = phase == .rendering ? 384 : 64
            s.previewScale = previewQuality.scale
            s.previewSamples = 64
            s.previewSPP = 2
        }
        return s
    }

    init() {
        if mode == .blackHole {
            azimuth = 34
            elevation = 6
            distance = 27
            fov = 32
            autoRotate = false
        }
    }

    var isBusy: Bool { phase.isBusy }

    var cameraSummary: String {
        if mode == .blackHole {
            return String(format: "%02.0f° / %02.0f°  ·  %.0f Rs  ·  %.0f° FOV",
                          azimuth, elevation, distance, fov)
        }
        return String(format: "%02.0f° / %02.0f°  ·  %.0f kpc  ·  %.0f° FOV",
                      azimuth, elevation, distance, fov)
    }

    var resolutionSummary: String {
        if finalWidth > 0 && finalHeight > 0 {
            return "\(finalWidth) × \(finalHeight)"
        }
        let aspect = previewHeight > 0 ? Double(previewWidth) / Double(previewHeight) : 1.6
        let h = Int(Double(finalLongEdge) / max(aspect, 0.2))
        return "\(finalLongEdge) × \(h)"
    }

    func switchMode(_ newMode: SceneMode) {
        guard mode != newMode else { return }
        mode = newMode
        if newMode == .blackHole {
            azimuth = 34
            elevation = 6
            distance = 27
            fov = 32
            autoRotate = false
        } else {
            azimuth = 34
            elevation = 36
            distance = 54
            fov = 38
            autoRotate = true
        }
        resetEvolution()
        showIntroOverlay = false
    }

    func applyBlackHolePreset(_ preset: BHPreset) {
        let v = preset.values
        withAnimation(.easeInOut(duration: 0.6)) {
            azimuth = v.azimuth
            elevation = v.elevation
            distance = v.distance
            fov = v.fov
        }
    }

    func apply(preset: CameraPreset) {
        let v = preset.values
        withAnimation(.easeInOut(duration: 0.65)) {
            azimuth = v.azimuth
            elevation = v.elevation
            distance = v.distance
            fov = v.fov
        }
    }

    func orbit(dx: CGFloat, dy: CGFloat) {
        azimuth += Double(dx) * 0.22
        elevation = min(85, max(2, elevation + Double(dy) * 0.20))
        if autoRotate {
            // Dragging implies manual control; keep the pattern animation off
            // so the user can compose a still.
            autoRotate = false
        }
    }

    func zoom(delta: CGFloat) {
        distance = min(92, max(24, distance * exp(-Double(delta) * 0.012)))
    }

    func resetEvolution() {
        simulationTime = 0
        timeResetCounter += 1
        simResetCounter += 1
    }

    func resetCamera() {
        azimuth = 34
        elevation = 36
        distance = 54
        fov = 38
    }

    func requestFinal(url: URL) {
        guard !isBusy else { return }
        autoRotate = false
        finalRequest = FinalRequest(url: url, longEdge: finalLongEdge, samples: finalSamples)
        phase = .rendering
        renderProgress = 0
        renderSamplesDone = 0
        renderSamplesTarget = finalSamples
        renderElapsed = 0
        savedURL = nil
        statusMessage = "正在渲染最终帧"
    }

    func cancelFinal() {
        finalRequest = nil
        phase = .idle
        renderProgress = 0
        statusMessage = "已取消"
    }

    func finishFinal(url: URL) {
        savedURL = url
        phase = .done
        finalRequest = nil
        renderProgress = 1
        statusMessage = "渲染完成"
        withAnimation(.easeOut(duration: 0.25)) {
            showIntroOverlay = false
        }
    }

    func fail(_ message: String) {
        errorMessage = message
        phase = .failed
        finalRequest = nil
        statusMessage = "渲染失败"
    }

    func updateStatus(fps: Double, width: Int, height: Int, samples: Int) {
        previewFPS = fps
        previewWidth = width
        previewHeight = height
        previewSamples = samples
    }

    func updateProgress(done: Int, target: Int, elapsed: Double) {
        renderSamplesDone = done
        renderSamplesTarget = target
        renderElapsed = elapsed
        renderProgress = target > 0 ? Double(done) / Double(target) : 0
        if phase != .saving { phase = .rendering }
    }

    func markSaving(width: Int, height: Int) {
        finalWidth = width
        finalHeight = height
        phase = .saving
        statusMessage = "正在写入 16-bit PNG"
    }
}
