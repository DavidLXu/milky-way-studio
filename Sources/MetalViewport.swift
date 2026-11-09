import SwiftUI
import MetalKit
import AppKit
import QuartzCore

final class GalaxyMTKView: MTKView {
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onResetCamera: (() -> Void)?
    var onToggleRotate: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onPick: ((CGPoint, CGSize) -> Void)?
    var onEscape: (() -> Void)?

    private var lastPoint: NSPoint = .zero
    private var dragged = false
    private var clickCount = 0

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastPoint = event.locationInWindow
        dragged = false
        clickCount = event.clickCount
        if event.clickCount == 2 {
            onResetCamera?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        let dx = p.x - lastPoint.x
        let dy = p.y - lastPoint.y
        lastPoint = p
        if abs(dx) + abs(dy) > 0.4 {
            dragged = true
            onOrbit?(dx, dy)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged && clickCount == 1 {
            let p = convert(event.locationInWindow, from: nil)
            // AppKit view coordinates are bottom-left; the camera/pick code
            // uses top-left screen coordinates.
            onPick?(CGPoint(x: p.x, y: bounds.height - p.y), bounds.size)
        }
        clickCount = 0
        dragged = false
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        if abs(delta) > 0.001 {
            onZoom?(delta)
        }
    }

    override func magnify(with event: NSEvent) {
        onZoom?(event.magnification * 500.0)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // space
            onToggleRotate?()
            return
        }
        if event.keyCode == 48 { // tab
            onToggleSidebar?()
            return
        }
        if event.keyCode == 53 { // esc
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

struct MetalViewport: NSViewRepresentable {
    @ObservedObject var state: StudioState

    final class Coordinator {
        var renderer: GalaxyRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let device = MTLCreateSystemDefaultDevice()
        let view = GalaxyMTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.wantsLayer = true
        view.layer?.isOpaque = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }

        view.onOrbit = { [weak state] dx, dy in
            guard let state, !state.isBusy else { return }
            state.orbit(dx: dx, dy: dy)
        }
        view.onZoom = { [weak state] delta in
            guard let state, !state.isBusy else { return }
            state.zoom(delta: delta)
        }
        view.onResetCamera = { [weak state] in
            guard let state, !state.isBusy else { return }
            withAnimation(.easeInOut(duration: 0.5)) { state.resetCamera() }
        }
        view.onToggleRotate = { [weak state] in
            guard let state, !state.isBusy else { return }
            state.autoRotate.toggle()
        }
        view.onToggleSidebar = { [weak state] in
            guard let state else { return }
            withAnimation(.easeInOut(duration: 0.28)) { state.showSidebar.toggle() }
        }
        view.onPick = { [weak state] point, size in
            guard let state, !state.isBusy else { return }
            state.pickSolar(at: point, viewSize: size)
        }
        view.onEscape = { [weak state] in
            guard let state else { return }
            if state.mode == .solarSystem && state.solarFocus >= 0 {
                withAnimation(.easeInOut(duration: 0.5)) { state.clearSolarFocus() }
            }
        }

        guard device != nil else {
            DispatchQueue.main.async { state.errorMessage = "这台 Mac 没有可用的 Metal 设备。" }
            return view
        }

        do {
            let renderer = try GalaxyRenderer(view: view)
            context.coordinator.renderer = renderer
            view.delegate = renderer

            renderer.onStatus = { [weak state] fps, w, h, samples in
                guard let state else { return }
                state.updateStatus(fps: fps, width: w, height: h, samples: samples)
            }
            renderer.onTime = { [weak state] time in
                guard let state else { return }
                state.simulationTime = time
            }
            renderer.onProgress = { [weak state] done, target, elapsed in
                guard let state else { return }
                state.updateProgress(done: done, target: target, elapsed: elapsed)
            }
            renderer.onSaving = { [weak state] w, h in
                guard let state else { return }
                state.markSaving(width: w, height: h)
            }
            renderer.onComplete = { [weak state] url in
                guard let state else { return }
                state.finishFinal(url: url)
            }
            renderer.onError = { [weak state] message in
                guard let state else { return }
                state.fail(message)
            }
            DispatchQueue.main.async { state.isReady = true }
        } catch {
            DispatchQueue.main.async { state.errorMessage = error.localizedDescription }
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let renderer = context.coordinator.renderer,
              let mtkView = nsView as? MTKView else { return }

        renderer.update(settings: state.renderSettings)

        if let request = state.finalRequest {
            let aspect = Double(mtkView.bounds.width / max(mtkView.bounds.height, 1))
            renderer.startFinal(request, viewportAspect: aspect)
        } else if renderer.isRenderingFinal {
            renderer.cancelFinal()
        }
    }
}
