import Foundation
import simd

/// A robin that drops in now and then to hop about on a window, the Dock or the ground and peck at the snow.
/// The cats stalk it; it always gets away.
struct Bird {
    enum State { case arriving, perched, leaving }

    var p: SIMD2<Float>                 // its feet
    var v: SIMD2<Float> = .zero
    var state: State = .arriving
    var perch: SIMD2<Float>
    var perchLedge: Int
    var ledge: Int?
    var offset: Float = 0
    var lastLedge = SIMD2<Float>(repeating: 0)
    var facing: Float
    var unit: Float
    var phase: Float = 0
    var hop: Float = 0                  // height of the current hop
    var hopV: Float = 0
    var hopTimer: Float = rand(0.8, 2)
    var peck: Float = 0
    var peckTimer: Float = rand(0.6, 2)
    var timer: Float = rand(25, 45)

    var flying: Bool { state != .perched }
}

extension SnowSimulation {
    /// Sends a bird now (from the settings).
    func callBird() {
        guard bird == nil else { return }
        spawnBird()
    }

    func updateBird(_ dt: Float, _ active: [Ledge]) {
        guard hostsCat, settings.birds else {
            bird = nil
            return
        }
        guard var b = bird else {
            birdCooldown -= dt
            if birdCooldown <= 0 {
                birdCooldown = rand(150, 300)
                spawnBird()
            }
            return
        }
        b.phase += dt * (b.flying ? 26 : 3)
        switch b.state {
        case .arriving: arrive(&b, dt)
        case .perched: perch(&b, dt)
        case .leaving:
            b.v.x += (b.facing * 280 - b.v.x) * min(1, dt * 2)
            b.v.y = min(b.v.y + 700 * dt, 320)
            b.p += b.v * dt
            if b.p.y > size.y + 40 || b.p.x < -60 || b.p.x > size.x + 60 {
                bird = nil
                return
            }
        }
        bird = b
    }

    /// Somewhere to land: most often a window's top, else the Dock or the ground.
    private func spawnBird() {
        var choices: [(Ledge, Int)] = []
        for l in ledges.values {
            let weight = l.kind == .window ? 3 : 1
            let margin = 12
            guard l.h.count > margin * 2 else { continue }
            for _ in 0..<weight {
                let i = Int.random(in: margin..<(l.h.count - margin))
                // Never right beside a cat.
                let spot = SIMD2(l.centerX(i), l.y + l.h[i])
                let clear = cats.allSatisfy { simd_distance($0.center, spot) > $0.size * 5 }
                if l.visible[i] && clear { choices.append((l, i)) }
            }
        }
        guard let (l, i) = choices.randomElement() else { return }
        let fromLeft = Bool.random()
        let perch = SIMD2(l.centerX(i), l.y + l.h[i])
        bird = Bird(p: SIMD2(fromLeft ? -30 : size.x + 30, size.y * rand(0.6, 0.9)), perch: perch, perchLedge: l.id,
                    facing: fromLeft ? 1 : -1, unit: settings.catSize * 0.46)
    }

    private func arrive(_ b: inout Bird, _ dt: Float) {
        // Keep up with a perch that moves (its window dragged) or goes away.
        guard let l = ledges[b.perchLedge], let col = l.column(at: b.perch.x), l.visible[col] else {
            leave(&b)
            return
        }
        b.perch.y = l.y + l.h[col]
        let to = b.perch - b.p
        let distance = simd_length(to)
        let speed = min(260, distance * 2.5 + 40)
        let want = distance > 0.01 ? to / distance * speed : .zero
        b.v += (want - b.v) * min(1, dt * 4)
        b.p += b.v * dt
        b.p.y += sin(b.phase * 0.25) * 12 * dt
        if abs(b.v.x) > 5 { b.facing = b.v.x > 0 ? 1 : -1 }
        if distance < 5 {
            b.state = .perched
            b.ledge = l.id
            b.offset = b.perch.x - l.x0
            b.lastLedge = SIMD2(l.x0, l.y)
            b.v = .zero
        }
    }

    private func perch(_ b: inout Bird, _ dt: Float) {
        guard let id = b.ledge, let l = ledges[id] else {
            leave(&b)
            return
        }
        // A window moving under it, or anything coming too close, and it's off.
        let at = SIMD2(l.x0, l.y)
        let moved = simd_length(at - b.lastLedge)
        b.lastLedge = at
        if moved > 3 || danger(near: b) {
            leave(&b)
            return
        }
        b.timer -= dt
        if b.timer <= 0 {
            leave(&b)
            return
        }

        // Hop about and peck at the snow.
        b.hopTimer -= dt
        if b.hopTimer <= 0 && b.hop <= 0 {
            b.hopTimer = rand(0.6, 2.2)
            if Float.random(in: 0..<1) < 0.35 { b.facing = -b.facing }
            let step = b.facing * rand(5, 14)
            let next = b.offset + step
            if let col = l.column(at: l.x0 + next), l.visible[col], next > 8, next < l.width - 8 {
                b.offset = next
            } else {
                b.facing = -b.facing
            }
            b.hopV = rand(70, 110)
        }
        b.hopV -= 600 * dt
        b.hop = max(0, b.hop + b.hopV * dt)
        if b.hop == 0 { b.hopV = 0 }
        b.peckTimer -= dt
        if b.peckTimer <= 0 {
            b.peckTimer = rand(0.5, 2)
            b.peck = 1
            if let col = l.column(at: l.x0 + b.offset + b.facing * b.unit * 0.8), l.h[col] > 1 {
                l.h[col] -= 0.4
            }
        }
        b.peck = max(0, b.peck - dt * 3.5)

        guard let col = l.column(at: l.x0 + b.offset), l.visible[col] else {
            leave(&b)
            return
        }
        let depth = l.h[col]
        b.p = SIMD2(l.x0 + b.offset, l.y + depth - min(depth, 3) * 0.4 + b.hop)
    }

    /// A cat too close or leaping, or the cursor rushing at it.
    private func danger(near b: Bird) -> Bool {
        for c in cats {
            let d = simd_distance(c.center, b.p)
            if d < c.size * 1.6 || (c.state == .airborne && d < c.size * 2.5) { return true }
        }
        if let cur = cursor, simd_distance(cur, b.p) < 80, simd_length(cursorVelocity) > 150 { return true }
        return false
    }

    private func leave(_ b: inout Bird) {
        b.state = .leaving
        b.ledge = nil
        if Bool.random() { b.facing = -b.facing }
        b.v = SIMD2(b.facing * 120, 220)
    }
}
