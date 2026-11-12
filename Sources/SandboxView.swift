import SwiftUI
import Foundation
import QuartzCore

// MARK: - Canvas

struct SandboxView: View {
    @ObservedObject var sandbox: GravitySandbox

    @State private var draggingBody: UUID?
    @State private var draggingIsVelocity = false
    @State private var draggingMoved = false
    @State private var dragPoint: CGPoint?

    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { context, canvasSize in
                    draw(context: context, size: canvasSize)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(size: size))
                .dropDestination(for: String.self) { items, location in
                    guard let raw = items.first,
                          let kind = SandboxKind(rawValue: raw) else { return false }
                    let world = sandbox.worldPoint(location, in: size)
                    sandbox.add(kind: kind, at: world)
                    return true
                } isTargeted: { _ in }

                if sandbox.bodies.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.draw")
                            .font(.system(size: 24, weight: .light))
                            .foregroundColor(Palette.amber.opacity(0.75))
                        Text("把左侧的星球拖进来")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Palette.ink.opacity(0.62))
                        Text("拖动星球设置位置 · 切到“初速度”拖出箭头")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(Palette.faint)
                    }
                    .allowsHitTesting(false)
                }

                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("N-BODY  /  ALL-PAIRS GRAVITY")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .tracking(1.3)
                                .foregroundColor(Palette.amber.opacity(0.8))
                            Text("\(sandbox.bodies.count) BODIES  ·  \(sandbox.running ? "RUNNING" : "PAUSED")  ·  t = \(String(format: "%.2f", sandbox.elapsedYears)) yr")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(Palette.faint)
                        }
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Text(sandbox.tool == .move ?
                             "拖动星球改变位置" :
                             "从星球拖出箭头设置初速度")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(.white.opacity(0.34))
                        Spacer()
                        Text(String(format: "%.1f px/AU", sandbox.pointsPerAU(for: size)))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.white.opacity(0.24))
                    }
                }
                .padding(.top, 112)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .onReceive(timer) { _ in sandbox.tick() }
        }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if draggingBody == nil {
                    if let hit = sandbox.body(at: value.startLocation, in: size) {
                        sandbox.selectedID = hit
                        draggingBody = hit
                        draggingIsVelocity = sandbox.tool == .velocity
                        draggingMoved = false
                    } else {
                        sandbox.selectedID = nil
                        return
                    }
                }
                if hypot(value.translation.width, value.translation.height) > 2 {
                    draggingMoved = true
                }
                guard let id = draggingBody,
                      let idx = sandbox.bodies.firstIndex(where: { $0.id == id }) else { return }

                if sandbox.tool == .velocity {
                    dragPoint = value.location
                } else if draggingMoved {
                    sandbox.bodies[idx].position = sandbox.worldPoint(value.location, in: size)
                    sandbox.bodies[idx].trail.removeAll()
                }
            }
            .onEnded { value in
                defer {
                    draggingBody = nil
                    draggingIsVelocity = false
                    draggingMoved = false
                    dragPoint = nil
                }
                guard let id = draggingBody,
                      let idx = sandbox.bodies.firstIndex(where: { $0.id == id }) else { return }

                if sandbox.tool == .velocity {
                    let origin = sandbox.screenPoint(sandbox.bodies[idx].position, in: size)
                    let pointsPerVelocity = 26.0
                    let vx = Double(value.location.x - origin.x) / pointsPerVelocity
                    let vy = -Double(value.location.y - origin.y) / pointsPerVelocity
                    sandbox.selectedID = id
                    sandbox.setVelocity(CGVector(dx: max(-24, min(24, vx)),
                                                 dy: max(-24, min(24, vy))))
                } else {
                    sandbox.selectedID = id
                    sandbox.bodies[idx].trail.removeAll()
                    sandbox.moveSelected(to: sandbox.bodies[idx].position)
                }
            }
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let ppa = sandbox.pointsPerAU(for: size)

        // Deep-space background.
        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(
                        Gradient(colors: [Color(red: 0.010, green: 0.014, blue: 0.030),
                                          Color(red: 0.025, green: 0.028, blue: 0.050),
                                          Color(red: 0.008, green: 0.010, blue: 0.022)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: size.height)))

        // Star field.
        for i in 0..<150 {
            let h1 = sin(Double(i) * 12.9898 + 4.1414) * 43758.5453
            let h2 = sin(Double(i) * 78.233 + 1.337) * 24634.6345
            let x = CGFloat(h1 - floor(h1)) * size.width
            let y = CGFloat(h2 - floor(h2)) * size.height
            let r = CGFloat(0.4 + 0.9 * (h1 - floor(h1)))
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                         with: .color(.white.opacity(0.18 + 0.25 * (h2 - floor(h2)))))
        }

        // One-AU grid.
        let visibleAU = Double(min(size.width, size.height)) / Double(ppa) * 0.65
        let gridStep = visibleAU > 9 ? 5.0 : (visibleAU > 4 ? 2.0 : 1.0)
        var g = -ceil(visibleAU / gridStep) * gridStep
        while g <= ceil(visibleAU / gridStep) * gridStep {
            let x = center.x + CGFloat(g) * ppa
            let y = center.y - CGFloat(g) * ppa
            var v = Path()
            v.move(to: CGPoint(x: x, y: 0)); v.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(v, with: .color(.white.opacity(0.045)), lineWidth: 0.5)
            var h = Path()
            h.move(to: CGPoint(x: 0, y: y)); h.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(h, with: .color(.white.opacity(0.045)), lineWidth: 0.5)
            g += gridStep
        }
        var axes = Path()
        axes.move(to: CGPoint(x: 0, y: center.y)); axes.addLine(to: CGPoint(x: size.width, y: center.y))
        axes.move(to: CGPoint(x: center.x, y: 0)); axes.addLine(to: CGPoint(x: center.x, y: size.height))
        context.stroke(axes, with: .color(.white.opacity(0.08)), lineWidth: 0.7)

        // Trails.
        if sandbox.showTrails {
            for body in sandbox.bodies where body.trail.count > 1 {
                var path = Path()
                for (i, p) in body.trail.enumerated() {
                    let sp = sandbox.screenPoint(p, in: size)
                    if i == 0 { path.move(to: sp) } else { path.addLine(to: sp) }
                }
                context.stroke(path, with: .color(body.color.opacity(0.30)), lineWidth: 1.0)
            }
        }

        // Velocity arrows.
        if sandbox.showVelocities {
            for body in sandbox.bodies {
                let p = sandbox.screenPoint(body.position, in: size)
                let v = body.velocity
                let len = hypot(v.dx, v.dy)
                guard len > 0.001 else { continue }
                let scale = 26.0
                let end = CGPoint(x: p.x + CGFloat(v.dx) * scale,
                                  y: p.y - CGFloat(v.dy) * scale)
                let selected = body.id == sandbox.selectedID
                drawArrow(context: context, from: p, to: end,
                          color: body.color.opacity(selected ? 0.85 : 0.35),
                          width: selected ? 1.4 : 0.8)
            }
        }
        if let id = draggingBody,
           sandbox.tool == .velocity,
           let point = dragPoint,
           let body = sandbox.bodies.first(where: { $0.id == id }) {
            let p = sandbox.screenPoint(body.position, in: size)
            drawArrow(context: context, from: p, to: point,
                      color: Palette.amber, width: 1.6)
        }

        // Bodies.
        for body in sandbox.bodies {
            let p = sandbox.screenPoint(body.position, in: size)
            let r = body.displayRadius
            let selected = body.id == sandbox.selectedID
            let glow = CGRect(x: p.x - r * 3.2, y: p.y - r * 3.2,
                              width: r * 6.4, height: r * 6.4)
            context.fill(Path(ellipseIn: glow),
                         with: .radialGradient(
                            Gradient(colors: [body.color.opacity(0.22), body.color.opacity(0.04), .clear]),
                            center: p, startRadius: r * 0.6, endRadius: r * 3.2))
            if selected {
                let ring = CGRect(x: p.x - r - 5, y: p.y - r - 5,
                                  width: r * 2 + 10, height: r * 2 + 10)
                context.stroke(Path(ellipseIn: ring),
                               with: .color(Palette.amber.opacity(0.9)),
                               lineWidth: 1.0)
            }
            context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r,
                                                width: r * 2, height: r * 2)),
                         with: .radialGradient(
                            Gradient(colors: [body.color, body.color.opacity(0.72)]),
                            center: CGPoint(x: p.x - r * 0.25, y: p.y - r * 0.28),
                            startRadius: 0.5, endRadius: r))
            context.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r,
                                                  width: r * 2, height: r * 2)),
                           with: .color(.white.opacity(0.30)), lineWidth: 0.6)

            let label = Text("\(body.name)  \(sandbox.massText(body.mass))")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.white.opacity(0.66))
            context.draw(label, at: CGPoint(x: p.x, y: p.y + r + 11), anchor: .top)
        }
    }

    private func drawArrow(context: GraphicsContext, from: CGPoint, to: CGPoint,
                           color: Color, width: CGFloat) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(color), lineWidth: width)
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head: CGFloat = 6
        var h = Path()
        h.move(to: to)
        h.addLine(to: CGPoint(x: to.x - head * cos(angle - 0.5),
                              y: to.y - head * sin(angle - 0.5)))
        h.move(to: to)
        h.addLine(to: CGPoint(x: to.x - head * cos(angle + 0.5),
                              y: to.y - head * sin(angle + 0.5)))
        context.stroke(h, with: .color(color), lineWidth: width)
    }
}

// MARK: - Palette and inspector

struct SandboxPaletteChip: View {
    let kind: SandboxKind

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(kind.color.opacity(0.18)).frame(width: 22, height: 22)
                Image(systemName: kind.symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(kind.color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(Palette.ink.opacity(0.82))
                Text(kind.shortTitle)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(Palette.faint)
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 7))
                .foregroundColor(Palette.faint)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.028)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line, lineWidth: 0.7))
        .draggable(kind.rawValue)
    }
}

struct SandboxSidebar: View {
    @ObservedObject var sandbox: GravitySandbox

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "BODY PALETTE", detail: "拖入画布")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(SandboxKind.allCases) { kind in
                    SandboxPaletteChip(kind: kind)
                        .onTapGesture {
                            sandbox.add(kind: kind, at: CGPoint(x: 0, y: 0))
                        }
                }
            }
            Text("拖拽星球到画面，或点击直接放在中心")
                .font(.system(size: 8.2, design: .monospaced))
                .foregroundColor(Palette.faint)

            SectionHeader(title: "TOOL", detail: "操作")

            HStack(spacing: 6) {
                ForEach(SandboxTool.allCases) { tool in
                    Button {
                        sandbox.tool = tool
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Image(systemName: tool.symbol)
                                    .font(.system(size: 8))
                                Text(tool.title)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            Text(tool.subtitle)
                                .font(.system(size: 7.2, design: .monospaced))
                                .foregroundColor(Palette.faint)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(sandbox.tool == tool ? Palette.panelRaised : Color.white.opacity(0.025)))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(sandbox.tool == tool ? Palette.amber.opacity(0.4) : Palette.line,
                                    lineWidth: 0.7))
                        .foregroundColor(sandbox.tool == tool ? Palette.ink : Palette.dim)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let body = sandbox.selected {
                SectionHeader(title: "BODY", detail: "属性")

                HStack(spacing: 8) {
                    Circle().fill(body.color).frame(width: 8, height: 8)
                    Text(body.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.ink)
                    Spacer()
                    Text(body.kind.title)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(Palette.faint)
                }

                VStack(spacing: 8) {
                    LabeledSlider(title: "质量",
                                  value: Binding(
                                    get: { log10(max(0.1, body.mass)) },
                                    set: { sandbox.setMass(pow(10, $0)) }),
                                  range: -1...6.7,
                                  format: { v in
                                      let m = pow(10, v)
                                      return sandbox.massText(m)
                                  })
                    HStack {
                        Text("初速度")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(Palette.faint)
                        Text(String(format: "%.2f, %.2f AU/yr", body.velocity.dx, body.velocity.dy))
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(Palette.ink.opacity(0.62))
                        Spacer()
                    }
                    TextField("名称", text: Binding(
                        get: { body.name },
                        set: { sandbox.renameSelected($0) }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 9))
                }

                Button {
                    sandbox.removeSelected()
                } label: {
                    Label("删除该星球", systemImage: "trash")
                        .font(.system(size: 9))
                        .foregroundColor(Palette.pink.opacity(0.85))
                }
                .buttonStyle(.plain)
            }

            SectionHeader(title: "SIMULATION", detail: "N-body")

            HStack(spacing: 6) {
                Button {
                    sandbox.toggleRunning()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: sandbox.running ? "pause.fill" : "play.fill")
                        Text(sandbox.running ? "暂停" : "播放")
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 27)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(sandbox.running ? Palette.amber.opacity(0.18) : Palette.panelRaised))
                    .foregroundColor(sandbox.running ? Palette.amber : Palette.ink)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    sandbox.stepOnce()
                } label: {
                    Image(systemName: "forward.frame.fill")
                        .font(.system(size: 10))
                        .frame(width: 32, height: 27)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.panelRaised))
                }
                .buttonStyle(.plain)

                Button {
                    sandbox.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                        .frame(width: 32, height: 27)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.panelRaised))
                }
                .buttonStyle(.plain)

                Button {
                    sandbox.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .frame(width: 32, height: 27)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.panelRaised))
                }
                .buttonStyle(.plain)
            }

            LabeledSlider(title: "时间流速",
                          value: $sandbox.speed,
                          range: 0.01...2.0,
                          format: { String(format: "%.2f 年/s", $0) })
            LabeledSlider(title: "缩放",
                          value: $sandbox.zoom,
                          range: 0.4...3.0,
                          format: { String(format: "%.2f×", $0) })

            HStack(spacing: 9) {
                Toggle("", isOn: $sandbox.showTrails)
                    .toggleStyle(.switch).controlSize(.mini).tint(Palette.blue).labelsHidden()
                Text("轨迹")
                    .font(.system(size: 9.5))
                    .foregroundColor(Palette.ink.opacity(0.8))
                Spacer(minLength: 4)
                Toggle("", isOn: $sandbox.showVelocities)
                    .toggleStyle(.switch).controlSize(.mini).tint(Palette.amber).labelsHidden()
                Text("速度矢量")
                    .font(.system(size: 9.5))
                    .foregroundColor(Palette.ink.opacity(0.8))
            }

            HStack(spacing: 9) {
                Toggle("", isOn: $sandbox.collisionsEnabled)
                    .toggleStyle(.switch).controlSize(.mini).tint(Palette.pink).labelsHidden()
                Text("碰撞合并")
                    .font(.system(size: 9.5))
                    .foregroundColor(Palette.ink.opacity(0.8))
                Spacer()
                Text("\(sandbox.bodies.count) / 64")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Palette.faint)
            }

            Button {
                sandbox.loadExample()
            } label: {
                Label("加载示例星系", systemImage: "sparkles")
                    .font(.system(size: 9))
                    .foregroundColor(Palette.amber)
                    .frame(maxWidth: .infinity)
                    .frame(height: 25)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Palette.amber.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.amber.opacity(0.22), lineWidth: 0.7))
            }
            .buttonStyle(.plain)

            Text("全对全 O(N²) · 软化为 0.02 AU · 速度单位 AU/yr")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(Palette.faint)
                .lineSpacing(2)
        }
    }
}


struct SandboxStatusPill: View {
    @ObservedObject var sandbox: GravitySandbox

    var body: some View {
        Text("\(sandbox.bodies.count) BODIES  ·  \(sandbox.running ? "RUNNING" : "PAUSED")  ·  O(N²)")
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.52))
    }
}

struct SandboxFooter: View {
    @ObservedObject var sandbox: GravitySandbox

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(Palette.blue).frame(width: 4, height: 4)
                Text("N-BODY")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(0.9)
            }
            Spacer()
            Text("\(sandbox.bodies.count) BODIES · O(N²)")
                .font(.system(size: 8, design: .monospaced))
                .tracking(0.6)
        }
        .foregroundColor(Palette.faint)
    }
}

struct SandboxCameraSummary: View {
    @ObservedObject var sandbox: GravitySandbox

    var body: some View {
        Text("N-BODY · ALL-PAIRS · \(sandbox.bodies.count) BODIES")
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.white.opacity(0.52))
    }
}
