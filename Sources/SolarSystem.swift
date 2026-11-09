import Foundation
import simd

/// J2000 heliocentric osculating elements. Positions are integrated with
/// Kepler's equation (two-body), not with a full planetary N-body solver.
enum SolarSystem {
    static let sunVisualRadius: Float = 0.145
    static let maxBodies = 16
    static let names = ["水星", "金星", "地球", "火星", "木星", "土星", "天王星", "海王星", "冥王星"]
    static let moonTypeBase: Float = 8

    private struct Elements {
        let a: Double
        let e: Double
        let inclination: Double
        let node: Double
        let peri: Double
        let meanAnomaly: Double
        let period: Double
        let realRadius: Double
        let color: SIMD3<Float>
        let type: Float
        let ring: Float
        let ringTilt: Double
        let orbitAlpha: Float
    }

    // a (AU), e, i, Ω, ω, M0 (deg), period (days), radius (AU), color,
    // surface type, ring strength, ring tilt (deg), orbit-line opacity.
    private static let sol: [Elements] = [
        Elements(a: 0.387098, e: 0.205630, inclination: 7.005, node: 48.331, peri: 29.124, meanAnomaly: 174.796, period: 87.969, realRadius: 1.630e-5, color: SIMD3(0.63, 0.59, 0.54), type: 0, ring: 0, ringTilt: 0, orbitAlpha: 0.22),
        Elements(a: 0.723332, e: 0.006772, inclination: 3.394, node: 76.680, peri: 54.884, meanAnomaly: 50.115, period: 224.701, realRadius: 4.045e-5, color: SIMD3(0.95, 0.84, 0.62), type: 1, ring: 0, ringTilt: 0, orbitAlpha: 0.24),
        Elements(a: 1.000000, e: 0.016708, inclination: 0.0, node: -11.26064, peri: 114.20783, meanAnomaly: 358.617, period: 365.256, realRadius: 4.264e-5, color: SIMD3(0.24, 0.50, 0.92), type: 2, ring: 0, ringTilt: 0, orbitAlpha: 0.30),
        Elements(a: 1.523679, e: 0.093400, inclination: 1.850, node: 49.558, peri: 286.502, meanAnomaly: 19.373, period: 686.980, realRadius: 2.260e-5, color: SIMD3(0.84, 0.37, 0.20), type: 3, ring: 0, ringTilt: 0, orbitAlpha: 0.24),
        Elements(a: 5.20440, e: 0.04890, inclination: 1.303, node: 100.464, peri: 273.867, meanAnomaly: 20.020, period: 4332.59, realRadius: 4.673e-4, color: SIMD3(0.86, 0.72, 0.55), type: 4, ring: 0, ringTilt: 0, orbitAlpha: 0.20),
        Elements(a: 9.5826, e: 0.05650, inclination: 2.485, node: 113.665, peri: 339.392, meanAnomaly: 317.020, period: 10759.22, realRadius: 3.889e-4, color: SIMD3(0.91, 0.83, 0.64), type: 5, ring: 1.0, ringTilt: 26.73, orbitAlpha: 0.18),
        Elements(a: 19.19126, e: 0.04717, inclination: 0.773, node: 74.006, peri: 96.998, meanAnomaly: 142.238, period: 30688.5, realRadius: 1.708e-4, color: SIMD3(0.57, 0.83, 0.87), type: 6, ring: 0.22, ringTilt: 97.77, orbitAlpha: 0.15),
        Elements(a: 30.07, e: 0.00859, inclination: 1.770, node: 131.783, peri: 273.187, meanAnomaly: 259.883, period: 60182.0, realRadius: 1.651e-4, color: SIMD3(0.28, 0.46, 0.86), type: 7, ring: 0, ringTilt: 0, orbitAlpha: 0.14),
        Elements(a: 39.48, e: 0.2488, inclination: 17.16, node: 110.299, peri: 113.834, meanAnomaly: 14.53, period: 90560.0, realRadius: 1.18e-5, color: SIMD3(0.72, 0.65, 0.58), type: 14, ring: 0, ringTilt: 0, orbitAlpha: 0.10)
    ]

    private static func kepler(_ meanAnomaly: Double, _ e: Double) -> Double {
        let m = meanAnomaly.truncatingRemainder(dividingBy: 2.0 * .pi)
        var E = m
        for _ in 0..<9 {
            E -= (E - e * sin(E) - m) / (1.0 - e * cos(E))
        }
        return E
    }

    /// Heliocentric ecliptic position in AU. Render coordinates put the
    /// ecliptic plane in XZ and the ecliptic north pole on +Y.
    private static func heliocentric(_ el: Elements, days: Double) -> SIMD3<Double> {
        let n = days / el.period
        let M = (el.meanAnomaly + 360.0 * n) * .pi / 180.0
        let E = kepler(M, el.e)
        let xv = el.a * (cos(E) - el.e)
        let yv = el.a * sqrt(max(0.0, 1.0 - el.e * el.e)) * sin(E)

        let w = el.peri * .pi / 180.0
        let om = el.node * .pi / 180.0
        let inc = el.inclination * .pi / 180.0

        let x1 = xv * cos(w) - yv * sin(w)
        let y1 = xv * sin(w) + yv * cos(w)
        let X = x1 * cos(om) - y1 * sin(om) * cos(inc)
        let Y = x1 * sin(om) + y1 * cos(om) * cos(inc)
        let Z = y1 * sin(inc)
        return SIMD3(X, Z, Y)
    }

    private static func visualRadius(_ real: Double, scale: Double) -> Float {
        let s = max(0.35, min(3.2, scale))
        return Float(max(real * 190.0 * s, 0.021 * s))
    }

    private static func body(_ type: Float, _ color: SIMD3<Float>, pos: SIMD3<Double>,
                             radius: Float, orbit: SIMD4<Float>, ring: Float = 0,
                             ringTilt: Double = 0) -> SolarPlanetGPU {
        var p = SolarPlanetGPU()
        p.posRadius = SIMD4<Float>(Float(pos.x), Float(pos.y), Float(pos.z), radius)
        p.color = SIMD4<Float>(color.x, color.y, color.z, 1)
        p.orbit = orbit
        p.flags = SIMD4<Float>(type, ring, Float(ringTilt * .pi / 180.0), 1)
        return p
    }

    static func renderPlanets(days: Double, scale: Double) -> [SolarPlanetGPU] {
        var out: [SolarPlanetGPU] = []
        out.reserveCapacity(maxBodies)

        var positions: [SIMD3<Double>] = []
        for el in sol {
            let p = heliocentric(el, days: days)
            positions.append(p)
            let orbit = SIMD4<Float>(Float(el.a), Float(el.e),
                                     Float((el.node + el.peri) * .pi / 180.0),
                                     el.orbitAlpha)
            out.append(body(el.type, el.color, pos: p,
                            radius: visualRadius(el.realRadius, scale: scale),
                            orbit: orbit, ring: el.ring, ringTilt: el.ringTilt))
        }

        // Earth's Moon.
        let earth = positions[2]
        let earthR = visualRadius(sol[2].realRadius, scale: scale)
        let moonR = max(earthR * 2.7, 0.030 * Float(max(0.5, scale)))
        let moonAngle = 2.0 * .pi * days / 27.322
        out.append(body(8, SIMD3(0.72, 0.70, 0.66),
                        pos: earth + SIMD3(cos(moonAngle) * Double(moonR), 0, sin(moonAngle) * Double(moonR)),
                        radius: max(earthR * 0.24, 0.0045 * Float(max(0.5, scale))),
                        orbit: .zero))

        // Galilean moons around Jupiter.
        let jupiter = positions[4]
        let jupR = visualRadius(sol[4].realRadius, scale: scale)
        let galilean: [(Float, Double, Float, SIMD3<Float>)] = [
            (1.65, 1.769, 0.26, SIMD3(0.92, 0.82, 0.38)),
            (2.05, 3.551, 0.24, SIMD3(0.84, 0.82, 0.76)),
            (2.50, 7.155, 0.28, SIMD3(0.62, 0.58, 0.52)),
            (3.10, 16.689, 0.26, SIMD3(0.42, 0.38, 0.34))
        ]
        for (i, m) in galilean.enumerated() {
            let ang = 2.0 * .pi * days / m.1 + Double(i) * 1.3
            let rr = Double(jupR * m.0)
            out.append(body(9 + Float(i), m.3,
                            pos: jupiter + SIMD3(cos(ang) * rr, 0, sin(ang) * rr),
                            radius: max(jupR * m.2, 0.0045 * Float(max(0.5, scale))),
                            orbit: .zero))
        }

        // Titan around Saturn.
        let saturn = positions[5]
        let satR = visualRadius(sol[5].realRadius, scale: scale)
        let titanAngle = 2.0 * .pi * days / 15.945 + 0.8
        out.append(body(13, SIMD3(0.88, 0.65, 0.38),
                        pos: saturn + SIMD3(cos(titanAngle) * Double(satR * 3.2), 0,
                                            sin(titanAngle) * Double(satR * 3.2)),
                        radius: max(satR * 0.20, 0.0045 * Float(max(0.5, scale))),
                        orbit: .zero))

        while out.count < maxBodies {
            out.append(SolarPlanetGPU())
        }
        return Array(out.prefix(maxBodies))
    }

    /// Human-readable simulation time.
    static func timeLabel(days: Double) -> String {
        let years = days / 365.25
        if abs(years) >= 1.0 {
            return String(format: "%.2f 年", years)
        }
        return String(format: "%.1f 天", days)
    }
}
