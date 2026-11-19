import Foundation
import simd

/// Width of one column of a heightmap, in points.
let columnWidth: Float = 2

@inline(__always) func rand(_ a: Float, _ b: Float) -> Float { Float.random(in: a..<b) }

struct Settings {
    var intensity: Float = 0.5      // 0...1
    var fallSpeed: Float = 1        // how fast flakes come down, 0.3...2.5
    var flakeSize: Float = 1        // how big flakes look, 0.5...2.5
    var opacity: Float = 1
    var ground = true
    var dock = true
    var windows = true
    var melt = false
    var blizzard = false
    var cat = true
    var friend = true
    var skater = true
    var birds = true
    var catSize: Float = 42
}

/// A falling or flying bit of snow.
struct Flake {
    enum Kind: UInt8 { case flake, spray, clump }
    var p: SIMD2<Float>
    var v: SIMD2<Float>
    var r: Float
    var depth: Float      // 0 far ... 1 near; only near flakes settle
    var phase: Float
    var speed: Float
    var amount: Float     // area of snow (pt²) it leaves where it lands
    var kind: Kind
    var seed: Float
}

/// A surface snow piles up on, kept as a heightmap of columns.
final class Ledge {
    enum Kind { case ground, dock, window }
    let id: Int
    let kind: Kind
    var x0: Float
    var y: Float
    var h: [Float]
    var visible: [Bool]
    var cap: Float
    var lip: Float          // how high snow can stand at an open end before it slips off
    var spills: Bool
    var spillLeft: Float = 0
    var spillRight: Float = 0
    var restless = 0         // frames left to keep relaxing

    init(id: Int, kind: Kind, x0: Float, y: Float, count: Int) {
        self.id = id
        self.kind = kind
        self.x0 = x0
        self.y = y
        h = Array(repeating: 0, count: max(count, 2))
        visible = Array(repeating: true, count: max(count, 2))
        switch kind {
        case .ground: cap = 70; lip = 0; spills = false
        case .dock: cap = 30; lip = 7; spills = true
        case .window: cap = 26; lip = 6; spills = true
        }
    }

    var width: Float { Float(h.count) * columnWidth }

    @inline(__always) func column(at x: Float) -> Int? {
        let i = Int(floor((x - x0) / columnWidth))
        return i >= 0 && i < h.count ? i : nil
    }

    @inline(__always) func centerX(_ i: Int) -> Float { x0 + (Float(i) + 0.5) * columnWidth }

    var total: Float { h.reduce(0, +) * columnWidth }
}

/// A snowball: rolled up from settled snow with ⌥ held, then thrown, dropped or stacked.
struct Snowball {
    enum State { case held, flying, resting }
    let uid: Int
    var p: SIMD2<Float>
    var v: SIMD2<Float> = .zero
    var volume: Float
    var state: State
    var supportLedge: Int?
    var supportBall: Int?
    var offset: SIMD2<Float> = .zero
    var seed: Float = rand(0, 100)
    var age: Float = 0
    var face = false        // the top ball of a stack becomes a snowman's head
    var hat = false
    var body = false        // the ball under a snowman's head gets buttons and arms

    var r: Float { max(3, sqrt(volume / .pi)) }
}

struct WindowInfo {
    let id: Int
    let rect: CGRect   // local to the screen, y up
}

final class SnowSimulation {
    var size: SIMD2<Float>
    var settings = Settings()
    /// Highest a window top may be and still collect snow (just under the menu bar).
    var topLimit: Float

    private(set) var flakes: [Flake] = []
    private(set) var ledges: [Int: Ledge] = [:]
    private(set) var balls: [Snowball] = []
    /// The cat lives on one screen only; this one hosts it when `hostsCat` is set.
    var hostsCat = false
    var cats: [Cat] = []
    var friendCooldown: Float = 15
    var friendSeek: Float = 20
    var skater: Skater?
    var skaterCooldown: Float = 90
    /// The laser pointer: a red dot at the cursor that the cats chase.
    var laserOn = false
    /// 0 by day, 1 at night: tints the snow, lights up the windows and makes the cats sleepier.
    var night: Float = 0
    var bird: Bird?
    var birdCooldown: Float = 50
    var laser: SIMD2<Float>? { laserOn ? cursor : nil }
    /// The first cat, for code that deals with one.
    var cat: Cat? {
        get { cats.first }
        set {
            if let newValue {
                if cats.isEmpty { cats.append(newValue) } else { cats[0] = newValue }
            } else {
                cats.removeAll()
            }
        }
    }
    var mugs: [Mug] = []
    var hearts: [Heart] = []
    private var stash: [Int: [Float]] = [:]
    private var pending: [Flake] = []

    private(set) var time: Float = 0
    private var wind: Float = 0
    private var windTarget: Float = 0
    private var windTimer: Float = 0
    private var spawnDebt: Float = 0
    private var prefilled = false

    private(set) var cursor: SIMD2<Float>?
    private(set) var cursorVelocity = SIMD2<Float>(repeating: 0)
    private var heldBall: Int?
    private var nextUID = 1

    static let groundID = -2
    static let dockID = -1

    init(size: SIMD2<Float>, topLimit: Float) {
        self.size = size
        self.topLimit = topLimit
        rebuildGround()
    }

    var isHolding: Bool { heldBall != nil }

    // MARK: - Surfaces

    func rebuildGround() {
        if settings.ground {
            let n = Int(size.x / columnWidth)
            if let g = ledges[Self.groundID], g.h.count == n { return }
            ledges[Self.groundID] = Ledge(id: Self.groundID, kind: .ground, x0: 0, y: 0, count: n)
        } else if let g = ledges.removeValue(forKey: Self.groundID) {
            _ = g
        }
    }

    func applySettings(_ s: Settings) {
        let old = settings
        settings = s
        if old.ground != s.ground { rebuildGround() }
        Mug.size = s.catSize * 0.42
        // The grey longhair, and its friend the ginger tabby.
        let wanted = hostsCat && s.cat ? (s.friend ? 2 : 1) : 0
        while cats.count > wanted { cats.removeLast() }
        while cats.count < wanted { spawnCat(coat: cats.count) }
        for i in cats.indices { cats[i].size = s.catSize * (cats[i].coat == 0 ? 1 : 0.94) }
        if old.windows && !s.windows {
            for (id, l) in ledges where l.kind == .window {
                drop(l, fraction: 1, velocity: .zero)
                ledges[id] = nil
            }
        }
        if old.dock && !s.dock, let d = ledges[Self.dockID] {
            drop(d, fraction: 1, velocity: .zero)
            ledges[Self.dockID] = nil
        }
    }

    /// The Dock's glass, in local coordinates, or nil when there is none on this screen.
    func updateDock(_ rect: CGRect?) {
        guard settings.dock, let rect, rect.width > 40 else {
            if let d = ledges.removeValue(forKey: Self.dockID) { drop(d, fraction: 1, velocity: .zero) }
            return
        }
        // Snow keeps off the round ends of the glass.
        let inset = Float(rect.height) * 0.22
        let left = Float(rect.minX) + inset
        let n = Int((Float(rect.width) - 2 * inset) / columnWidth)
        let top = Float(rect.maxY)
        if let d = ledges[Self.dockID] {
            if d.h.count != n {
                // The Dock grows and shrinks from its middle: stretch what lies on it to the new width.
                let old = d.h
                var h = [Float](repeating: 0, count: max(n, 2))
                for i in h.indices {
                    let src = Float(i) / Float(max(h.count - 1, 1)) * Float(old.count - 1)
                    h[i] = old[Int(src.rounded())]
                }
                d.h = h
                d.visible = Array(repeating: true, count: h.count)
                d.restless = 60
            }
            d.x0 = left
            d.y = top
        } else {
            let d = Ledge(id: Self.dockID, kind: .dock, x0: left, y: top, count: n)
            if let saved = stash.removeValue(forKey: Self.dockID), saved.count == n { d.h = saved }
            ledges[Self.dockID] = d
        }
    }

    /// Windows front to back, in local coordinates. `dt` is the time since the last update.
    func updateWindows(_ windows: [WindowInfo], dt: Float, keepVanished: Bool) {
        guard settings.windows else { return }
        var seen = Set<Int>()
        let corner: Float = 9
        for (index, w) in windows.enumerated() {
            let top = Float(w.rect.maxY)
            guard top > 30, top < topLimit - 2 else { continue }
            let left = max(Float(w.rect.minX) + corner, 0)
            let right = min(Float(w.rect.maxX) - corner, size.x)
            guard right - left > 30 else { continue }
            let n = Int((right - left) / columnWidth)
            seen.insert(w.id)

            let ledge: Ledge
            if let l = ledges[w.id] {
                let dx = left - l.x0, dy = top - l.y
                if l.h.count != n {
                    drop(l, fraction: 1, velocity: .zero)
                    ledge = Ledge(id: w.id, kind: .window, x0: left, y: top, count: n)
                    ledges[w.id] = ledge
                } else {
                    ledge = l
                    if dx != 0 || dy != 0 {
                        let move = SIMD2(dx, dy)
                        let speed = length(move) / max(dt, 1.0 / 120)
                        // A gentle nudge carries the snow along; a drag or a shake throws it off.
                        let fraction = min(max((speed - 120) / 700, 0), 1)
                        l.x0 = left
                        l.y = top
                        if fraction > 0.02 {
                            drop(l, fraction: fraction, velocity: move / max(dt, 1.0 / 120) * 0.5)
                            if fraction > 0.5 { loosenBalls(on: l.id) }
                        }
                    }
                }
            } else if let saved = stash.removeValue(forKey: w.id), saved.count == n {
                ledge = Ledge(id: w.id, kind: .window, x0: left, y: top, count: n)
                ledge.h = saved
                ledges[w.id] = ledge
            } else {
                ledge = Ledge(id: w.id, kind: .window, x0: left, y: top, count: n)
                ledges[w.id] = ledge
            }

            // Hide the stretches of the top edge that windows in front cover.
            let probe = CGFloat(top + 1)
            let front = windows[0..<index].map(\.rect).filter { $0.minY <= probe && $0.maxY > probe }
            if front.isEmpty {
                for i in ledge.visible.indices { ledge.visible[i] = true }
            } else {
                for i in ledge.visible.indices {
                    let x = CGFloat(ledge.centerX(i))
                    ledge.visible[i] = !front.contains { x >= $0.minX && x < $0.maxX }
                }
            }
        }
        for (id, l) in ledges where l.kind == .window && !seen.contains(id) {
            if keepVanished {
                stash[id] = l.h
                loosenBalls(on: id, vanish: true)
            } else {
                drop(l, fraction: 1, velocity: SIMD2(0, -40))
                loosenBalls(on: id)
            }
            ledges[id] = nil
        }
        if stash.count > 200 { stash.removeAll() }
    }

    // MARK: - Saving

    /// What is worth keeping across a restart: the drifts, snowballs and snowmen, and the mugs.
    func savedState() -> SavedState {
        var state = SavedState()
        state.ground = ledges[Self.groundID]?.h
        state.dock = ledges[Self.dockID]?.h
        for (id, l) in ledges where l.kind == .window { state.windows[String(id)] = l.h }
        for (id, h) in stash where id >= 0 { state.windows[String(id)] = h }
        state.balls = balls.filter { $0.state == .resting }.map {
            SavedState.Ball(uid: $0.uid, x: $0.p.x, y: $0.p.y, volume: $0.volume, ledge: $0.supportLedge,
                            onBall: $0.supportBall, ox: $0.offset.x, oy: $0.offset.y, seed: $0.seed)
        }
        state.mugs = mugs.filter(\.resting).map {
            SavedState.Mug(x: $0.p.x, y: $0.p.y, ledge: $0.ledge, offset: $0.offset, age: $0.age)
        }
        return state
    }

    func restore(_ state: SavedState) {
        if let h = state.ground, let g = ledges[Self.groundID], g.h.count == h.count { g.h = h }
        if let h = state.dock { stash[Self.dockID] = h }
        for (key, h) in state.windows { if let id = Int(key) { stash[id] = h } }
        balls = state.balls.map {
            var b = Snowball(uid: $0.uid, p: SIMD2($0.x, $0.y), volume: $0.volume, state: .resting)
            b.supportLedge = $0.ledge
            b.supportBall = $0.onBall
            b.offset = SIMD2($0.ox, $0.oy)
            b.seed = $0.seed
            return b
        }
        nextUID = (balls.map(\.uid).max() ?? 0) + 1
        mugs = state.mugs.map {
            var m = Mug(p: SIMD2($0.x, $0.y))
            m.ledge = $0.ledge
            m.offset = $0.offset
            m.age = $0.age
            m.resting = true
            return m
        }
        refreshSnowmen()
    }

    /// Just after starting, the windows and the Dock have yet to be read: things resting on them wait for them.
    var settling: Bool { time < 1.5 }

    func clear() {
        for l in ledges.values {
            for i in l.h.indices { l.h[i] = 0 }
        }
        stash.removeAll()
        balls.removeAll()
        mugs.removeAll()
        hearts.removeAll()
        heldBall = nil
        flakes.removeAll { $0.kind != .flake }
    }

    /// Throws `fraction` of a ledge's snow off it in clumps.
    private func drop(_ l: Ledge, fraction: Float, velocity: SIMD2<Float>) {
        let chunk = 5
        var i = 0
        while i < l.h.count {
            let j = min(l.h.count, i + chunk)
            var area: Float = 0
            var tallest: Float = 0
            for k in i..<j {
                let take = l.h[k] * fraction
                area += take * columnWidth
                tallest = max(tallest, l.h[k])
                l.h[k] -= take
            }
            if area > 0.6 && l.visible[min(i, l.h.count - 1)] {
                let pieces = max(1, Int(ceil(area / 45)))
                for _ in 0..<pieces {
                    let a = area / Float(pieces)
                    let x = l.x0 + (Float(i) + rand(0, Float(j - i))) * columnWidth
                    let p = SIMD2(x, l.y + rand(0, max(tallest, 1)))
                    let v = velocity + SIMD2(rand(-30, 30), rand(-10, 40))
                    addClump(at: p, area: a, velocity: v)
                }
            }
            i = j
        }
        l.restless = 60
    }

    private func addClump(at p: SIMD2<Float>, area: Float, velocity: SIMD2<Float>) {
        let r = min(max(sqrt(area / .pi) * 0.9, 1.4), 7)
        pending.append(Flake(p: p, v: velocity, r: r, depth: 1, phase: 0, speed: 0,
                             amount: area, kind: .clump, seed: rand(0, 100)))
    }

    func addSpray(at p: SIMD2<Float>, velocity: SIMD2<Float>, amount: Float, r: Float = rand(1.1, 2.4)) {
        pending.append(Flake(p: p, v: velocity, r: r, depth: 1, phase: rand(0, 6.28), speed: rand(30, 50),
                             amount: amount, kind: .spray, seed: rand(0, 100)))
    }

    // MARK: - Step

    func step(dt: Float, cursor point: SIMD2<Float>?) {
        time += dt
        updateWind(dt)
        updateCursor(point, dt: dt)
        spawn(dt)
        let active = Array(ledges.values)
        moveFlakes(dt, active)
        if let p = cursor, heldBall == nil { carve(around: p, active) }
        updateBalls(dt, active)
        updateCat(dt, active)
        updateSkater(dt)
        updateBird(dt, active)
        settle(dt, active)
        if !pending.isEmpty {
            flakes.append(contentsOf: pending)
            pending.removeAll(keepingCapacity: true)
        }
        if flakes.count > 6000 { flakes.removeFirst(flakes.count - 6000) }
    }

    private func updateWind(_ dt: Float) {
        windTimer -= dt
        let gusty: Float = settings.blizzard ? 4 : 1
        if windTimer <= 0 {
            windTimer = rand(6, 16) / gusty
            windTarget = rand(-22, 22) * gusty + (settings.blizzard ? 70 : 0)
        }
        wind += (windTarget - wind) * min(1, dt * 0.4 * gusty)
    }

    private func updateCursor(_ point: SIMD2<Float>?, dt: Float) {
        guard let point else {
            cursor = nil
            cursorVelocity = .zero
            return
        }
        if let old = cursor, dt > 0 {
            let v = (point - old) / dt
            cursorVelocity += (v - cursorVelocity) * min(1, dt * 18)
        }
        cursor = point
    }

    private var targetCount: Float {
        let base = settings.intensity * settings.intensity * size.x * 0.55 + settings.intensity * 40
        return settings.blizzard ? base * 2.2 : base
    }

    private func spawn(_ dt: Float) {
        let target = targetCount
        if !prefilled {
            prefilled = true
            for _ in 0..<Int(target) { flakes.append(newFlake(y: rand(0, size.y))) }
            return
        }
        let falling = Float(flakes.lazy.filter { $0.kind == .flake }.count)
        guard falling < target * 1.1 else { return }
        let fallTime = size.y / ((settings.blizzard ? 95 : 48) * settings.fallSpeed)
        spawnDebt += target / fallTime * dt
        while spawnDebt >= 1 {
            spawnDebt -= 1
            flakes.append(newFlake(y: size.y + 6))
        }
    }

    private func newFlake(y: Float) -> Flake {
        let depth = rand(0.25, 1)
        let r = (0.7 + depth * depth * 2.4) * rand(0.8, 1.2)
        let margin = abs(wind) * 6 + 40
        let x = rand(-margin, size.x + margin) - wind * 4
        return Flake(p: SIMD2(x, y), v: SIMD2(0, -30), r: r, depth: depth, phase: rand(0, 6.28),
                     speed: (18 + depth * 52) * rand(0.8, 1.2) * (settings.blizzard ? 1.8 : 1),
                     amount: (20 + r * 4) / max(settings.fallSpeed, 0.1), kind: .flake, seed: rand(0, 100))
    }

    private func moveFlakes(_ dt: Float, _ active: [Ledge]) {
        let cursorPush = cursor != nil && simd_length(cursorVelocity) > 40
        var w = 0
        let count = flakes.count
        for i in 0..<count {
            var f = flakes[i]
            let y0 = f.p.y
            switch f.kind {
            case .flake, .spray:
                let sway = sin(time * (0.6 + f.seed.truncatingRemainder(dividingBy: 1)) + f.phase) * 16 * f.depth
                // Only falling flakes follow the speed setting; spray keeps its own.
                let fall = f.kind == .flake ? f.speed * settings.fallSpeed : f.speed
                let target = SIMD2(wind * (0.4 + f.depth * 0.6) + sway, -fall)
                let k: Float = f.kind == .spray ? 2.6 : 1.4
                f.v += (target - f.v) * min(1, k * dt)
            case .clump:
                f.v.y -= 1100 * dt
                f.v.x *= 1 - 0.4 * dt
            }
            if cursorPush, let c = cursor, f.depth > 0.5 {
                let d = f.p - c
                let dist2 = simd_length_squared(d)
                if dist2 < 900 {
                    f.v += cursorVelocity * (1 - dist2 / 900) * 0.12
                }
            }
            f.p += f.v * dt

            var keep = true
            if f.depth > 0.62 {
                if absorbIntoBall(&f) {
                    keep = false
                } else if let (ledge, col) = landing(x: f.p.x, from: y0, to: f.p.y, active) {
                    land(f, on: ledge, col)
                    keep = false
                }
            }
            if f.p.y < -30 || f.p.x < -300 || f.p.x > size.x + 300 || f.p.y > size.y + 600 { keep = false }
            if keep {
                flakes[w] = f
                w += 1
            }
        }
        flakes.removeLast(count - w)
    }

    @inline(__always)
    func landing(x: Float, from y0: Float, to y1: Float, _ active: [Ledge]) -> (Ledge, Int)? {
        var best: (Ledge, Int)?
        var bestTop = -Float.infinity
        for l in active {
            guard let i = l.column(at: x), l.visible[i] else { continue }
            let top = l.y + l.h[i]
            if top <= y0 + 0.5 && top >= y1 && top > bestTop {
                bestTop = top
                best = (l, i)
            }
        }
        return best
    }

    private func land(_ f: Flake, on l: Ledge, _ i: Int) {
        switch f.kind {
        case .flake, .spray:
            deposit(l, i, area: f.amount)
        case .clump:
            // A clump bursts into powder where it lands, leaving most of itself behind.
            let burst = f.amount > 12 ? min(Int(f.amount / 10), 5) : 0
            let left = f.amount * (burst > 0 ? 0.7 : 1)
            let spread = max(1, Int(f.r / columnWidth))
            for k in -spread...spread {
                let j = min(max(i + k, 0), l.h.count - 1)
                deposit(l, j, area: left / Float(2 * spread + 1))
            }
            for _ in 0..<burst {
                let v = SIMD2(rand(-90, 90) + f.v.x * 0.2, rand(40, 140))
                addSpray(at: SIMD2(f.p.x, l.y + l.h[i] + 1), velocity: v, amount: f.amount * 0.3 / Float(burst))
            }
        }
    }

    @inline(__always) private func deposit(_ l: Ledge, _ i: Int, area: Float) {
        guard l.h[i] < l.cap else { return }
        let dh = area / columnWidth
        l.h[i] += dh * 0.5
        let a = i > 0 ? i - 1 : i
        let b = i < l.h.count - 1 ? i + 1 : i
        l.h[a] += dh * 0.25
        l.h[b] += dh * 0.25
        l.restless = max(l.restless, 20)
    }

    /// The cursor ploughs through the drifts it touches, throwing up powder.
    private func carve(around p: SIMD2<Float>, _ active: [Ledge]) {
        let radius: Float = 11
        let speed = simd_length(cursorVelocity)
        for l in active {
            guard p.y > l.y - radius, p.y < l.y + l.cap + radius,
                  p.x > l.x0 - radius, p.x < l.x0 + l.width + radius else { continue }
            let first = max(0, Int((p.x - radius - l.x0) / columnWidth))
            let last = min(l.h.count - 1, Int((p.x + radius - l.x0) / columnWidth))
            guard first <= last else { continue }
            var removed: Float = 0
            for i in first...last where l.visible[i] {
                let dx = l.centerX(i) - p.x
                let reach = radius * radius - dx * dx
                guard reach > 0 else { continue }
                let bottom = p.y - sqrt(reach)
                let top = l.y + l.h[i]
                guard bottom < top, p.y + sqrt(reach) > l.y else { continue }
                let floor = max(l.y, bottom)
                let cut = top - floor
                if cut > 0.05 {
                    l.h[i] -= cut
                    removed += cut * columnWidth
                }
            }
            guard removed > 0.4 else { continue }
            l.restless = 60
            let pieces = min(max(Int(removed / 2.5), 1), 40)
            let dir = speed > 1 ? cursorVelocity / speed : SIMD2<Float>(0, 1)
            for _ in 0..<pieces {
                let v = dir * min(speed, 900) * rand(0.25, 0.7) + SIMD2(rand(-50, 50), rand(50, 150))
                let at = p + SIMD2(rand(-radius, radius) * 0.7, rand(-2, 6))
                addSpray(at: at, velocity: v, amount: removed / Float(pieces))
            }
        }
    }

    private func settle(_ dt: Float, _ active: [Ledge]) {
        // Slow enough that snow still piles up while it falls, so drifts settle at a modest depth.
        let melt = settings.melt ? dt * (settings.blizzard ? 0.004 : 0.012) : 0
        for l in active {
            if melt > 0 {
                for i in l.h.indices where l.h[i] > 0 { l.h[i] = max(0, l.h[i] - melt) }
            }
            guard l.restless > 0 else { continue }
            l.restless -= 1
            relax(l)
        }
        if melt > 0 {
            for i in balls.indices where balls[i].state == .resting {
                balls[i].volume -= melt * 2 * balls[i].r
            }
            let gone = balls.filter { $0.state == .resting && $0.volume < 30 }.map(\.uid)
            if !gone.isEmpty {
                balls.removeAll { gone.contains($0.uid) }
            }
        }
    }

    /// Lets snow slump to its angle of repose and slip off the open ends of a ledge.
    private func relax(_ l: Ledge) {
        let n = l.h.count
        let steepest = columnWidth * 0.7
        for pass in 0..<2 {
            let forward = (pass + Int(time * 60)) % 2 == 0
            for k in 0..<(n - 1) {
                let i = forward ? k : n - 2 - k
                let d = l.h[i] - l.h[i + 1]
                if d > steepest {
                    let m = (d - steepest) * 0.5
                    l.h[i] -= m
                    l.h[i + 1] += m
                } else if d < -steepest {
                    let m = (-d - steepest) * 0.5
                    l.h[i] += m
                    l.h[i + 1] -= m
                }
            }
        }
        guard l.spills else { return }
        if l.h[0] > l.lip {
            l.spillLeft += (l.h[0] - l.lip) * columnWidth
            l.h[0] = l.lip
        }
        if l.h[n - 1] > l.lip {
            l.spillRight += (l.h[n - 1] - l.lip) * columnWidth
            l.h[n - 1] = l.lip
        }
        if l.spillLeft > 8 {
            addClump(at: SIMD2(l.x0 - 1, l.y + l.lip), area: l.spillLeft, velocity: SIMD2(rand(-35, -10), 0))
            l.spillLeft = 0
        }
        if l.spillRight > 8 {
            addClump(at: SIMD2(l.x0 + l.width + 1, l.y + l.lip), area: l.spillRight, velocity: SIMD2(rand(10, 35), 0))
            l.spillRight = 0
        }
    }

    // MARK: - Snowballs

    private func ballIndex(_ uid: Int) -> Int? { balls.firstIndex { $0.uid == uid } }

    /// Whether the overlay should take the mouse: ⌥ is held over snow or a snowball, or a ball is in hand.
    func wantsMouse(optionHeld: Bool) -> Bool {
        if heldBall != nil { return true }
        if let c = cursor, creatureUnder(c) { return true }
        guard optionHeld, let c = cursor else { return false }
        if balls.contains(where: { $0.state != .held && simd_distance($0.p, c) < $0.r + 6 }) { return true }
        return snowDepth(near: c) > 1
    }

    func snowDepth(near c: SIMD2<Float>) -> Float {
        var best: Float = 0
        for l in ledges.values {
            for dx in stride(from: Float(-8), through: 8, by: 4) {
                guard let i = l.column(at: c.x + dx), l.visible[i] else { continue }
                if c.y > l.y - 8 && c.y < l.y + l.h[i] + 10 { best = max(best, l.h[i]) }
            }
        }
        return best
    }

    func beginGrab(at p: SIMD2<Float>) {
        cursor = p
        if poke(at: p) { return }
        // Pick up a ball if one is under the cursor (the top one of a stack first).
        let hits = balls.indices.filter { balls[$0].state != .held && simd_distance(balls[$0].p, p) < balls[$0].r + 6 }
        if let i = hits.max(by: { balls[$0].p.y < balls[$1].p.y }) {
            let uid = balls[i].uid
            balls[i].state = .held
            balls[i].supportBall = nil
            balls[i].supportLedge = nil
            balls[i].face = false
            balls[i].hat = false
            loosenBalls(onBall: uid)
            heldBall = uid
            refreshSnowmen()
            return
        }
        guard snowDepth(near: p) > 0.5 else { return }
        var ball = Snowball(uid: nextUID, p: p, volume: 0, state: .held)
        nextUID += 1
        // Scoop a starting handful.
        ball.volume = scoop(center: p, radius: 12, depthLimit: 30)
        guard ball.volume > 8 else { return }
        ball.volume = max(ball.volume, 30)
        balls.append(ball)
        heldBall = ball.uid
        if balls.count > 40 { balls.removeFirst() }
    }

    func endGrab() {
        guard let uid = heldBall, let i = ballIndex(uid) else {
            heldBall = nil
            return
        }
        heldBall = nil
        var v = cursorVelocity
        let speed = simd_length(v)
        if speed > 2600 { v *= 2600 / speed }
        if speed < 60 { v = .zero }
        balls[i].v = v
        balls[i].state = .flying
    }

    /// Removes snow inside a circle and returns its area.
    private func scoop(center p: SIMD2<Float>, radius: Float, depthLimit: Float) -> Float {
        var got: Float = 0
        for l in ledges.values {
            guard p.x > l.x0 - radius, p.x < l.x0 + l.width + radius else { continue }
            let first = max(0, Int((p.x - radius - l.x0) / columnWidth))
            let last = min(l.h.count - 1, Int((p.x + radius - l.x0) / columnWidth))
            guard first <= last else { continue }
            for i in first...last where l.visible[i] {
                let dx = l.centerX(i) - p.x
                let reach = radius * radius - dx * dx
                guard reach > 0 else { continue }
                let bottom = p.y - sqrt(reach) - 4
                let top = l.y + l.h[i]
                guard bottom < top, p.y + sqrt(reach) + 4 > l.y else { continue }
                let cut = min(top - max(l.y, bottom), depthLimit)
                if cut > 0 {
                    l.h[i] -= cut
                    got += cut * columnWidth
                    l.restless = 60
                }
            }
        }
        return got
    }

    private func updateBalls(_ dt: Float, _ active: [Ledge]) {
        guard !balls.isEmpty else { return }
        var splats: [Int] = []
        for i in balls.indices {
            balls[i].age += dt
            switch balls[i].state {
            case .held:
                guard let c = cursor else { continue }
                balls[i].p += (c - balls[i].p) * min(1, dt * 30)
                // Rolling the ball through snow packs it on.
                let r = balls[i].r
                let got = scoop(center: balls[i].p, radius: r + 1.5, depthLimit: 3)
                if got > 0 && r < 75 { balls[i].volume += got * 0.85 }
            case .flying:
                flyBall(i, dt, active, &splats)
            case .resting:
                restBall(i)
            }
        }
        if !splats.isEmpty {
            for uid in Set(splats) {
                guard let i = ballIndex(uid) else { continue }
                let b = balls[i]
                splat(b)
                balls.remove(at: i)
                loosenBalls(onBall: uid)
            }
            refreshSnowmen()
        }
    }

    private func flyBall(_ i: Int, _ dt: Float, _ active: [Ledge], _ splats: inout [Int]) {
        var b = balls[i]
        let r = b.r
        let bottom0 = b.p.y - r
        b.v.y -= 1500 * dt
        b.v.x *= 1 - 0.15 * dt
        b.p += b.v * dt
        if hitCreature(at: b.p, radius: r, velocity: b.v) {
            balls[i] = b
            splats.append(b.uid)
            return
        }
        if b.p.x - r < 0 || b.p.x + r > size.x {
            if abs(b.v.x) > 350 {
                balls[i] = b
                splats.append(b.uid)
                return
            }
            b.p.x = min(max(b.p.x, r), size.x - r)
            b.v.x *= -0.3
        }
        if b.p.y < -r * 2 {
            balls[i] = b
            splats.append(b.uid)
            return
        }
        // Find what is under the ball: a drift or a resting ball.
        let bottom = b.p.y - r
        var supportTop = -Float.infinity
        var ledgeID: Int?
        var ballUID: Int?
        for l in active {
            guard let c = l.column(at: b.p.x), l.visible[c] else { continue }
            let top = l.y + l.h[c]
            if top <= bottom0 + 2 && top >= bottom - 1 && top > supportTop {
                supportTop = top
                ledgeID = l.id
                ballUID = nil
            }
        }
        for o in balls where o.uid != b.uid && o.state == .resting {
            let dx = b.p.x - o.p.x
            guard abs(dx) < o.r * 0.9 else { continue }
            let top = o.p.y + sqrt(max(0, o.r * o.r - dx * dx)) * 0.85
            if top <= bottom0 + 2 && top >= bottom - 1 && top > supportTop {
                supportTop = top
                ballUID = o.uid
                ledgeID = nil
            }
        }
        guard supportTop > -Float.infinity else {
            balls[i] = b
            return
        }
        let impact = simd_length(b.v)
        if impact > 520 {
            balls[i] = b
            splats.append(b.uid)
            if let o = ballUID, impact > 900 { splats.append(o) }
            return
        }
        b.state = .resting
        b.v = .zero
        if let id = ledgeID, let l = ledges[id] {
            b.supportLedge = id
            b.offset = SIMD2(b.p.x - l.x0, 0)
        } else if let o = ballUID, let j = ballIndex(o) {
            b.supportBall = o
            // Stack it centred, with a little give.
            let dx = (b.p.x - balls[j].p.x) * 0.3
            b.offset = SIMD2(dx, balls[j].r * 0.82 + r * 0.82)
        }
        balls[i] = b
        restBall(i)
        refreshSnowmen()
    }

    private func restBall(_ i: Int) {
        let r = balls[i].r
        if let id = balls[i].supportLedge {
            guard let l = ledges[id], let c = l.column(at: l.x0 + balls[i].offset.x), l.visible[c] else {
                if !settling { fall(i) }
                return
            }
            balls[i].p = SIMD2(l.x0 + balls[i].offset.x, l.y + l.h[c] + r * 0.82)
        } else if let o = balls[i].supportBall {
            guard let j = ballIndex(o), balls[j].state == .resting else {
                if settling { return }
                fall(i)
                return
            }
            balls[i].p = balls[j].p + balls[i].offset
        } else {
            fall(i)
        }
    }

    private func fall(_ i: Int) {
        balls[i].state = .flying
        balls[i].supportBall = nil
        balls[i].supportLedge = nil
        balls[i].v = SIMD2(rand(-20, 20), 0)
        balls[i].face = false
        balls[i].hat = false
    }

    private func loosenBalls(on ledge: Int, vanish: Bool = false) {
        for i in balls.indices where balls[i].supportLedge == ledge {
            fall(i)
        }
        refreshSnowmen()
    }

    private func loosenBalls(onBall uid: Int) {
        for i in balls.indices where balls[i].supportBall == uid {
            fall(i)
        }
    }

    /// The top ball of a stack of two or more gets a face; of three or more, a hat as well.
    private func refreshSnowmen() {
        for i in balls.indices {
            balls[i].face = false
            balls[i].hat = false
            balls[i].body = false
        }
        for i in balls.indices where balls[i].state == .resting && balls[i].supportBall != nil {
            let uid = balls[i].uid
            guard !balls.contains(where: { $0.supportBall == uid && $0.state == .resting }) else { continue }
            var height = 1
            var cursorUID = balls[i].supportBall
            while let u = cursorUID, let j = ballIndex(u) {
                height += 1
                cursorUID = balls[j].supportBall
                if height > 10 { break }
            }
            balls[i].face = height >= 2
            balls[i].hat = height >= 3
            if height >= 2, let below = balls[i].supportBall, let j = ballIndex(below) { balls[j].body = true }
        }
    }

    private func absorbIntoBall(_ f: inout Flake) -> Bool {
        guard !balls.isEmpty, f.kind == .flake else { return false }
        for i in balls.indices where balls[i].state != .flying {
            if simd_distance(balls[i].p, f.p) < balls[i].r {
                if balls[i].p.y < f.p.y { balls[i].volume += f.amount * 0.3 }
                return true
            }
        }
        return false
    }

    private func splat(_ b: Snowball) {
        let impact = simd_length(b.v)
        let pieces = min(max(Int(b.volume / 6), 10), 260)
        let each = b.volume * 0.92 / Float(pieces)
        for _ in 0..<pieces {
            let a = rand(0, .pi * 2)
            var dir = SIMD2(cos(a), sin(a))
            if dir.y < 0 { dir.y *= -0.4 }
            let s = rand(60, 260) * (0.6 + min(impact, 2000) / 1400)
            let at = b.p + dir * b.r * rand(0.1, 0.9)
            let v = dir * s + SIMD2(b.v.x * 0.2, -b.v.y * 0.05)
            addSpray(at: at, velocity: v, amount: each, r: rand(1.2, 2.8))
        }
    }
}
