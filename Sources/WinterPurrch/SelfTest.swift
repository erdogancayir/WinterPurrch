import AppKit
import Metal
import simd

/// `WinterPurrch --selftest <dir>`: runs a scripted scene without a screen and saves pictures of it, so the snow can be
/// checked without looking at the desktop.
enum SelfTest {
    static let size = SIMD2<Float>(900, 520)
    static let windowA = CGRect(x: 90, y: -40, width: 360, height: 330)
    static let windowB = CGRect(x: 400, y: -40, width: 330, height: 250)
    static let dock = CGRect(x: 230, y: 0, width: 440, height: 64)

    static func run(outputDirectory: String) -> Int32 {
        // With the settings a new user gets, snow must visibly pile up within a minute or two.
        let fresh = SnowSimulation(size: size, topLimit: 500)
        var defaults = Settings()
        defaults.melt = true
        fresh.applySettings(defaults)
        for k in 0..<(60 * 180) {
            if k % 4 == 0 {
                fresh.updateWindows([WindowInfo(id: 1, rect: windowA)], dt: 1.0 / 15, keepVanished: false)
                fresh.updateDock(dock)
            }
            fresh.step(dt: 1.0 / 60, cursor: nil)
            if (k + 1) % (60 * 30) == 0 {
                let depth = { (id: Int) in String(format: "%.1f", fresh.ledges[id].map { $0.total / $0.width } ?? 0) }
                print("selftest: defaults t=\((k + 1) / 60)s mean depth ground=\(depth(SnowSimulation.groundID)) "
                      + "dock=\(depth(SnowSimulation.dockID)) window=\(depth(1))")
            }
        }

        let sim = SnowSimulation(size: size, topLimit: 500)
        var s = Settings()
        s.intensity = 1
        sim.applySettings(s)
        let windows = [WindowInfo(id: 1, rect: windowA), WindowInfo(id: 2, rect: windowB)]
        let dt: Float = 1.0 / 60
        func run(_ seconds: Float, cursor: ((Float) -> SIMD2<Float>?)? = nil) {
            let steps = Int(seconds / dt)
            for k in 0..<steps {
                if k % 4 == 0 {
                    sim.updateWindows(windows, dt: dt * 4, keepVanished: false)
                    sim.updateDock(dock)
                }
                sim.step(dt: dt, cursor: cursor?(Float(k) / Float(max(steps - 1, 1))))
            }
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = Renderer(device: device, pixelFormat: .bgra8Unorm, sampleCount: 1, simulation: sim)
        else {
            print("selftest: no Metal")
            return 1
        }
        var shots = 0
        func shot(_ name: String) {
            shots += 1
            save(renderer, sim, to: "\(outputDirectory)/\(shots)-\(name).png")
        }

        let start = Date()
        run(120)   // two minutes of heavy snow
        report(sim, "after snowfall", since: start)
        shot("snowfall")

        // Sweep the cursor through the drift on window A.
        let top = Float(windowA.maxY)
        run(0.8) { t in SIMD2(140 + t * 160, top + 4) }
        run(0.15)
        report(sim, "after sweep", since: start)
        shot("sweep")
        run(3)

        // Build a snowman on the Dock: roll three balls along the ground and set them on top of one another.
        let dockTop = Float(dock.maxY)
        let stackX: Float = 450
        for (index, roll) in [Float(300), 230, 150].enumerated() {
            let startX: Float = 20 + Float(index) * 6
            let groundY = groundTop(sim, at: startX)
            sim.step(dt: dt, cursor: SIMD2(startX, groundY - 2))
            sim.beginGrab(at: SIMD2(startX, groundY - 2))
            guard sim.isHolding else {
                print("selftest: could not grab snow at x=\(startX), ground=\(groundY)")
                return 1
            }
            run(1.6) { t in
                let x = startX + t * roll
                return SIMD2(x, groundTop(sim, at: x) - 2 + 14 * t)
            }
            // Carry it over the stack and let go.
            let lift = sim.balls.map { $0.p.y + $0.r }.max() ?? dockTop
            let from = sim.balls.last!.p
            run(0.6) { t in from + (SIMD2(stackX, max(lift + 40, dockTop + 120)) - from) * t }
            run(0.2) { _ in SIMD2(stackX, max(lift + 40, dockTop + 120)) }
            sim.endGrab()
            run(1.5)
            print("selftest: ball \(index + 1): " + sim.balls.map {
                "r=\(Int($0.r)) \($0.state) face=\($0.face) hat=\($0.hat)"
            }.joined(separator: ", "))
        }
        shot("snowman")

        // Throw one at window B.
        let gx: Float = 860
        sim.step(dt: dt, cursor: SIMD2(gx, groundTop(sim, at: gx) - 2))
        sim.beginGrab(at: SIMD2(gx, groundTop(sim, at: gx) - 2))
        if sim.isHolding {
            run(0.8) { t in SIMD2(gx - t * 60, groundTop(sim, at: gx - t * 60) - 2) }
            let from = sim.balls.last!.p
            run(0.3) { t in from + SIMD2(-200 * t, 260 * t) }
            run(0.12) { t in from + SIMD2(-200 - 260 * t, 260 + 120 * t) }
            sim.endGrab()
            run(0.33)
            shot("throw")
            run(0.5)
            shot("splat")
        } else {
            print("selftest: could not grab snow for the throw")
        }
        run(4)
        shot("settled")
        report(sim, "end", since: start)

        // The cat: drops in, wanders, plays on the Dock, jumps when poked, fetches coffee, purrs when petted.
        sim.hostsCat = true
        sim.applySettings(s)
        func catLine(_ label: String) {
            guard let c = sim.cat else { return print("selftest: \(label): no cat") }
            print("selftest: cat \(label): state=\(c.state) at \(Int(c.p.x)),\(Int(c.p.y)) ledge=\(c.ledge ?? 0) "
                  + "carrying=\(c.carrying) mugs=\(sim.mugs.count) hearts=\(sim.hearts.count)")
        }
        run(6)
        catLine("after 6s")
        shot("cat-wander")
        sim.playOnDockNow()
        run(1.3)
        catLine("playing")
        shot("cat-play")
        if let c = sim.cat {
            let ground = c.p.y
            sim.beginGrab(at: c.center)
            sim.endGrab()
            var highest: Float = 0
            for k in 0..<90 {
                run(1.0 / 60)
                highest = max(highest, (sim.cat?.p.y ?? ground) - ground)
                if k == 12 { shot("cat-jump") }
                // Clicking again in mid-air must not throw it higher.
                if k == 6, let c = sim.cat { sim.beginGrab(at: c.center); sim.endGrab() }
            }
            print("selftest: poke hop height \(Int(highest))pt for a \(Int(c.size))pt cat")
        }
        catLine("poked")
        run(3)
        // A snowball hit: it shakes the snow off where it stands.
        if let c = sim.cat {
            _ = sim.hitCreature(at: c.center, radius: 12, velocity: SIMD2(500, 0))
            run(0.05)
            catLine("hit by snowball")
            shot("cat-snowy")
            run(0.3)
            shot("cat-shaking")
            run(1.2)
            catLine("after shaking")
        }
        run(4)
        // Clumsy moments: tripping flat, digging, tumbling off a ledge.
        sim.catDo("flop")
        run(0.4)
        catLine("flopped")
        shot("cat-flop")
        run(4)
        sim.playOnDockNow()
        sim.catDo("dig")
        run(0.8)
        catLine("digging")
        shot("cat-dig")
        sim.playOnDockNow()
        sim.catDo("tumble")
        run(0.16)
        catLine("tumbling")
        shot("cat-tumble")
        run(0.6)
        catLine("after tumble")
        run(4)

        // Several coffee runs: mugs should end up in different places.
        for run_ in 0..<4 {
            let before = sim.mugs.count
            sim.fetchCoffeeNow()
            var waited: Float = 0
            while sim.mugs.count == before && waited < 60 {
                run(0.5)
                waited += 0.5
            }
            catLine("coffee \(run_ + 1) after \(waited)s")
            run(2)
        }
        print("selftest: mugs at " + sim.mugs.map { "\(Int($0.p.x)),\(Int($0.p.y)) on \($0.ledge ?? 0)" }.joined(separator: "; "))
        shot("cat-coffee")
        if let c = sim.cat {
            let spot = c.center
            run(2.5) { _ in spot }
        }
        catLine("petted")
        shot("cat-pet")

        // A window dragged quickly throws its snow off.
        let moved = [WindowInfo(id: 1, rect: windowA.offsetBy(dx: 60, dy: 0)), WindowInfo(id: 2, rect: windowB)]
        sim.updateWindows(moved, dt: 1.0 / 30, keepVanished: false)
        run(0.25)
        shot("shake")

        // Timing: how long a frame of the simulation takes with this much snow.
        let t0 = Date()
        run(10)
        print(String(format: "selftest: %.3f ms per step", Date().timeIntervalSince(t0) * 1000 / 600))
        return 0
    }

    private static func groundTop(_ sim: SnowSimulation, at x: Float) -> Float {
        guard let g = sim.ledges[SnowSimulation.groundID], let i = g.column(at: x) else { return 0 }
        return g.h[i]
    }

    private static func report(_ sim: SnowSimulation, _ label: String, since: Date) {
        var parts: [String] = []
        for l in sim.ledges.values.sorted(by: { $0.id < $1.id }) {
            let maxH = l.h.max() ?? 0
            parts.append("ledge \(l.id) max=\(String(format: "%.1f", maxH)) area=\(Int(l.total))")
        }
        print("selftest: \(label): flakes=\(sim.flakes.count) balls=\(sim.balls.count) " + parts.joined(separator: "; "))
    }

    private static func save(_ renderer: Renderer, _ sim: SnowSimulation, to path: String) {
        let w = Int(size.x), h = Int(size.y)
        guard let snow = renderer.snapshot(width: w, height: h, background: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        // A night-sky desktop with two windows and a Dock, then the snow over it.
        ctx.setFillColor(CGColor(red: 0.16, green: 0.22, blue: 0.36, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (rect, shade) in [(windowB, 0.82), (windowA, 0.92)] {
            ctx.setFillColor(CGColor(gray: shade, alpha: 1))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
            ctx.fillPath()
            ctx.setFillColor(CGColor(gray: shade - 0.12, alpha: 1))
            ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 28, width: rect.width, height: 16))
        }
        ctx.setFillColor(CGColor(red: 0.5, green: 0.55, blue: 0.65, alpha: 0.85))
        ctx.addPath(CGPath(roundedRect: dock.insetBy(dx: 0, dy: 4), cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.fillPath()
        ctx.draw(snow, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
