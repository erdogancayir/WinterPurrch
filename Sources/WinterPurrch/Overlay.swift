import AppKit
import MetalKit

/// A short log of mouse capture in ~/Library/Logs/WinterPurrch.log, to see why a snowball didn't start.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WinterPurrch.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// A see-through panel over one screen that the snow is drawn in. It lets the mouse through except while a
/// snowball is being made.
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class SnowView: MTKView {
    weak var simulation: SnowSimulation?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func local(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        return SIMD2(Float(p.x), Float(p.y))
    }

    override func mouseDown(with event: NSEvent) {
        let p = local(event)
        simulation?.beginGrab(at: p)
        Log.write("mouseDown at \(Int(p.x)),\(Int(p.y)) holding=\(simulation?.isHolding ?? false)")
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        Log.write("mouseUp")
        simulation?.endGrab()
        NSCursor.arrow.set()
    }
}

/// The snow on one screen: its panel, view, simulation and renderer.
final class ScreenSnow {
    let screen: NSScreen
    let panel: OverlayPanel
    let view: SnowView
    let simulation: SnowSimulation
    private var renderer: Renderer?
    private var capturing = false
    private var optionWas = false

    var origin: CGPoint { panel.frame.origin }

    init?(screen: NSScreen, settings: Settings) {
        self.screen = screen
        panel = OverlayPanel(screen: screen)
        let size = screen.frame.size
        let topLimit = Float(screen.visibleFrame.maxY - screen.frame.minY)
        simulation = SnowSimulation(size: SIMD2(Float(size.width), Float(size.height)), topLimit: topLimit)
        simulation.hostsCat = screen == NSScreen.screens.first
        simulation.applySettings(settings)
        view = SnowView(frame: CGRect(origin: .zero, size: size), device: MTLCreateSystemDefaultDevice())
        view.simulation = simulation
        view.colorPixelFormat = .bgra8Unorm
        view.sampleCount = 1
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 60
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.isOpaque = false
        guard let renderer = Renderer(view: view, simulation: simulation) else { return nil }
        self.renderer = renderer
        view.delegate = renderer
        panel.contentView = view
        renderer.onFrame = { [weak self] dt in self?.frame(dt) }
    }

    private var shown = false
    private var occlusionObserver: NSObjectProtocol?

    func show(screenshots: Bool) {
        shown = true
        panel.sharingType = screenshots ? .readOnly : .none
        panel.orderFrontRegardless()
        if occlusionObserver == nil {
            // Covered by a full-screen app or video, there is nothing to see: stop drawing until it shows again.
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
            ) { [weak self] _ in self?.updatePaused() }
        }
        updatePaused()
    }

    private func updatePaused() {
        view.isPaused = !shown || !panel.occlusionState.contains(.visible)
    }

    func hide() {
        shown = false
        view.isPaused = true
        panel.orderOut(nil)
    }

    func close() {
        hide()
        view.delegate = nil
        panel.close()
    }

    func setFrameRate(_ fps: Int) { view.preferredFramesPerSecond = fps }

    private var frameCount = 0

    private func frame(_ dt: Float) {
        frameCount += 1
        if frameCount % 600 == 0, let dir = UserDefaults.standard.string(forKey: "debugDump") { dump(to: dir) }
        let mouse = NSEvent.mouseLocation
        let inside = panel.frame.contains(mouse)
        let point = inside ? SIMD2(Float(mouse.x - origin.x), Float(mouse.y - origin.y)) : nil
        simulation.step(dt: dt, cursor: point)
        let option = NSEvent.modifierFlags.contains(.option)
        let want = inside && simulation.wantsMouse(optionHeld: option)
        if option != optionWas {
            optionWas = option
            if option, let p = point {
                Log.write("option down at \(Int(p.x)),\(Int(p.y)) snow=\(String(format: "%.1f", simulation.snowDepth(near: p))) wants=\(want)")
            }
        }
        if want != capturing {
            Log.write("capture \(want ? "on" : "off")")
            capturing = want
            panel.ignoresMouseEvents = !want
            if want && !simulation.isHolding {
                if let p = point, simulation.creatureUnder(p) { NSCursor.pointingHand.set() } else { NSCursor.openHand.set() }
            }
            if !want { NSCursor.arrow.set() }
        }
    }

    /// Hands the windows and the Dock to the simulation in this screen's coordinates.
    func updateSurfaces(windows: [WindowList.Entry], dock: CGRect?, dt: Float, keepVanished: Bool) {
        let o = screen.frame.origin
        let local = windows.compactMap { w -> WindowInfo? in
            guard w.frame.intersects(screen.frame) else { return nil }
            return WindowInfo(id: w.id, rect: w.frame.offsetBy(dx: -o.x, dy: -o.y))
        }
        simulation.updateWindows(local, dt: dt, keepVanished: keepVanished)
        if let dock, screen.frame.contains(CGPoint(x: dock.midX, y: dock.minY + 1)) {
            simulation.updateDock(dock.offsetBy(dx: -o.x, dy: -o.y))
        } else {
            simulation.updateDock(nil)
        }
    }

    /// `defaults write com.erdogancayir.WinterPurrch debugDump <dir>`: every ten seconds, writes what this screen's snow looks like.
    private func dump(to dir: String) {
        let sim = simulation
        var lines = ["screen \(screen.localizedName) \(screen.frame) flakes=\(sim.flakes.count) balls=\(sim.balls.count)"]
        for l in sim.ledges.values.sorted(by: { $0.id < $1.id }) {
            let shown = l.visible.filter { $0 }.count
            lines.append(String(format: "ledge %d kind=%@ x0=%.0f y=%.0f w=%.0f visible=%d/%d max=%.1f",
                                l.id, "\(l.kind)", l.x0, l.y, l.width, shown, l.visible.count, l.h.max() ?? 0))
        }
        let name = screen.localizedName.replacingOccurrences(of: " ", with: "_")
        try? lines.joined(separator: "\n").write(toFile: "\(dir)/\(name).txt", atomically: true, encoding: .utf8)
        guard let renderer, let image = renderer.snapshot(width: Int(screen.frame.width), height: Int(screen.frame.height),
                                                          background: MTLClearColor(red: 0.2, green: 0.25, blue: 0.4, alpha: 1))
        else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
}
