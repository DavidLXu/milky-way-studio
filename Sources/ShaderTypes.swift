import Foundation
import simd

struct SceneUniforms {
    var resolution: SIMD4<Float> = .zero
    var cameraPos: SIMD4<Float> = .zero
    var cameraRight: SIMD4<Float> = .zero
    var cameraUp: SIMD4<Float> = .zero
    var cameraForward: SIMD4<Float> = .zero
    var params0: SIMD4<Float> = .zero
    var params1: SIMD4<Float> = .zero
    var params2: SIMD4<Float> = .zero
    var params3: SIMD4<Float> = .zero
    var params4: SIMD4<Float> = .zero
}

struct CompositeUniforms {
    var resolution: SIMD4<Float> = .zero
    var params0: SIMD4<Float> = .zero
    var params1: SIMD4<Float> = .zero
    var params2: SIMD4<Float> = .zero
}

struct BloomUniforms {
    var texel: SIMD4<Float> = .zero
    var params: SIMD4<Float> = .zero
}

struct BuildUniforms {
    var params: SIMD4<Float> = .zero
}

struct StarParticle {
    var posSize: SIMD4<Float> = .zero
    var colorBrightness: SIMD4<Float> = .zero
    var velocity: SIMD4<Float> = .zero
}

enum SceneMode: String, CaseIterable, Identifiable {
    case galaxy
    case blackHole
    case solarSystem

    var id: String { rawValue }
    var title: String {
        switch self {
        case .galaxy: return "MILKY WAY"
        case .blackHole: return "BLACK HOLE"
        case .solarSystem: return "SOLAR SYSTEM"
        }
    }
}

/// Must match `struct SolarPlanet` in Shaders.metal.
struct SolarPlanetGPU {
    var posRadius = SIMD4<Float>(0, 0, 0, 0)
    var color = SIMD4<Float>(0, 0, 0, 0)
    var orbit = SIMD4<Float>(0, 0, 0, 0)
    var flags = SIMD4<Float>(0, 0, 0, 0)
}

struct RenderSettings: Equatable {
    var mode: SceneMode = .galaxy
    var azimuth: Double = 34.0
    var elevation: Double = 31.0
    var distance: Double = 51.0
    var fov: Double = 38.0

    var time: Double = 0.0
    var autoRotate: Bool = true
    var rotationSpeed: Double = 7.0

    var dust: Double = 1.0
    var shearEnabled: Bool = true
    var resetCounter: Int = 0
    var exposure: Double = 0.0
    var bloom: Double = 0.48
    var vignette: Double = 0.30
    var grain: Double = 0.012
    var chromatic: Double = 0.35

    var steps: Int = 128
    var seed: UInt32 = 1
    var starLayerEnabled: Bool = true
    var dustHighEnabled: Bool = true
    var starDynamicsEnabled: Bool = false
    var simResetCounter: Int = 0
    var previewScale: Double = 0.62
    var previewSamples: Int = 64
    var previewSPP: Int = 2
    var targetSamples: Int = 96

    // Black hole / relativistic disk
    var bhTemp: Double = 10500
    var bhBrightness: Double = 1.0
    var bhDiskOuter: Double = 12.0
    var bhDoppler: Bool = true
    var bhJets: Bool = false
    var bhSoftness: Double = 1.6
    var bhThickness: Double = 0.25

    // Solar system
    var solarPlanetScale: Double = 1.0
    var solarOrbitLines: Bool = true
    var solarBelts: Bool = true
    var solarMoons: Bool = true
    var solarExposure: Double = 0.0
    var solarBloom: Double = 0.38
}

struct SceneKey: Equatable {
    var mode: SceneMode
    var azimuth: Double
    var elevation: Double
    var distance: Double
    var fov: Double
    var time: Double
    var dust: Double
    var steps: Int
    var seed: UInt32
    var stars: Bool
    var highDust: Bool
    var dynamics: Bool
    var bhTemp: Double
    var bhBrightness: Double
    var bhDiskOuter: Double
    var bhDoppler: Bool
    var bhJets: Bool
    var bhSoftness: Double
    var bhThickness: Double
    var solarPlanetScale: Double
    var solarOrbitLines: Bool
    var solarBelts: Bool
    var solarMoons: Bool
    var width: Int
    var height: Int

    init(settings: RenderSettings, width: Int, height: Int) {
        self.mode = settings.mode
        self.azimuth = settings.azimuth
        self.elevation = settings.elevation
        self.distance = settings.distance
        self.fov = settings.fov
        self.time = settings.time
        self.dust = settings.dust
        self.steps = settings.steps
        self.seed = settings.seed
        self.stars = settings.starLayerEnabled
        self.highDust = settings.dustHighEnabled
        self.dynamics = settings.starDynamicsEnabled
        self.bhTemp = settings.bhTemp
        self.bhBrightness = settings.bhBrightness
        self.bhDiskOuter = settings.bhDiskOuter
        self.bhDoppler = settings.bhDoppler
        self.bhJets = settings.bhJets
        self.bhSoftness = settings.bhSoftness
        self.bhThickness = settings.bhThickness
        self.solarPlanetScale = settings.solarPlanetScale
        self.solarOrbitLines = settings.solarOrbitLines
        self.solarBelts = settings.solarBelts
        self.solarMoons = settings.solarMoons
        self.width = width
        self.height = height
    }
}

struct CameraBasis {
    var position: SIMD3<Float>
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    var forward: SIMD3<Float>
    var tanHalfFov: Float

    static func make(settings: RenderSettings, aspect: Double) -> CameraBasis {
        let az = settings.azimuth * .pi / 180.0
        let el = max(-84.0, min(84.0, settings.elevation)) * .pi / 180.0
        let minimumDistance: Double
        switch settings.mode {
        case .galaxy: minimumDistance = 24.0
        case .blackHole: minimumDistance = 8.0
        case .solarSystem: minimumDistance = 0.65
        }
        let d = max(minimumDistance, settings.distance)

        let eye = SIMD3<Double>(
            d * cos(el) * sin(az),
            d * sin(el),
            d * cos(el) * cos(az)
        )
        let target = SIMD3<Double>(0.0, 0.0, 0.0)
        var forward = simd_normalize(target - eye)
        let worldUp = SIMD3<Double>(0.0, 1.0, 0.0)
        var right = simd_cross(forward, worldUp)
        if simd_length(right) < 1e-5 {
            right = SIMD3<Double>(1.0, 0.0, 0.0)
        }
        right = simd_normalize(right)
        let up = simd_normalize(simd_cross(right, forward))
        let tanHalf = tan(max(12.0, min(75.0, settings.fov)) * .pi / 360.0)

        return CameraBasis(
            position: SIMD3<Float>(Float(eye.x), Float(eye.y), Float(eye.z)),
            right: SIMD3<Float>(Float(right.x), Float(right.y), Float(right.z)),
            up: SIMD3<Float>(Float(up.x), Float(up.y), Float(up.z)),
            forward: SIMD3<Float>(Float(forward.x), Float(forward.y), Float(forward.z)),
            tanHalfFov: Float(tanHalf)
        )
    }
}
