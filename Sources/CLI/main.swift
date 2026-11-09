import Foundation
import Metal

let args = CommandLine.arguments

func stringValue(_ key: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: key), i + 1 < args.count else { return fallback }
    return args[i + 1]
}
func doubleValue(_ key: String, _ fallback: Double) -> Double {
    Double(stringValue(key, String(fallback))) ?? fallback
}
func intValue(_ key: String, _ fallback: Int) -> Int {
    Int(stringValue(key, String(fallback))) ?? fallback
}

let output = URL(fileURLWithPath: stringValue("--out", "MilkyWay.png"))
let width = max(320, intValue("--width", 1600))
let height = max(200, intValue("--height", 1000))
let samples = max(1, intValue("--samples", 16))

var settings = RenderSettings()
settings.azimuth = doubleValue("--az", settings.azimuth)
settings.elevation = doubleValue("--el", settings.elevation)
settings.distance = doubleValue("--dist", settings.distance)
settings.fov = doubleValue("--fov", settings.fov)
settings.time = doubleValue("--time", 0)
settings.dust = doubleValue("--dust", 1.0)
settings.exposure = doubleValue("--exposure", 0.0)
settings.bloom = doubleValue("--bloom", settings.bloom)
settings.steps = max(32, intValue("--steps", 128))
settings.seed = UInt32(max(0, intValue("--seed", 1)))
settings.autoRotate = false
settings.starLayerEnabled = !args.contains("--no-stars")
settings.dustHighEnabled = !args.contains("--no-highdust")
if args.contains("--blackhole") {
    settings.mode = .blackHole
    settings.starLayerEnabled = false
    settings.dustHighEnabled = false
    settings.bhTemp = doubleValue("--bh-temp", 10500)
    settings.bhBrightness = doubleValue("--bh-brightness", 1.0)
    settings.bhDiskOuter = doubleValue("--bh-outer", 12.0)
    settings.bhDoppler = !args.contains("--no-doppler")
    settings.bhJets = args.contains("--jets")
    settings.bhSoftness = doubleValue("--bh-soft", 1.6)
}

do {
    print("Metal device: \(MTLCreateSystemDefaultDevice()?.name ?? "unknown")")
    let engine = try GalaxyEngine()
    print(String(format: "Shader compile: %.2fs   volume build: %.2fs", engine.compileSeconds, engine.buildSeconds))
    let result = try engine.renderOffscreen(width: width,
                                            height: height,
                                            samples: samples,
                                            settings: settings,
                                            outputURL: output) { p in
        if p < 1.0 {
            print(String(format: "  %3.0f%%", p * 100))
        }
    }
    print(String(format: "Rendered %dx%d, %d spp in %.2fs -> %@",
                 width, height, samples, result.seconds, output.path))
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
