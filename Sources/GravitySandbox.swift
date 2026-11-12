import Foundation
import SwiftUI
import QuartzCore

enum SandboxTool: String, CaseIterable, Identifiable {
    case move
    case velocity

    var id: String { rawValue }
    var title: String {
        switch self {
        case .move: return "移动"
        case .velocity: return "初速度"
        }
    }
    var subtitle: String {
        switch self {
        case .move: return "拖动星球改变位置"
        case .velocity: return "从星球拖出速度箭头"
        }
    }
    var symbol: String {
        switch self {
        case .move: return "hand.draw"
        case .velocity: return "location.north.line"
        }
    }
}

enum SandboxKind: String, CaseIterable, Identifiable {
    case star
    case rocky
    case gasGiant
    case blackHole

    var id: String { rawValue }

    var title: String {
        switch self {
        case .star: return "恒星"
        case .rocky: return "岩石行星"
        case .gasGiant: return "气态巨行星"
        case .blackHole: return "黑洞"
        }
    }

    var shortTitle: String {
        switch self {
        case .star: return "STAR"
        case .rocky: return "ROCKY"
        case .gasGiant: return "GIANT"
        case .blackHole: return "BH"
        }
    }

    /// Mass in Earth masses.
    var defaultMass: Double {
        switch self {
        case .star: return 333_000
        case .rocky: return 1
        case .gasGiant: return 318
        case .blackHole: return 1_500_000
        }
    }

    var color: Color {
        switch self {
        case .star: return Color(red: 1.00, green: 0.74, blue: 0.36)
        case .rocky: return Color(red: 0.58, green: 0.68, blue: 0.88)
        case .gasGiant: return Color(red: 0.90, green: 0.62, blue: 0.40)
        case .blackHole: return Color(red: 0.55, green: 0.30, blue: 0.95)
        }
    }

    var symbol: String {
        switch self {
        case .star: return "sun.max.fill"
        case .rocky: return "circle.fill"
        case .gasGiant: return "circle.dotted"
        case .blackHole: return "circle.circle.fill"
        }
    }
}

struct SandboxBody: Identifiable {
    let id: UUID
    var name: String
    var kind: SandboxKind
    /// Earth masses.
    var mass: Double
    /// AU. The canvas uses a right-handed astronomical plane with y up;
    /// rendering flips y for screen coordinates.
    var position: CGPoint
    /// AU per year.
    var velocity: CGVector
    var color: Color
    var trail: [CGPoint]

    init(kind: SandboxKind, name: String, mass: Double,
         position: CGPoint, velocity: CGVector = .zero,
         color: Color? = nil) {
        self.id = UUID()
        self.name = name
        self.kind = kind
        self.mass = mass
        self.position = position
        self.velocity = velocity
        self.color = color ?? kind.color
        self.trail = []
    }

    var displayRadius: CGFloat {
        let logM = log10(max(mass, 0.01))
        return min(23, max(3.5, 3.8 + 2.25 * CGFloat(logM + 0.5)))
    }

    var collisionRadiusAU: Double {
        max(0.0035, 0.003 + 0.0018 * Double(log10(max(mass, 0.01) + 1)))
    }
}

final class GravitySandbox: ObservableObject {
    static let earthMassInSolar = 1.0 / 333_000.0
    static let gravitationalConstant = 4.0 * Double.pi * Double.pi / 333_000.0
    static let maxBodies = 64

    @Published var bodies: [SandboxBody] = []
    @Published var selectedID: UUID?
    @Published var tool: SandboxTool = .move
    @Published var running = false
    @Published var speed: Double = 0.25          // years per real second
    @Published var zoom: Double = 1.0
    @Published var showTrails = true
    @Published var showVelocities = true
    @Published var collisionsEnabled = true
    @Published var elapsedYears: Double = 0

    private var initialBodies: [SandboxBody] = []
    private var lastTick = CACurrentMediaTime()
    private var nameCounter = 1

    var selected: SandboxBody? {
        guard let id = selectedID else { return nil }
        return bodies.first { $0.id == id }
    }

    func massText(_ mass: Double) -> String {
        if mass >= 1000 {
            return String(format: "%.2f M☉", mass / 333_000.0)
        }
        if mass >= 100 {
            return String(format: "%.0f M⊕", mass)
        }
        return String(format: "%.2f M⊕", mass)
    }

    var totalEnergy: Double {
        var kinetic = 0.0
        var potential = 0.0
        for i in bodies.indices {
            kinetic += 0.5 * bodies[i].mass *
                (bodies[i].velocity.dx * bodies[i].velocity.dx +
                 bodies[i].velocity.dy * bodies[i].velocity.dy)
            for j in (i + 1)..<bodies.count {
                let dx = bodies[j].position.x - bodies[i].position.x
                let dy = bodies[j].position.y - bodies[i].position.y
                let r = max(0.002, sqrt(dx * dx + dy * dy))
                potential -= Self.gravitationalConstant *
                    bodies[i].mass * bodies[j].mass / r
            }
        }
        return kinetic + potential
    }

    func pointsPerAU(for size: CGSize) -> CGFloat {
        max(12, min(size.width, size.height) / 12.0) * CGFloat(zoom)
    }

    func screenPoint(_ world: CGPoint, in size: CGSize) -> CGPoint {
        let s = pointsPerAU(for: size)
        return CGPoint(x: size.width * 0.5 + world.x * s,
                       y: size.height * 0.5 - world.y * s)
    }

    func worldPoint(_ screen: CGPoint, in size: CGSize) -> CGPoint {
        let s = pointsPerAU(for: size)
        return CGPoint(x: (screen.x - size.width * 0.5) / s,
                       y: (size.height * 0.5 - screen.y) / s)
    }

    func body(at screen: CGPoint, in size: CGSize) -> UUID? {
        let s = pointsPerAU(for: size)
        var best: (UUID, CGFloat)?
        for body in bodies {
            let p = screenPoint(body.position, in: size)
            let r = max(12, body.displayRadius + 7)
            let d = hypot(screen.x - p.x, screen.y - p.y)
            if d < r, best == nil || d < best!.1 {
                best = (body.id, d)
            }
        }
        _ = s
        return best?.0
    }

    func add(kind: SandboxKind, at position: CGPoint) {
        guard bodies.count < Self.maxBodies else { return }
        let name: String
        switch kind {
        case .star: name = "S\(nameCounter)"
        case .rocky: name = "P\(nameCounter)"
        case .gasGiant: name = "G\(nameCounter)"
        case .blackHole: name = "BH\(nameCounter)"
        }
        nameCounter += 1
        let body = SandboxBody(kind: kind, name: name, mass: kind.defaultMass,
                               position: position)
        bodies.append(body)
        selectedID = body.id
        captureInitial()
    }

    func removeSelected() {
        guard let id = selectedID else { return }
        bodies.removeAll { $0.id == id }
        selectedID = bodies.last?.id
        captureInitial()
    }

    func moveSelected(to position: CGPoint) {
        guard let id = selectedID, let idx = bodies.firstIndex(where: { $0.id == id }) else { return }
        bodies[idx].position = position
        bodies[idx].trail.removeAll()
        captureInitial()
    }

    func setVelocity(_ velocity: CGVector) {
        guard let id = selectedID, let idx = bodies.firstIndex(where: { $0.id == id }) else { return }
        bodies[idx].velocity = velocity
        bodies[idx].trail.removeAll()
        captureInitial()
    }

    func commitCurrentEdit() {
        captureInitial()
    }

    func setMass(_ mass: Double) {
        guard let id = selectedID, let idx = bodies.firstIndex(where: { $0.id == id }) else { return }
        bodies[idx].mass = max(0.01, min(5_000_000, mass))
        captureInitial()
    }

    func renameSelected(_ name: String) {
        guard let id = selectedID, let idx = bodies.firstIndex(where: { $0.id == id }) else { return }
        bodies[idx].name = String(name.prefix(10))
        captureInitial()
    }

    func toggleRunning() {
        running.toggle()
        lastTick = CACurrentMediaTime()
    }

    func clear() {
        bodies.removeAll()
        selectedID = nil
        initialBodies.removeAll()
        elapsedYears = 0
        running = false
    }

    func reset() {
        bodies = initialBodies
        if selectedID == nil || !bodies.contains(where: { $0.id == selectedID }) {
            selectedID = bodies.first?.id
        }
        elapsedYears = 0
        running = false
        lastTick = CACurrentMediaTime()
    }

    func stepOnce() {
        let dt = 0.005
        integrate(dtYears: dt)
        elapsedYears += dt
    }

    func tick() {
        let now = CACurrentMediaTime()
        let realDt = min(0.05, max(0.0, now - lastTick))
        lastTick = now
        guard running, !bodies.isEmpty else { return }
        let simYears = speed * realDt
        guard simYears > 0 else { return }
        let substeps = min(8, max(1, Int(ceil(simYears / 0.01))))
        let dt = simYears / Double(substeps)
        for _ in 0..<substeps {
            integrate(dtYears: dt)
            elapsedYears += dt
        }
    }

    private func captureInitial() {
        // Keep the setup snapshot current while the user is composing; once
        // running, reset returns to the last composed state.
        if !running {
            initialBodies = bodies
        }
    }

    private func accelerations() -> [CGVector] {
        var acc = Array(repeating: CGVector.zero, count: bodies.count)
        guard bodies.count > 1 else { return acc }
        let eps2 = 0.02 * 0.02
        for i in 0..<bodies.count {
            var ax = 0.0
            var ay = 0.0
            for j in 0..<bodies.count where j != i {
                let dx = bodies[j].position.x - bodies[i].position.x
                let dy = bodies[j].position.y - bodies[i].position.y
                let r2 = dx * dx + dy * dy + eps2
                let inv = Self.gravitationalConstant * bodies[j].mass /
                    (r2 * sqrt(r2))
                ax += dx * inv
                ay += dy * inv
            }
            acc[i] = CGVector(dx: ax, dy: ay)
        }
        return acc
    }

    private func integrate(dtYears dt: Double) {
        guard !bodies.isEmpty else { return }
        let a0 = accelerations()
        for i in bodies.indices {
            let p = bodies[i].position
            let v = bodies[i].velocity
            let a = a0[i]
            bodies[i].position = CGPoint(
                x: p.x + v.dx * dt + 0.5 * a.dx * dt * dt,
                y: p.y + v.dy * dt + 0.5 * a.dy * dt * dt
            )
            bodies[i].velocity = CGVector(
                dx: v.dx + 0.5 * a.dx * dt,
                dy: v.dy + 0.5 * a.dy * dt
            )
        }
        let a1 = accelerations()
        for i in bodies.indices {
            bodies[i].velocity = CGVector(
                dx: bodies[i].velocity.dx + 0.5 * a1[i].dx * dt,
                dy: bodies[i].velocity.dy + 0.5 * a1[i].dy * dt
            )
        }
        if dt > 0 {
            for i in bodies.indices {
                if showTrails {
                    bodies[i].trail.append(bodies[i].position)
                    if bodies[i].trail.count > 420 {
                        bodies[i].trail.removeFirst(bodies[i].trail.count - 420)
                    }
                }
            }
        }
        if collisionsEnabled {
            mergeCollisions()
        }
        // Drop runaway bodies that leave the sandbox by a wide margin.
        bodies.removeAll { abs($0.position.x) > 200 || abs($0.position.y) > 200 }
        if let selectedID, !bodies.contains(where: { $0.id == selectedID }) {
            self.selectedID = bodies.first?.id
        }
    }

    private func mergeCollisions() {
        guard bodies.count > 1 else { return }
        var merged = true
        while merged {
            merged = false
            outer: for i in bodies.indices {
                for j in (i + 1)..<bodies.count {
                    let dx = bodies[j].position.x - bodies[i].position.x
                    let dy = bodies[j].position.y - bodies[i].position.y
                    let dist = sqrt(dx * dx + dy * dy)
                    if dist < bodies[i].collisionRadiusAU + bodies[j].collisionRadiusAU {
                        let m1 = bodies[i].mass
                        let m2 = bodies[j].mass
                        let mt = m1 + m2
                        let px = (bodies[i].position.x * m1 + bodies[j].position.x * m2) / mt
                        let py = (bodies[i].position.y * m1 + bodies[j].position.y * m2) / mt
                        let vx = (bodies[i].velocity.dx * m1 + bodies[j].velocity.dx * m2) / mt
                        let vy = (bodies[i].velocity.dy * m1 + bodies[j].velocity.dy * m2) / mt
                        bodies[i].mass = mt
                        bodies[i].position = CGPoint(x: px, y: py)
                        bodies[i].velocity = CGVector(dx: vx, dy: vy)
                        bodies[i].trail.removeAll()
                        if m2 > m1 { bodies[i].color = bodies[j].color }
                        bodies.remove(at: j)
                        selectedID = bodies[i].id
                        merged = true
                        break outer
                    }
                }
            }
        }
    }

    private func bodyNamed(_ name: String, kind: SandboxKind, mass: Double,
                           at position: CGPoint, velocity: CGVector) -> SandboxBody {
        var b = SandboxBody(kind: kind, name: name, mass: mass,
                            position: position, velocity: velocity)
        b.color = kind.color
        return b
    }

    func loadExample() {
        let sunMass = 333_000.0
        var list: [SandboxBody] = []
        list.append(bodyNamed("SUN", kind: .star, mass: sunMass,
                              at: .zero, velocity: .zero))

        func addPlanet(_ name: String, radius: Double, mass: Double,
                       color: Color, angle: Double) {
            let r = radius
            let x = cos(angle) * r
            let y = sin(angle) * r
            let v = sqrt(Self.gravitationalConstant * sunMass / r)
            var b = SandboxBody(kind: .rocky, name: name, mass: mass,
                                position: CGPoint(x: x, y: y),
                                velocity: CGVector(dx: -sin(angle) * v,
                                                   dy: cos(angle) * v))
            b.color = color
            list.append(b)
        }
        addPlanet("EARTH", radius: 1.0, mass: 1, color: Color(red: 0.30, green: 0.62, blue: 1.0), angle: 0)
        addPlanet("GIANT", radius: 2.4, mass: 318, color: Color(red: 0.94, green: 0.68, blue: 0.42), angle: 2.1)
        addPlanet("ICE", radius: 4.8, mass: 17, color: Color(red: 0.52, green: 0.84, blue: 0.92), angle: 4.2)
        bodies = list
        selectedID = list.first?.id
        nameCounter = 1
        elapsedYears = 0
        running = false
        initialBodies = list
    }
}
