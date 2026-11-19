import Foundation
import simd

/// A kid on a skateboard who turns up once the snow is deep, carves across it, pulls tricks, grinds along the
/// Dock and rides off the other side of the screen.
struct Skater {
    enum Trick { case none, kickflip, spin, grab, combo }

    var p: SIMD2<Float>                 // where the wheels touch
    var v: SIMD2<Float>
    var facing: Float
    var unit: Float                     // drawing scale: about a cat's size
    var onDock = false
    var airborne = false
    var tilt: Float = 0
    var crouch: Float = 0
    var flip: Float = 0                 // kickflip turns, 0...1 per flip
    var flipRate: Float = 0
    var spin: Float = 0                 // body rotation in radians
    var spinRate: Float = 0
    var grab: Float = 0
    var trick: Trick = .none
    var phase: Float = 0
    var nextPop: Float = rand(0.8, 1.6)
    var windup: Float = 0               // crouching before a jump
    var pendingJump: Float = 0          // the jump's upward speed once wound up
    var sprayTimer: Float = 0
}

extension SnowSimulation {
    private static let skaterGravity: Float = 1500

    /// Whether the snow is deep enough to be worth a visit.
    private var snowIsDeep: Bool {
        guard let g = ledges[Self.groundID] else { return false }
        let mean = g.total / max(g.width, 1)
        return mean > 14 || (g.h.max() ?? 0) > 45
    }

    /// Sends the skater in now (from the settings), whatever the snow.
    func callSkater() {
        guard skater == nil, ledges[Self.groundID] != nil else { return }
        spawnSkater()
    }

    private func spawnSkater() {
        let fromLeft = Bool.random()
        let unit = settings.catSize * 0.62
        skater = Skater(p: SIMD2(fromLeft ? -unit * 3 : size.x + unit * 3, 0),
                        v: SIMD2((fromLeft ? 1 : -1) * rand(330, 400), 0),
                        facing: fromLeft ? 1 : -1, unit: unit)
    }

    func updateSkater(_ dt: Float) {
        guard hostsCat, settings.skater else {
            skater = nil
            return
        }
        guard var s = skater else {
            skaterCooldown -= dt
            if skaterCooldown <= 0 {
                skaterCooldown = 20
                if snowIsDeep { spawnSkater() }
            }
            return
        }
        guard let ground = ledges[Self.groundID] else {
            skater = nil
            return
        }
        s.phase += dt * 5
        s.crouch = max(0, s.crouch - dt * 2.5)
        s.grab = max(0, s.grab - dt * 3)

        if s.airborne {
            fly(&s, dt, ground)
        } else {
            ride(&s, dt, ground)
        }
        scareCats(near: s)

        // Off the far side: gone until the snow piles up again.
        if s.facing > 0 ? s.p.x > size.x + s.unit * 4 : s.p.x < -s.unit * 4 {
            skater = nil
            skaterCooldown = rand(240, 420)
            return
        }
        skater = s
    }

    // MARK: - Riding

    private func surface(_ x: Float, on l: Ledge) -> Float {
        guard let c = l.column(at: min(max(x, l.x0), l.x0 + l.width - 0.01)) else { return l.y }
        return l.y + l.h[c]
    }

    private func ride(_ s: inout Skater, _ dt: Float, _ ground: Ledge) {
        let dock = ledges[Self.dockID]
        let l = s.onDock ? (dock ?? ground) : ground

        // Wind up, then pop.
        if s.windup > 0 {
            s.windup -= dt
            s.crouch = min(1, s.crouch + dt * 8)
            if s.windup <= 0 { pop(&s, vy: s.pendingJump) }
        }

        let x = s.p.x
        let here = surface(x, on: l)
        let ahead = surface(x + s.facing * 14, on: l)
        let slope = (ahead - here) / 14 * s.facing
        s.tilt += (atan(slope) * s.facing - s.tilt) * min(1, dt * 12)
        // Downhill speeds it up, uphill slows it; it pushes off to keep going.
        let speed = abs(s.v.x)
        var target = speed - slope * 600 * dt
        target += (370 - target) * min(1, dt * 0.8)
        s.v.x = s.facing * min(max(target, 220), 560)
        s.p.x += s.v.x * dt
        s.p.y = surface(s.p.x, on: l)

        // Carves a groove in the drift and throws up a spray behind.
        if let col = l.column(at: s.p.x), l.visible[col], l.h[col] > 1.5 {
            for k in -2...2 {
                let j = col + k
                guard j >= 0, j < l.h.count else { continue }
                l.h[j] = max(0, l.h[j] - 0.45)
            }
            l.restless = 30
            s.sprayTimer -= dt
            if s.sprayTimer <= 0 {
                s.sprayTimer = 0.03
                let tail = SIMD2(s.p.x - s.facing * s.unit * 0.6, s.p.y + 2)
                addSpray(at: tail, velocity: SIMD2(-s.facing * rand(60, 170), rand(50, 170)), amount: 1.2)
            }
        }

        if s.onDock, let dock {
            // Grinding along the Dock's glass; off the end with a trick.
            let end = s.facing > 0 ? dock.x0 + dock.width : dock.x0
            if (end - s.p.x) * s.facing < s.unit * 0.8 && s.windup <= 0 {
                s.pendingJump = rand(430, 520)
                s.windup = 0.12
            }
            return
        }
        guard s.windup <= 0 else { return }
        // Coming up on the Dock: a big ollie onto it.
        if let dock, dock.width > s.unit * 4 {
            let near = s.facing > 0 ? dock.x0 : dock.x0 + dock.width
            let distance = (near - s.p.x) * s.facing
            if distance > 0 && distance < abs(s.v.x) * 0.42 + s.unit {
                let rise = dock.y + (dock.h.max() ?? 0) - s.p.y + s.unit * 1.2
                s.pendingJump = sqrt(2 * Self.skaterGravity * max(rise, 40))
                s.windup = 0.1
                return
            }
        }
        // Pops an ollie now and then, more readily off a crest.
        s.nextPop -= dt
        let crest = slope < -0.25
        if s.nextPop <= 0 || (crest && s.nextPop < 0.6) {
            s.nextPop = rand(0.9, 1.9)
            s.pendingJump = rand(380, 560)
            s.windup = 0.1
        }
    }

    private func pop(_ s: inout Skater, vy: Float) {
        s.airborne = true
        s.onDock = false
        s.v.y = vy
        let airtime = 2 * vy / Self.skaterGravity
        let roll = Float.random(in: 0..<1)
        s.trick = airtime > 0.62 && roll < 0.3 ? .combo
            : airtime > 0.5 && roll < 0.55 ? .spin
            : roll < 0.8 ? .kickflip : .grab
        let turns: Float = s.trick == .combo ? 1 : 1
        s.flipRate = s.trick == .kickflip || s.trick == .combo ? turns / (airtime * 0.85) : 0
        s.spinRate = s.trick == .spin || s.trick == .combo ? -s.facing * 2 * .pi / (airtime * 0.9) : 0
        s.crouch = 0
    }

    private func fly(_ s: inout Skater, _ dt: Float, _ ground: Ledge) {
        let y0 = s.p.y
        s.v.y -= Self.skaterGravity * dt
        s.p += s.v * dt
        s.tilt *= 1 - min(1, dt * 4)
        s.flip = min(1, s.flip + s.flipRate * dt)
        if s.spinRate != 0 {
            s.spin += s.spinRate * dt
            if abs(s.spin) >= 2 * .pi { s.spin = 0; s.spinRate = 0 }
        }
        if s.trick == .grab || s.trick == .combo, s.v.y > -200 { s.grab = 1 }

        // Lands on the Dock's glass if it comes down over it, else on the ground.
        if s.v.y <= 0, let dock = ledges[Self.dockID], s.p.x > dock.x0, s.p.x < dock.x0 + dock.width {
            let top = surface(s.p.x, on: dock)
            if y0 >= top - 1 && s.p.y <= top {
                land(&s, at: top, on: dock)
                s.onDock = true
                return
            }
        }
        let top = surface(s.p.x, on: ground)
        if s.v.y <= 0 && s.p.y <= top {
            land(&s, at: top, on: ground)
        }
    }

    private func land(_ s: inout Skater, at top: Float, on l: Ledge) {
        s.airborne = false
        s.p.y = top
        s.v.y = 0
        s.flip = 0
        s.flipRate = 0
        s.spin = 0
        s.spinRate = 0
        s.trick = .none
        s.crouch = 1
        s.onDock = false
        let pieces = 14
        for _ in 0..<pieces {
            let a = rand(0.2, .pi - 0.2)
            addSpray(at: SIMD2(s.p.x, top + 2), velocity: SIMD2(cos(a) * rand(80, 220), sin(a) * rand(80, 220)), amount: 1.5)
        }
    }

    /// Cats in the way leap aside; sleeping ones sleep on.
    private func scareCats(near s: Skater) {
        for i in cats.indices {
            let c = cats[i]
            guard c.state != .sleeping, c.state != .airborne, c.state != .away else { continue }
            let d = c.center - (s.p + SIMD2(0, s.unit))
            if abs(d.x) < s.unit * 1.6 + c.size && abs(d.y) < s.unit * 1.8 {
                startle(&cats[i], from: s.p.x)
            }
        }
    }
}
