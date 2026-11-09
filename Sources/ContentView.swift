import SwiftUI
import AppKit
import UniformTypeIdentifiers
import simd

struct ContentView: View {
    @StateObject private var state = StudioState()

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            HStack(spacing: 0) {
                if state.showSidebar {
                    SidebarView(state: state)
                        .frame(width: 322)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ViewportView(state: state)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                withAnimation(.easeOut(duration: 0.6)) {
                    state.showIntroOverlay = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleGalaxySidebar)) { _ in
            withAnimation(.easeInOut(duration: 0.28)) {
                state.showSidebar.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestGalaxyRender)) { _ in
            if !state.isBusy {
                presentRenderPanel()
            }
        }
    }

    private func presentRenderPanel() {
        let panel = NSSavePanel()
        panel.title = "渲染银河最终帧"
        panel.message = "16-bit PNG · 渐进式超采样 · 当前视角"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let sizeName: String
        switch state.finalLongEdge {
        case 7680: sizeName = "8K"
        case 5120: sizeName = "5K"
        default: sizeName = "4K"
        }
        panel.nameFieldStringValue = "MilkyWay_\(sizeName)_\(formatter.string(from: Date())).png"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                state.requestFinal(url: url)
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var state: StudioState

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 38)
                .padding(.horizontal, 22)
                .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if state.mode == .blackHole {
                        blackHoleSection
                    } else if state.mode == .solarSystem {
                        solarViewSection
                        solarSection
                    } else {
                        viewSection
                        galaxySection
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 14)
            }

            renderActionBar

            footer
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 10)
        }
        .background(
            LinearGradient(colors: [Palette.panel, Palette.background],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.line).frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            GalaxyMark(scale: 0.92)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.mode == .blackHole ? "Event Horizon" :
                     (state.mode == .solarSystem ? "Solar System" : "Milky Way"))
                    .font(.system(size: 24, weight: .light, design: .serif))
                    .foregroundColor(Palette.ink)
                Text(state.mode == .blackHole ? "SCHWARZSCHILD RAY TRACER" :
                     (state.mode == .solarSystem ? "KEPLERIAN ORRERY" : "GALACTIC VOLUME RENDERER"))
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(1.55)
                    .foregroundColor(Palette.dim)
            }
            Spacer(minLength: 0)
        }
    }

    private var viewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "VIEW", detail: "视角") {
                Button {
                    withAnimation(.easeInOut(duration: 0.5)) { state.resetCamera() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Palette.dim)
                }
                .buttonStyle(.plain)
                .help("重置视角")
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(CameraPreset.allCases) { preset in
                    PresetButton(preset: preset,
                                 isActive: isPresetActive(preset)) {
                        state.apply(preset: preset)
                    }
                }
            }
            .disabled(state.isBusy)

            VStack(spacing: 8) {
                LabeledSlider(title: "倾角",
                              value: $state.elevation,
                              range: 2...85,
                              format: { String(format: "%.0f°", $0) })
                LabeledSlider(title: "距离",
                              value: $state.distance,
                              range: 24...92,
                              format: { String(format: "%.0f kpc", $0) })
                LabeledSlider(title: "视场",
                              value: $state.fov,
                              range: 25...55,
                              format: { String(format: "%.0f°", $0) })
            }
            .disabled(state.isBusy)

            Text("拖拽画面环绕 · 滚轮缩放 · 双击重置")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Palette.faint)
        }
    }

    private var galaxySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "GALAXY", detail: "星系")

            VStack(spacing: 8) {
                LabeledSlider(title: "尘埃",
                              value: $state.dust,
                              range: 0...2,
                              format: { String(format: "%.2f×", $0) })
                LabeledSlider(title: "曝光",
                              value: $state.exposure,
                              range: -1.5...1.5,
                              format: { String(format: "%+.1f EV", $0) })
                LabeledSlider(title: "泛光",
                              value: $state.bloom,
                              range: 0...0.9,
                              format: { String(format: "%.2f", $0) })
            }
            .disabled(state.isBusy)

            HStack(spacing: 10) {
                Toggle("", isOn: $state.autoRotate)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Palette.amber)
                    .labelsHidden()
                Text("密度波自转")
                    .font(.system(size: 11.5))
                    .foregroundColor(Palette.ink)
                Spacer()
                Text(state.autoRotate ? "RUNNING" : "PAUSED")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(state.autoRotate ? Palette.amber : Palette.faint)
            }
            .disabled(state.isBusy)

            LabeledSlider(title: "速度",
                          value: $state.rotationSpeed,
                          range: 0.5...20,
                          format: { String(format: "%.1f Myr/s", $0) })
                .disabled(state.isBusy || !state.autoRotate)

            HStack(spacing: 8) {
                Toggle("", isOn: $state.shearEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Palette.blue)
                    .labelsHidden()
                Text("物理较差自转")
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.ink.opacity(0.85))
                Spacer()
                Text("Ω(r)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Palette.faint)
            }
            .disabled(state.isBusy)

            RotationCurveView()

            HStack(spacing: 9) {
                Toggle("", isOn: $state.starLayerEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Palette.amber)
                    .labelsHidden()
                Text("星粒子 120k")
                    .font(.system(size: 9.5))
                    .foregroundColor(Palette.ink.opacity(0.8))
                Spacer(minLength: 4)
                Toggle("", isOn: $state.dustHighEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Palette.blue)
                    .labelsHidden()
                Text("高清尘埃")
                    .font(.system(size: 9.5))
                    .foregroundColor(Palette.ink.opacity(0.8))
            }
            .disabled(state.isBusy)

            HStack(spacing: 9) {
                Toggle("", isOn: Binding(
                    get: { state.starDynamicsEnabled },
                    set: { value in
                        state.starDynamicsEnabled = value
                        if value { state.resetEvolution() }
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Palette.pink)
                    .labelsHidden()
                Text("N-body 恒星动力学")
                    .font(.system(size: 9.5))
                    .foregroundColor(Palette.ink.opacity(0.8))
                Spacer(minLength: 4)
                Text("受限引力")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Palette.faint)
            }
            .disabled(state.isBusy)

            HStack {
                Text("演化")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Palette.faint)
                Text(String(format: "%04.0f Myr", state.simulationTime))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Palette.ink.opacity(0.7))
                Spacer()
                Button {
                    state.resetEvolution()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 7.5, weight: .semibold))
                        Text("复位")
                            .font(.system(size: 8.5))
                    }
                    .foregroundColor(Palette.dim)
                }
                .buttonStyle(.plain)
                .disabled(state.isBusy)
            }

            HStack(spacing: 5) {
                Image(systemName: "atom")
                    .font(.system(size: 9))
                Text("vflat 220 km/s · Ωp 24 km/s/kpc")
                    .font(.system(size: 8.5, design: .monospaced))
            }
            .foregroundColor(Palette.faint)
        }
    }

    private var solarViewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "VIEW", detail: "视角") {
                Button {
                    withAnimation(.easeInOut(duration: 0.5)) { state.resetCamera() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Palette.dim)
                }
                .buttonStyle(.plain)
                .help("重置视角")
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(SolarPreset.allCases) { preset in
                    SolarPresetButton(preset: preset,
                                      isActive: isSolarPresetActive(preset)) {
                        state.applySolarPreset(preset)
                    }
                }
            }
            .disabled(state.isBusy)

            VStack(spacing: 8) {
                LabeledSlider(title: "倾角",
                              value: $state.elevation,
                              range: 2...85,
                              format: { String(format: "%.0f°", $0) })
                LabeledSlider(title: "距离",
                              value: $state.distance,
                              range: 0.05...50,
                              format: { String(format: "%.2f AU", $0) })
                LabeledSlider(title: "视场",
                              value: $state.fov,
                              range: 25...60,
                              format: { String(format: "%.0f°", $0) })
            }
            .disabled(state.isBusy)

            Text("点击行星聚焦 · 拖拽环绕 · 滚轮缩放 · ESC 返回全景")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundColor(Palette.faint)
        }
    }

    private var solarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "SOLAR SYSTEM", detail: "太阳系")

            if state.solarFocus >= 0 {
                HStack(spacing: 7) {
                    Text("聚焦")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Palette.faint)
                    Text(state.solarFocusLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Palette.amber)
                    Spacer()
                    Button("返回全景") {
                        withAnimation(.easeInOut(duration: 0.55)) {
                            state.clearSolarFocus()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundColor(Palette.dim)
                }
            }

            HStack(spacing: 10) {
                Toggle("", isOn: $state.autoRotate)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Palette.amber)
                    .labelsHidden()
                Text("公转演化")
                    .font(.system(size: 11.5))
                    .foregroundColor(Palette.ink)
                Spacer()
                Text(state.autoRotate ? "RUNNING" : "PAUSED")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(state.autoRotate ? Palette.amber : Palette.faint)
            }
            .disabled(state.isBusy)

            LabeledSlider(title: "速度",
                          value: $state.rotationSpeed,
                          range: 1...365,
                          format: { String(format: "%.0f 天/s", $0) })
                .disabled(state.isBusy || !state.autoRotate)

            LabeledSlider(title: "行星尺寸",
                          value: $state.solarPlanetScale,
                          range: 0.5...2.5,
                          format: { String(format: "%.1f×", $0) })
                .disabled(state.isBusy)

            HStack(spacing: 9) {
                Toggle("", isOn: $state.solarOrbitLines)
                    .toggleStyle(.switch).controlSize(.mini).tint(Palette.blue).labelsHidden()
                Text("轨道线")
                    .font(.system(size: 9.5))
                    .foregroundColor(Palette.ink.opacity(0.8))
                Spacer(minLength: 4)
                Toggle("", isOn: $state.solarBelts)
                    .toggleStyle(.switch).controlSize(.mini).tint(Palette.amber).labelsHidden()
                Text("小行星带")
                    .font(.system(size: 9.5))
                    .foregroundColor(Palette.ink.opacity(0.8))
            }
            .disabled(state.isBusy)

            HStack(spacing: 9) {
                Toggle("", isOn: $state.solarMoons)
                    .toggleStyle(.switch).controlSize(.mini).tint(Palette.pink).labelsHidden()
                Text("主要卫星")
                    .font(.system(size: 9.5))
                    .foregroundColor(Palette.ink.opacity(0.8))
                Spacer()
                Text("月球 · 伽利略 · 泰坦")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Palette.faint)
            }
            .disabled(state.isBusy)

            VStack(spacing: 8) {
                LabeledSlider(title: "曝光",
                              value: $state.solarExposure,
                              range: -2...2,
                              format: { String(format: "%+.1f EV", $0) })
                LabeledSlider(title: "泛光",
                              value: $state.solarBloom,
                              range: 0...0.9,
                              format: { String(format: "%.2f", $0) })
            }
            .disabled(state.isBusy)

            HStack {
                Text("历元")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Palette.faint)
                Text("J2000 + " + SolarSystem.timeLabel(days: state.simulationTime))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Palette.ink.opacity(0.7))
                Spacer()
                Button {
                    state.resetEvolution()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 7.5, weight: .semibold))
                        Text("复位")
                            .font(.system(size: 8.5))
                    }
                    .foregroundColor(Palette.dim)
                }
                .buttonStyle(.plain)
                .disabled(state.isBusy)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("开普勒二体 · 真实 J2000 轨道根数")
                Text("行星半径已放大以便观察 · 卫星轨道为示意")
            }
            .font(.system(size: 8.2, design: .monospaced))
            .foregroundColor(Palette.faint)
            .lineSpacing(2)
        }
    }

    private func isSolarPresetActive(_ preset: SolarPreset) -> Bool {
        let v = preset.values
        return abs(state.elevation - v.elevation) < 1.0 &&
               abs(state.distance - v.distance) < 0.5 &&
               abs(state.fov - v.fov) < 1.0
    }

    private var blackHoleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "BLACK HOLE", detail: "黑洞")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(BHPreset.allCases) { preset in
                    BHPresetButton(preset: preset) {
                        state.applyBlackHolePreset(preset)
                    }
                }
            }
            .disabled(state.isBusy)

            VStack(spacing: 8) {
                LabeledSlider(title: "倾角",
                              value: $state.elevation,
                              range: 1...82,
                              format: { String(format: "%.0f°", $0) })
                LabeledSlider(title: "距离",
                              value: $state.distance,
                              range: 8...48,
                              format: { String(format: "%.0f Rs", $0) })
                LabeledSlider(title: "视场",
                              value: $state.fov,
                              range: 20...60,
                              format: { String(format: "%.0f°", $0) })
            }
            .disabled(state.isBusy)

            SectionHeader(title: "ACCRETION", detail: "吸积盘")

            VStack(spacing: 8) {
                LabeledSlider(title: "温度",
                              value: $state.bhTemp,
                              range: 3000...30000,
                              format: { String(format: "%.0f K", $0) })
                LabeledSlider(title: "亮度",
                              value: $state.bhBrightness,
                              range: 0.05...2.0,
                              format: { String(format: "%.2f×", $0) })
                LabeledSlider(title: "外半径",
                              value: $state.bhDiskOuter,
                              range: 6...20,
                              format: { String(format: "%.0f Rs", $0) })
                LabeledSlider(title: "盘厚度",
                              value: $state.bhThickness,
                              range: 0.05...1.5,
                              format: { String(format: "%.2f×", $0) })
                LabeledSlider(title: "曝光",
                              value: $state.bhExposure,
                              range: -4...1,
                              format: { String(format: "%+.1f EV", $0) })
                LabeledSlider(title: "泛光",
                              value: $state.bhBloom,
                              range: 0...0.9,
                              format: { String(format: "%.2f", $0) })
                LabeledSlider(title: "柔焦",
                              value: $state.bhSoftness,
                              range: 0...6,
                              format: { String(format: "%.1f px", $0) })
            }
            .disabled(state.isBusy)

            HStack(spacing: 9) {
                Toggle("", isOn: $state.bhDoppler)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Palette.amber)
                    .labelsHidden()
                Text("相对论多普勒")
                    .font(.system(size: 9.5))
                    .foregroundColor(Palette.ink.opacity(0.8))
                Spacer()
                Toggle("", isOn: $state.bhJets)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Palette.blue)
                    .labelsHidden()
                Text("喷流")
                    .font(.system(size: 9.5))
                    .foregroundColor(Palette.ink.opacity(0.8))
            }
            .disabled(state.isBusy)

            HStack(spacing: 9) {
                Toggle("", isOn: $state.autoRotate)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Palette.amber)
                    .labelsHidden()
                Text("吸积盘旋转")
                    .font(.system(size: 9.5))
                    .foregroundColor(Palette.ink.opacity(0.8))
                Spacer()
                Text(state.autoRotate ? "RUNNING" : "PAUSED")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(state.autoRotate ? Palette.amber : Palette.faint)
            }
            .disabled(state.isBusy)

            VStack(alignment: .leading, spacing: 4) {
                Text("Schwarzschild · 非旋转 · ISCO = 3 Rs")
                Text("零测地线追踪 · 引力红移 · 多普勒 beaming")
            }
            .font(.system(size: 8.2, design: .monospaced))
            .foregroundColor(Palette.faint)
            .lineSpacing(2)
        }
    }

    private var renderSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "RENDER", detail: "渲染")

            Text("预览质量")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Palette.faint)

            SegmentedChoice(
                options: PreviewQuality.allCases,
                selection: $state.previewQuality,
                label: { $0.label }
            )
            .disabled(state.isBusy)

            VStack(spacing: 7) {
                ValueMenu(title: "长边",
                          value: resolutionTitle,
                          disabled: state.isBusy) {
                    ForEach([3840, 5120, 7680], id: \.self) { v in
                        Button(resolutionOptionTitle(v)) { state.finalLongEdge = v }
                    }
                }
                ValueMenu(title: "采样",
                          value: sampleTitle,
                          disabled: state.isBusy) {
                    ForEach([64, 128, 256], id: \.self) { v in
                        Button(sampleOptionTitle(v)) { state.finalSamples = v }
                    }
                }
            }

            Text("16-bit · 当前视角 · 渐进超采样")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundColor(Palette.faint)
        }
    }

    private var renderActionBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                CompactMenu(label: "预览", value: state.previewQuality.label) {
                    ForEach(PreviewQuality.allCases) { q in
                        Button(q.label) { state.previewQuality = q }
                    }
                }
                CompactMenu(label: "长边", value: shortResolutionTitle) {
                    ForEach([3840, 5120, 7680], id: \.self) { v in
                        Button(resolutionOptionTitle(v)) { state.finalLongEdge = v }
                    }
                }
                CompactMenu(label: "采样", value: shortSampleTitle) {
                    ForEach([64, 128, 256], id: \.self) { v in
                        Button(sampleOptionTitle(v)) { state.finalSamples = v }
                    }
                }
                Spacer(minLength: 0)
            }
            .disabled(state.isBusy)

            Button {
                NotificationCenter.default.post(name: .requestGalaxyRender, object: nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: state.phase == .done ? "arrow.triangle.2.circlepath" : "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                    Text(state.isBusy ? (state.phase == .saving ? "正在写入图像" : "正在渲染") :
                            (state.phase == .done ? "再次渲染" : "渲染最终帧"))
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    if state.isBusy {
                        Button {
                            state.cancelFinal()
                        } label: {
                            Text("取消")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(Palette.ink.opacity(0.65))
                                .padding(.horizontal, 7)
                                .frame(height: 22)
                                .background(Capsule().fill(.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("⌘R")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .opacity(0.55)
                    }
                }
                .foregroundColor(state.isBusy ? Palette.ink : Color(red: 0.10, green: 0.07, blue: 0.03))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(
                    Group {
                        if state.isBusy {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Palette.panelRaised)
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
                        } else {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(LinearGradient(colors: [Palette.amber, Palette.amberDeep],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
                )
            }
            .buttonStyle(.plain)
            .disabled(state.isBusy)

            if state.isBusy {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(state.phase == .saving ? "写入 16-bit PNG" : "渐进采样")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(Palette.dim)
                        Spacer()
                        Text(state.phase == .saving ? "" : "\(Int(state.renderProgress * 100))%")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(Palette.amber)
                    }
                    CustomProgressBar(value: state.phase == .saving ? 1 : state.renderProgress,
                                      indeterminate: state.phase == .saving)
                    if state.phase == .rendering {
                        Text("\(state.renderSamplesDone) / \(state.renderSamplesTarget) spp  ·  \(timeString(state.renderElapsed))")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(Palette.faint)
                    }
                }
            } else if let url = state.savedURL, state.phase == .done {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(red: 0.45, green: 0.78, blue: 0.55))
                        .font(.system(size: 11))
                    Text(url.lastPathComponent)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundColor(Palette.dim)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Palette.amber)
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 9)
        .padding(.bottom, 5)
        .background(
            LinearGradient(colors: [Palette.panel.opacity(0.96), Palette.background],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.line).frame(height: 1)
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.isReady ? Color(red: 0.45, green: 0.78, blue: 0.55) : Palette.amber)
                    .frame(width: 4, height: 4)
                Text(state.isReady ? "METAL 4" : "BUILDING")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(0.9)
            }
            Spacer()
            Text("640³ VOLUME")
                .font(.system(size: 8, design: .monospaced))
                .tracking(0.6)
        }
        .foregroundColor(Palette.faint)
    }

    private var resolutionTitle: String {
        switch state.finalLongEdge {
        case 7680: return "8K · 7680 px"
        case 5120: return "5K · 5120 px"
        default: return "4K · 3840 px"
        }
    }

    private func resolutionOptionTitle(_ value: Int) -> String {
        switch value {
        case 7680: return "8K · 7680 px"
        case 5120: return "5K · 5120 px"
        default: return "4K · 3840 px"
        }
    }

    private var shortResolutionTitle: String {
        switch state.finalLongEdge {
        case 7680: return "8K"
        case 5120: return "5K"
        default: return "4K"
        }
    }

    private var shortSampleTitle: String {
        "\(state.finalSamples) spp"
    }

    private var sampleTitle: String {
        switch state.finalSamples {
        case 256: return "256 spp · 画廊"
        case 128: return "128 spp · 推荐"
        default: return "64 spp · 快速"
        }
    }

    private func sampleOptionTitle(_ value: Int) -> String {
        switch value {
        case 256: return "256 spp · 画廊"
        case 128: return "128 spp · 推荐"
        default: return "64 spp · 快速"
        }
    }

    private func isPresetActive(_ preset: CameraPreset) -> Bool {
        let v = preset.values
        return abs(state.elevation - v.elevation) < 1.0 &&
               abs(state.distance - v.distance) < 1.5 &&
               abs(state.fov - v.fov) < 1.0
    }

    private func timeString(_ t: Double) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Solar labels

private struct SolarLabelItem: Identifiable {
    let id: Int
    let text: String
    let color: Color
    let center: CGPoint
    let anchor: CGPoint
    let lineEnd: CGPoint
}

struct SolarLabelsOverlay: View {
    @ObservedObject var state: StudioState

    var body: some View {
        GeometryReader { geo in
            let items = makeItems(size: geo.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for item in items {
                        var path = Path()
                        path.move(to: item.anchor)
                        path.addLine(to: item.lineEnd)
                        context.stroke(path, with: .color(.white.opacity(0.16)), lineWidth: 0.6)
                    }
                }
                .allowsHitTesting(false)

                ForEach(items) { item in
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 3, height: 3)
                        Text(item.text)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.72))
                            .fixedSize()
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.28)))
                    .overlay(Capsule().stroke(.white.opacity(0.06), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.8), radius: 2)
                    .position(item.center)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func makeItems(size: CGSize) -> [SolarLabelItem] {
        let w = size.width
        let h = size.height
        guard w > 10, h > 10 else { return [] }
        let aspect = max(0.2, Double(w / h))
        var settings = state.renderSettings
        settings.time = state.simulationTime
        let camera = CameraBasis.make(settings: settings, aspect: aspect)
        let bodies = SolarSystem.renderPlanets(days: state.simulationTime,
                                               scale: state.solarPlanetScale)

        struct Projected {
            let index: Int
            let screen: CGPoint
            let radius: CGFloat
            let color: Color
        }

        func project(_ p: SIMD4<Float>, index: Int) -> Projected? {
            let d = SIMD3<Float>(p.x, p.y, p.z) - camera.position
            let depth = Double(simd_dot(d, camera.forward))
            guard depth > 0.05 else { return nil }
            let nx = Double(simd_dot(d, camera.right)) /
                     (depth * Double(camera.tanHalfFov) * aspect)
            let ny = Double(simd_dot(d, camera.up)) /
                     (depth * Double(camera.tanHalfFov))
            let sx = (nx * 0.5 + 0.5) * w
            let sy = (0.5 - ny * 0.5) * h
            guard sx > -42, sx < w + 42, sy > -42, sy < h + 42 else { return nil }
            let radius = CGFloat(Double(p.w) /
                                 (depth * Double(camera.tanHalfFov)) * h * 0.5)
            let c = bodies[index].color
            return Projected(index: index,
                             screen: CGPoint(x: sx, y: sy),
                             radius: max(1.5, radius),
                             color: Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)))
        }

        var projected: [Projected] = []
        for i in 0..<min(9, bodies.count) {
            if state.solarFocus > 0 && i != state.solarFocus - 1 { continue }
            let p = bodies[i].posRadius
            if let item = project(SIMD4<Float>(p.x, p.y, p.z, p.w), index: i) {
                projected.append(item)
            }
        }

        // Sun disk, used to keep labels away from the solar surface as well.
        let sunDisk: (CGPoint, CGFloat)? = {
            let d = SIMD3<Float>(0, 0, 0) - camera.position
            let depth = Double(simd_dot(d, camera.forward))
            guard depth > 0.05 else { return nil }
            let nx = Double(simd_dot(d, camera.right)) /
                     (depth * Double(camera.tanHalfFov) * aspect)
            let ny = Double(simd_dot(d, camera.up)) /
                     (depth * Double(camera.tanHalfFov))
            let sx = (nx * 0.5 + 0.5) * w
            let sy = (0.5 - ny * 0.5) * h
            let radius = CGFloat(Double(SolarSystem.sunVisualRadius) /
                                 (depth * Double(camera.tanHalfFov)) * h * 0.5)
            return (CGPoint(x: sx, y: sy), max(2, radius))
        }()

        func intersectsCircle(_ rect: CGRect, center: CGPoint, radius: CGFloat) -> Bool {
            let nx = min(max(center.x, rect.minX), rect.maxX)
            let ny = min(max(center.y, rect.minY), rect.maxY)
            return hypot(center.x - nx, center.y - ny) < radius + 3
        }

        var occupied: [CGRect] = []
        var items: [SolarLabelItem] = []

        for (order, body) in projected.enumerated() {
            let text = SolarSystem.names[body.index]
            let estimatedWidth = CGFloat(text.count) * 9.5 + 18
            let halfW = estimatedWidth * 0.5
            let labelHalfH: CGFloat = 8
            let gap: CGFloat = 12

            let rightFits = body.screen.x + body.radius + gap + estimatedWidth + 8 < w
            let side: CGFloat = rightFits ? 1 : -1
            var cx = body.screen.x + side * (body.radius + gap + halfW)
            var cy = body.screen.y - 4

            // Keep the label inside the viewport.
            cx = min(max(cx, halfW + 6), w - halfW - 6)
            cy = min(max(cy, labelHalfH + 6), h - labelHalfH - 6)

            let verticalOffsets: [CGFloat] = [0, -18, 18, -36, 36, -54, 54, -72, 72]
            var chosen = CGRect(x: cx - halfW, y: cy - labelHalfH,
                                width: estimatedWidth, height: labelHalfH * 2)
            for dy in verticalOffsets {
                let candidateY = min(max(cy + dy, labelHalfH + 6), h - labelHalfH - 6)
                let candidate = CGRect(x: cx - halfW, y: candidateY - labelHalfH,
                                       width: estimatedWidth, height: labelHalfH * 2)
                var bad = false
                for other in projected where other.index != body.index {
                    if intersectsCircle(candidate, center: other.screen, radius: other.radius) {
                        bad = true
                        break
                    }
                }
                if !bad, let sunDisk, intersectsCircle(candidate, center: sunDisk.0, radius: sunDisk.1) {
                    bad = true
                }
                if !bad {
                    for rect in occupied where rect.intersects(candidate) {
                        bad = true
                        break
                    }
                }
                if !bad {
                    chosen = candidate
                    cy = candidateY
                    break
                }
            }
            occupied.append(chosen.insetBy(dx: -2, dy: -2))

            // Leader line from the planet's limb to the nearest label edge.
            let dirX = cx - body.screen.x
            let dirY = cy - body.screen.y
            let len = max(1.0, hypot(dirX, dirY))
            let ux = dirX / len
            let uy = dirY / len
            let anchor = CGPoint(x: body.screen.x + ux * (body.radius + 1.5),
                                 y: body.screen.y + uy * (body.radius + 1.5))
            let lineEnd = CGPoint(x: cx - ux * (halfW + 1),
                                  y: cy - uy * (labelHalfH + 1))
            items.append(SolarLabelItem(id: body.index,
                                        text: text,
                                        color: body.color,
                                        center: CGPoint(x: cx, y: cy),
                                        anchor: anchor,
                                        lineEnd: lineEnd))
            _ = order
        }
        return items
    }
}

// MARK: - Viewport

struct ViewportView: View {
    @ObservedObject var state: StudioState

    var body: some View {
        ZStack {
            Color.black

            MetalViewport(state: state)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

            if state.mode == .solarSystem {
                SolarLabelsOverlay(state: state)
                    .allowsHitTesting(false)

                if state.solarFocus >= 0 {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.easeInOut(duration: 0.55)) {
                                    state.clearSolarFocus()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 8, weight: .semibold))
                                    Text("\(state.solarFocusLabel) · 返回全景")
                                        .font(.system(size: 9.5, weight: .medium))
                                    Text("ESC")
                                        .font(.system(size: 7.5, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.35))
                                }
                                .foregroundColor(.white.opacity(0.82))
                                .padding(.horizontal, 11)
                                .frame(height: 27)
                                .background(Capsule().fill(.black.opacity(0.46)))
                                .overlay(Capsule().stroke(.white.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        .padding(.top, 88)
                        Spacer()
                    }
                    .allowsHitTesting(true)
                }
            }

            LinearGradient(colors: [.black.opacity(0.48), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 138)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

            LinearGradient(colors: [.clear, .black.opacity(0.42)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            ModePill(title: "MILKY WAY", active: state.mode == .galaxy) {
                                state.switchMode(.galaxy)
                            }
                            ModePill(title: "BLACK HOLE", active: state.mode == .blackHole) {
                                state.switchMode(.blackHole)
                            }
                            ModePill(title: "SOLAR SYSTEM", active: state.mode == .solarSystem) {
                                state.switchMode(.solarSystem)
                            }
                        }
                        HStack(spacing: 7) {
                            Circle().fill(Palette.amber).frame(width: 4, height: 4)
                            Text(state.mode == .blackHole ? "EVENT HORIZON" :
                                 (state.mode == .solarSystem ? "HELIOCENTRIC" : "MILKY WAY"))
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .tracking(2.2)
                                .foregroundColor(Palette.ink.opacity(0.86))
                        }
                        .padding(.top, 2)
                        Text(state.mode == .blackHole ?
                             "SCHWARZSCHILD  /  ACCRETION DISK" :
                             (state.mode == .solarSystem ?
                              "J2000  /  KEPLERIAN PLANETARY ORBITS" :
                              "M-01  /  DENSITY-WAVE BARRED SPIRAL"))
                            .font(.system(size: 8, design: .monospaced))
                            .tracking(1.1)
                            .foregroundColor(.white.opacity(0.38))
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        HeaderIconButton(systemName: "sidebar.left") {
                            withAnimation(.easeInOut(duration: 0.28)) { state.showSidebar.toggle() }
                        }
                        HeaderIconButton(systemName: "arrow.up.left.and.arrow.down.right") {
                            NSApp.keyWindow?.toggleFullScreen(nil)
                        }
                    }
                }
                .padding(.top, 42)
                .padding(.horizontal, 24)

                Spacer()

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.cameraSummary)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.52))
                        Text("DRAG TO ORBIT   ·   SCROLL TO ZOOM   ·   SPACE TO PAUSE")
                            .font(.system(size: 7.5, design: .monospaced))
                            .tracking(0.9)
                            .foregroundColor(.white.opacity(0.25))
                    }
                    Spacer()
                    statusPill
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }

            if !state.isReady {
                loadingOverlay
            }

            if state.showIntroOverlay && state.mode == .galaxy && state.isReady && !state.isBusy {
                introOverlay
                    .transition(.opacity)
            }

            if state.isBusy {
                VStack {
                    Spacer()
                    renderOverlay
                        .padding(.bottom, 74)
                }
                .allowsHitTesting(false)
            }

            if let message = state.errorMessage {
                VStack {
                    errorBanner(message)
                        .padding(.top, 92)
                    Spacer()
                }
            }

            if let url = state.savedURL, state.phase == .done, !state.isBusy {
                VStack {
                    Spacer()
                    savedToast(url)
                        .padding(.bottom, 70)
                }
            }
        }
        .padding(14)
        .background(Palette.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.isBusy ? Palette.amber : Color(red: 0.46, green: 0.78, blue: 0.56))
                .frame(width: 4, height: 4)
            if state.isBusy {
                Text(state.phase == .saving ? "WRITING PNG" :
                        "RENDERING  \(Int(state.renderProgress * 100))%")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(0.9)
                    .foregroundColor(.white.opacity(0.72))
            } else {
                Text("LIVE  \(Int(state.previewFPS)) FPS  ·  \(state.previewWidth)×\(state.previewHeight)  ·  \(state.previewSamples) spp")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.52))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(.black.opacity(0.34)))
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.7))
    }

    private var renderOverlay: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Palette.amber)
                Text(state.phase == .saving ? "正在写入 16-bit PNG…" :
                        "正在生成 \(state.renderSamplesTarget) spp 最终帧")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                Text("\(Int(state.renderProgress * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Palette.amber)
            }
            .padding(.horizontal, 16)
            .frame(height: 39)
            .background(Capsule().fill(.black.opacity(0.58)))
            .overlay(Capsule().stroke(.white.opacity(0.11), lineWidth: 0.7))
            Text("\(state.finalWidth) × \(state.finalHeight)  ·  \(state.renderSamplesDone)/\(state.renderSamplesTarget) spp")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
        }
    }

    private var introOverlay: some View {
        VStack(spacing: 13) {
            GalaxyMark(scale: 1.15)
                .opacity(0.9)
            VStack(spacing: 5) {
                Text("Milky Way Studio")
                    .font(.system(size: 20, weight: .light, design: .serif))
                    .foregroundColor(Palette.ink)
                Text("空格开始自转  ·  拖拽环绕  ·  滚轮缩放")
                    .font(.system(size: 9.5, design: .monospaced))
                    .tracking(0.7)
                    .foregroundColor(.white.opacity(0.42))
            }
        }
        .frame(maxWidth: 300)
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.10)))
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.35)) { state.showIntroOverlay = false }
        }
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Palette.amber)
            Text("正在构建 640³ 银河体数据…")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Palette.pink)
            Text(message)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(2)
            Button {
                state.errorMessage = nil
                if state.phase == .failed { state.phase = .idle }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.58)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.pink.opacity(0.25)))
    }

    private func savedToast(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(Color(red: 0.46, green: 0.78, blue: 0.56))
            VStack(alignment: .leading, spacing: 2) {
                Text("16-bit PNG 已保存")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Palette.ink)
                Text("\(state.finalWidth) × \(state.finalHeight)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .buttonStyle(.plain)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundColor(Palette.amber)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.62)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.10)))
    }
}

// MARK: - Rotation curve

struct RotationCurveView: View {
    private let rMax = 20.0

    private func v(_ r: Double) -> Double {
        AstroModel.circularSpeed(r)
    }

    private func omega(_ r: Double) -> Double {
        AstroModel.angularSpeed(r) / AstroModel.kmPerSecToKpcPerMyr
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let w = size.width
                let h = size.height
                let pad: CGFloat = 2
                let usableW = w - pad * 2
                let usableH = h - pad * 2
                let omega0 = omega(0.2)

                // Grid
                for i in 0...4 {
                    let y = pad + usableH * CGFloat(i) / 4
                    var line = Path()
                    line.move(to: CGPoint(x: pad, y: y))
                    line.addLine(to: CGPoint(x: w - pad, y: y))
                    context.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                }

                // v(r), normalised to 220 km/s
                var vPath = Path()
                for i in 0...100 {
                    let r = rMax * Double(i) / 100.0
                    let x = pad + usableW * CGFloat(r / rMax)
                    let y = pad + usableH * (1.0 - CGFloat(v(r) / 220.0) * 0.92)
                    if i == 0 { vPath.move(to: CGPoint(x: x, y: y)) }
                    else { vPath.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(vPath, with: .color(Palette.blue.opacity(0.85)), lineWidth: 1.1)

                // Ω(r), normalised to the central value
                var oPath = Path()
                for i in 0...120 {
                    let r = 0.2 + (rMax - 0.2) * Double(i) / 120.0
                    let x = pad + usableW * CGFloat(r / rMax)
                    let y = pad + usableH * (1.0 - CGFloat(omega(r) / omega0) * 0.96)
                    if i == 0 { oPath.move(to: CGPoint(x: x, y: y)) }
                    else { oPath.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(oPath, with: .color(Palette.amber.opacity(0.9)), lineWidth: 1.1)

                // Corotation marker where Ω(r) crosses the 24 km/s/kpc pattern speed.
                let corotation = AstroModel.corotationRadius() / rMax
                let cx = pad + usableW * CGFloat(corotation)
                var dot = Path()
                dot.addEllipse(in: CGRect(x: cx - 1.7, y: pad + usableH * 0.24 - 1.7,
                                          width: 3.4, height: 3.4))
                context.fill(dot, with: .color(.white.opacity(0.75)))
            }
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.16)))

            HStack(spacing: 10) {
                LegendDot(color: Palette.blue, text: "v(r)")
                LegendDot(color: Palette.amber, text: "Ω(r)")
                Spacer()
                Text(String(format: "共转 %.1f kpc", AstroModel.corotationRadius()))
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundColor(Palette.faint)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.018)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line.opacity(0.8), lineWidth: 0.7))
    }
}

struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(text)
                .font(.system(size: 7.5, design: .monospaced))
                .foregroundColor(Palette.dim)
        }
    }
}

// MARK: - Reusable components


struct GalaxyMark: View {
    var scale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Palette.amber, Palette.amberDeep.opacity(0.7), .clear],
                                     center: .center, startRadius: 1, endRadius: 17 * scale))
                .frame(width: 34 * scale, height: 34 * scale)
                .blur(radius: 2.5 * scale)
            Ellipse()
                .stroke(LinearGradient(colors: [.clear, .white.opacity(0.65), .clear],
                                       startPoint: .leading, endPoint: .trailing),
                        lineWidth: 0.8)
                .frame(width: 30 * scale, height: 11 * scale)
                .rotationEffect(.degrees(-24))
            Ellipse()
                .stroke(Palette.blue.opacity(0.5), lineWidth: 0.7)
                .frame(width: 24 * scale, height: 7 * scale)
                .rotationEffect(.degrees(-24))
            Circle()
                .fill(.white)
                .frame(width: 4.2 * scale, height: 4.2 * scale)
                .blur(radius: 0.6)
        }
        .frame(width: 34 * scale, height: 34 * scale)
    }
}

struct SectionHeader<Accessory: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, detail: String, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.detail = detail
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(1.8)
                .foregroundColor(Palette.amber.opacity(0.9))
            Text(detail)
                .font(.system(size: 9))
                .foregroundColor(Palette.faint)
            Spacer()
            accessory()
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.line)
                .frame(height: 1)
                .offset(y: 7)
        }
        .padding(.bottom, 4)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, detail: String) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

struct SolarPresetButton: View {
    let preset: SolarPreset
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isActive ? Palette.ink : Palette.ink.opacity(0.78))
                Text(preset.subtitle)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(isActive ? Palette.amber.opacity(0.8) : Palette.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? Palette.panelRaised : Color.white.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isActive ? Palette.amber.opacity(0.38) : Palette.line,
                            lineWidth: isActive ? 0.9 : 0.7)
            )
        }
        .buttonStyle(.plain)
    }
}

struct PresetButton: View {
    let preset: CameraPreset
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isActive ? Palette.ink : Palette.ink.opacity(0.78))
                Text(preset.subtitle)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(isActive ? Palette.amber.opacity(0.8) : Palette.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? Palette.panelRaised : Color.white.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isActive ? Palette.amber.opacity(0.38) : Palette.line,
                            lineWidth: isActive ? 0.9 : 0.7)
            )
        }
        .buttonStyle(.plain)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.dim)
                Spacer()
                Text(format(value))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Palette.ink.opacity(0.72))
            }
            Slider(value: $value, in: range)
                .tint(Palette.amber)
                .controlSize(.mini)
        }
    }
}

struct SegmentedChoice<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(selection == option ? Palette.ink : Palette.faint)
                        .frame(maxWidth: .infinity)
                        .frame(height: 25)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selection == option ? Palette.panelRaised : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.black.opacity(0.24)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line, lineWidth: 0.7))
    }
}

struct ValueMenu<Content: View>: View {
    let title: String
    let value: String
    let disabled: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundColor(Palette.dim)
            Spacer()
            Menu {
                content()
            } label: {
                HStack(spacing: 5) {
                    Text(value)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Palette.ink.opacity(0.8))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(Palette.faint)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(disabled)
        }
        .frame(height: 22)
    }
}

struct CompactMenu<Content: View>: View {
    let label: String
    let value: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text("\(label)  \(value)")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.ink.opacity(0.8))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.0, weight: .semibold))
                    .foregroundColor(Palette.faint)
            }
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(Capsule().fill(.black.opacity(0.22)))
            .overlay(Capsule().stroke(Palette.line, lineWidth: 0.7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct BHPresetButton: View {
    let preset: BHPreset
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Palette.ink.opacity(0.86))
                Text(preset.subtitle)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Palette.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.025)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }
}

struct ModePill: View {
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(active ? Color(red: 0.10, green: 0.07, blue: 0.03) : .white.opacity(0.42))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    Capsule().fill(active ? Palette.amber : Color.black.opacity(0.28))
                )
                .overlay(Capsule().stroke(.white.opacity(active ? 0.0 : 0.12), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }
}

struct HeaderIconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.white.opacity(0.62))
                .frame(width: 29, height: 29)
                .background(Circle().fill(.black.opacity(0.30)))
                .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
    }
}

struct CustomProgressBar: View {
    let value: Double
    var indeterminate: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07))
                if indeterminate {
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.amber.opacity(0.2), Palette.amber, Palette.amber.opacity(0.2)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * 0.35)
                } else {
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.amberDeep, Palette.amber],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geo.size.width * min(max(value, 0), 1)))
                }
            }
        }
        .frame(height: 3)
    }
}
