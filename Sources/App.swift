import SwiftUI
import AppKit

@main
struct MilkyWayStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1180, minHeight: 720)
                .preferredColorScheme(.dark)
                .background(Palette.background)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1520, height: 980)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .sidebar) {
                Button("切换侧栏") {
                    NotificationCenter.default.post(name: .toggleGalaxySidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command])
            }
            CommandGroup(after: .saveItem) {
                Button("渲染最终帧…") {
                    NotificationCenter.default.post(name: .requestGalaxyRender, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        prepareWindow(attempt: 0)
    }

    private func prepareWindow(attempt: Int) {
        let windows = NSApp.windows.filter { $0.styleMask.contains(.titled) && $0.contentView != nil }
        self.log("prepare attempt=\(attempt) windows=\(NSApp.windows.count) titled=\(windows.count)")

        guard let window = windows.first else {
            if attempt < 200 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    self.prepareWindow(attempt: attempt + 1)
                }
            }
            return
        }

        window.title = "Milky Way Studio"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.minSize = NSSize(width: 1180, height: 720)
        window.isRestorable = false
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        window.setContentSize(NSSize(width: 1520, height: 980))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.log("configured frame=\(window.frame) content=\(window.contentView?.bounds ?? .zero)")

        var snapshotPath = ProcessInfo.processInfo.environment["MILKYWAY_SNAPSHOT"]
        if snapshotPath == nil, let idx = CommandLine.arguments.firstIndex(of: "--ui-snapshot"),
           idx + 1 < CommandLine.arguments.count {
            snapshotPath = CommandLine.arguments[idx + 1]
        }
        if let snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                self.captureWindow(window, to: snapshotPath)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func log(_ message: String) {
        guard ProcessInfo.processInfo.environment["MILKYWAY_DEBUG"] != nil else { return }
        let path = "/Users/xulixin/Downloads/MilkyWayStudio/build/app_debug.log"
        let line = "[\(Date())] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func captureWindow(_ window: NSWindow, to path: String) {
        log("capture start frame=\(window.frame)")
        guard let view = window.contentView else {
            log("capture no contentView")
            return
        }
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                do {
                    try data.write(to: URL(fileURLWithPath: path))
                    log("wrote cache snapshot \(data.count) bytes")
                } catch {
                    log("cache write error \(error)")
                }
            } else {
                log("cache png failed")
            }
        } else {
            log("cache rep nil")
        }
        if let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                 CGWindowID(window.windowNumber),
                                                 [.boundsIgnoreFraming]) {
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let cgPath = path.replacingOccurrences(of: ".png", with: "_cg.png")
                try? data.write(to: URL(fileURLWithPath: cgPath))
                log("wrote CG snapshot \(data.count) bytes")
            }
        } else {
            log("CGWindowListCreateImage nil")
        }
    }
}

extension Notification.Name {
    static let toggleGalaxySidebar = Notification.Name("toggleGalaxySidebar")
    static let requestGalaxyRender = Notification.Name("requestGalaxyRender")
}
