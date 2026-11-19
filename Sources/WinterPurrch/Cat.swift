import Foundation
import simd

/// The cat that lives in the snow: it wanders the drifts, climbs onto windows, plays in the snow on the Dock,
/// fetches coffee, jumps when it is hit and purrs when it is petted.
struct Cat {
    enum State { case walking, sitting, sleeping, playing, airborne, away, shaking, flopped, digging, grooming }
    enum Errand: Equatable { case none, leaving, returning(target: Float, ledge: Int) }

    var p: SIMD2<Float>                 // the point on the ground between its feet
    var v = SIMD2<Float>(repeating: 0)
    var ledge: Int?
    var offset: Float = 0               // where it stands along its ledge
    var lastLedge = SIMD2<Float>(repeating: 0)
    var facing: Float = 1
    var state: State = .airborne
    var timer: Float = 2
    var phase: Float = 0                // walk cycle, or the swing of a playing paw
    var size: Float = 18
    var carrying = false
    var errand: Errand = .none
    var descend = false                 // wants to hop down at the end of its ledge
    var nextCoffee: Float = rand(35, 60)
    var nextPlay: Float = rand(15, 30)
    var blinkTimer: Float = rand(2, 5)
    var blink: Float = 0
    var startle: Float = 0
    var petting: Float = 0
    var heartTimer: Float = 0
    var stepTravel: Float = 0
    var swatTimer: Float = 0
    var snowy: Float = 0                // how much snow is stuck in its fur
    var shake: Float = 0                // time left shaking it off
    var fleeing: Float = 0              // time left scurrying away after a fright
    var angle: Float = 0                // tumbling through the air
    var coat = 0                        // 0 grey-and-white longhair, 1 ginger tabby
    var groomBack = false               // licking its back rather than a paw
    enum Social { case none, licking, licked }
    var social: Social = .none          // washing its friend, or being washed
    var seeking = false                 // on its way to its friend
    var stroking: Float = 0             // how long the cursor has been stroking it
    var look: Float = 0                 // 1 looking at the viewer, 0 looking where it is going
    var lookTime: Float = 0
    var lookCooldown: Float = rand(4, 10)
    var spin: Float = 0
    var tumbling = false

    var center: SIMD2<Float> { p + SIMD2(0, size * 0.9) }

    /// 0 walk, 1 sit, 2 sleep, 3 airborne, 4 playing (crouched, swatting).
    var pose: Float {
        switch state {
        case .walking, .away: return 0
        case .sitting:
            if petting > 0.6 { return 8 }
            switch social {
            case .licking: return 11
            case .licked: return 12
            case .none: return 1
            }
        case .sleeping: return 2
        case .airborne: return 3
        case .playing: return 4
        case .shaking: return 5
        case .flopped: return 6
        case .digging: return 7
        case .grooming: return groomBack ? 10 : 9
        }
    }

    func contains(_ point: SIMD2<Float>) -> Bool {
        guard state != .away else { return false }
        let d = point - center
        return abs(d.x) < size * 1.3 && abs(d.y) < size * 1.1
    }
}

struct Mug {
    var p: SIMD2<Float>                 // its base
    var v = SIMD2<Float>(repeating: 0)
    var ledge: Int?
    var offset: Float = 0
    var age: Float = 0
    var resting = false
    static var size: Float = 13

    var center: SIMD2<Float> { p + SIMD2(0, Mug.size * 0.9) }
}

struct Heart {
    var isZ = false
    var p: SIMD2<Float>
    var v: SIMD2<Float>
    var life: Float = 1
    var seed: Float = rand(0, 6.28)
}

extension SnowSimulation {
    private static let gravity: Float = 1300

    func spawnCat(coat: Int = 0) {
        var c = Cat(p: SIMD2(size.x * (coat == 0 ? 0.35 : 0.6), size.y * 0.75))
        c.coat = coat
        c.size = settings.catSize * (coat == 0 ? 1 : 0.94)
        c.state = .airborne
        c.facing = coat == 0 ? 1 : -1
        cats.append(c)
    }

    /// Drops a lost cat back in from the top, keeping who it is.
    private func respawn(_ c: inout Cat, x: Float) {
        let coat = c.coat, size = c.size
        c = Cat(p: SIMD2(x, self.size.y + 30))
        c.coat = coat
        c.size = size
        c.state = .airborne
    }

    // MARK: - Touch

    func creatureUnder(_ point: SIMD2<Float>) -> Bool {
        if cats.contains(where: { $0.contains(point) }) { return true }
        return mugs.contains { simd_distance($0.center, point) < Mug.size * 1.6 }
    }

    /// A click: the cat jumps; a mug gets drunk. Returns whether something was there.
    func poke(at point: SIMD2<Float>) -> Bool {
        if let i = cats.firstIndex(where: { $0.contains(point) }) {
            // A cat already in the air can't be startled again.
            if cats[i].state != .airborne { startle(&cats[i], from: point.x) }
            return true
        }
        if let i = mugs.firstIndex(where: { simd_distance($0.center, point) < Mug.size * 1.6 }) {
            let m = mugs.remove(at: i)
            for _ in 0..<3 { hearts.append(Heart(p: m.center + SIMD2(rand(-4, 4), 6), v: SIMD2(rand(-15, 15), rand(30, 50)))) }
            return true
        }
        return false
    }

    /// A flying snowball reaching the cat or a mug. Returns whether it hit something.
    func hitCreature(at point: SIMD2<Float>, radius: Float, velocity: SIMD2<Float>) -> Bool {
        if let i = cats.firstIndex(where: { $0.state != .away && simd_distance(point, $0.center) < radius + $0.size * 0.9 }) {
            var c = cats[i]
            // Snow in its fur: it stays put and shakes it off (once back on its feet).
            if c.carrying { dropCarriedMug(c) }
            c.carrying = false
            c.errand = .none
            c.snowy = 1
            c.startle = 0.6
            c.facing = velocity.x >= 0 ? 1 : -1
            if c.state != .airborne { beginShaking(&c) }
            cats[i] = c
            return true
        }
        if let i = mugs.firstIndex(where: { simd_distance($0.center, point) < radius + Mug.size }) {
            mugs[i].resting = false
            mugs[i].ledge = nil
            mugs[i].v = velocity * 0.3 + SIMD2(0, 220)
            return true
        }
        return false
    }

    /// A fright from `x`: a short hop straight up with its fur on end, then a dash the other way.
    private func startle(_ c: inout Cat, from x: Float) {
        c.social = .none
        c.seeking = false
        if c.carrying { dropCarriedMug(c) }
        c.carrying = false
        c.errand = .none
        c.state = .airborne
        c.ledge = nil
        c.startle = 1
        let away: Float = c.p.x >= x ? 1 : -1
        c.facing = away
        c.v = SIMD2(away * c.size * 2.2, sqrt(2 * Self.gravity * c.size * 1.4))
        c.fleeing = rand(0.7, 1.2)
    }

    private func beginShaking(_ c: inout Cat) {
        c.state = .shaking
        c.shake = 1.1
        c.v = .zero
    }

    /// Shakes the snow out of its fur, flinging it about.
    private func shakeOff(_ c: inout Cat, _ dt: Float) {
        c.shake -= dt
        if c.snowy > 0 {
            let lose = min(c.snowy, dt * 1.1)
            c.snowy -= lose
            let pieces = Int(rand(1, 4))
            for _ in 0..<pieces {
                let side: Float = Bool.random() ? 1 : -1
                let at = c.p + SIMD2(rand(-0.8, 0.8) * c.size, rand(0.6, 1.4) * c.size)
                addSpray(at: at, velocity: SIMD2(side * rand(60, 200), rand(40, 220)), amount: 6 * c.size / 18 * lose / dt / Float(pieces) * 0.1)
            }
        }
        if c.shake <= 0 {
            c.snowy = 0
            if Float.random(in: 0..<1) < 0.6 {
                // Then puts its fur straight.
                startGrooming(&c)
                return
            }
            c.state = .walking
            c.facing = -c.facing
            c.fleeing = rand(0.5, 0.9)
            c.timer = rand(1.5, 3)
        }
    }

    private func dropCarriedMug(_ c: Cat) {
        var m = Mug(p: c.p + SIMD2(c.facing * c.size * 1.1, c.size * 0.4))
        m.v = SIMD2(c.facing * 60, 120)
        mugs.append(m)
    }

    // MARK: - Step

    func updateCat(_ dt: Float, _ active: [Ledge]) {
        updateMugs(dt, active)
        updateHearts(dt)
        for i in cats.indices {
            var c = cats[i]
            step(&c, dt, active)
            cats[i] = c
        }
        socialize(dt)
    }

    private func step(_ c: inout Cat, _ dt: Float, _ active: [Ledge]) {
        c.blinkTimer -= dt
        if c.blinkTimer < 0 {
            c.blink = 1
            c.blinkTimer = rand(2.5, 6)
        }
        c.blink = max(0, c.blink - dt * 6)
        c.startle = max(0, c.startle - dt * 1.2)
        if c.errand == .none && !c.carrying {
            c.nextCoffee -= dt
            c.nextPlay -= dt
        }

        switch c.state {
        case .airborne: fly(&c, dt, active)
        case .away: away(&c, dt)
        default: grounded(&c, dt, active)
        }
        pet(&c, dt)
    }

    // MARK: - Friends

    /// Two cats that are friends: they look for each other, and when they meet they touch noses, wash each other,
    /// curl up together for a nap, play-fight or play tag. One sometimes tags along after the other.
    private func socialize(_ dt: Float) {
        guard cats.count >= 2 else { return }
        friendCooldown -= dt
        friendSeek -= dt
        var a = cats[0], b = cats[1]
        defer {
            cats[0] = a
            cats[1] = b
        }
        let settled: Set<Cat.State> = [.walking, .sitting]
        let free = { (c: Cat) in c.ledge != nil && settled.contains(c.state) && c.errand == .none && c.fleeing <= 0 && c.petting < 0.3 }
        guard free(a), free(b) else { return }

        // Apart for a while, one goes to find the other.
        let apart = a.ledge != b.ledge || abs(b.p.x - a.p.x) > (a.size + b.size) * 3
        if apart {
            guard friendSeek <= 0 else { return }
            friendSeek = rand(30, 60)
            if Bool.random() { seek(&a, b) } else { seek(&b, a) }
            friendCooldown = min(friendCooldown, 0)
            return
        }
        guard let ledgeID = a.ledge, let l = ledges[ledgeID] else { return }
        let dx = b.p.x - a.p.x
        let side: Float = dx >= 0 ? 1 : -1

        // One heads off and the other tags along behind.
        if friendCooldown > 0 && a.state != b.state && Float.random(in: 0..<1) < dt * 0.08 {
            if a.state == .walking { follow(&b, a) } else { follow(&a, b) }
            return
        }

        let near = abs(dx) < (a.size + b.size) * 1.2
        guard near else { return }
        if friendCooldown <= 0 {
            friendCooldown = rand(18, 35)
            a.seeking = false
            b.seeking = false
            let roll = Float.random(in: 0..<1)
            if roll < 0.22 {
                // Nose to nose, with a heart between them.
                placeSideBySide(&a, &b, side: side, gap: 0.62, on: l)
                for i in 0..<2 {
                    var c = i == 0 ? a : b
                    c.state = .sitting
                    c.social = .none
                    c.timer = rand(3, 4.5)
                    c.facing = i == 0 ? side : -side
                    if i == 0 { a = c } else { b = c }
                }
                heartsBetween(a, b, 3)
            } else if roll < 0.45 {
                // One washes the other's head; the other shuts its eyes and enjoys it.
                placeSideBySide(&a, &b, side: side, gap: 0.5, on: l)
                let first = Bool.random()
                var groomer = first ? a : b, groomed = first ? b : a
                let toward: Float = first ? side : -side
                groomer.state = .sitting
                groomer.social = .licking
                groomer.facing = toward
                groomer.timer = rand(4, 6)
                groomed.state = .sitting
                groomed.social = .licked
                groomed.facing = -toward
                groomed.timer = groomer.timer
                if first { a = groomer; b = groomed } else { b = groomer; a = groomed }
                heartsBetween(a, b, 1)
            } else if roll < 0.63 {
                // Curled up together, heads in the middle.
                placeSideBySide(&a, &b, side: side, gap: 0.46, on: l)
                let nap = rand(18, 30)
                for i in 0..<2 {
                    var c = i == 0 ? a : b
                    c.state = .sleeping
                    c.timer = nap
                    c.facing = i == 0 ? side : -side
                    if i == 0 { a = c } else { b = c }
                }
            } else if roll < 0.8 {
                // Play-fighting: crouched face to face, batting and pouncing.
                placeSideBySide(&a, &b, side: side, gap: 0.8, on: l)
                for i in 0..<2 {
                    var c = i == 0 ? a : b
                    c.state = .playing
                    c.timer = rand(3, 5)
                    c.swatTimer = rand(0.1, 0.4)
                    c.facing = i == 0 ? side : -side
                    if i == 0 { a = c } else { b = c }
                }
            } else {
                // Tag: one bolts, the other gives chase.
                let runner = Bool.random()
                var r = runner ? a : b, chaser = runner ? b : a
                let away: Float = runner ? -side : side
                r.state = .walking
                r.facing = away
                r.fleeing = rand(1.8, 2.6)
                chaser.state = .walking
                chaser.facing = away
                chaser.fleeing = r.fleeing + 0.3
                if runner { a = r; b = chaser } else { b = r; a = chaser }
            }
            return
        }
        // Walking into its friend, it turns aside.
        if a.state == .walking && !a.seeking && a.facing == side && abs(dx) < (a.size + b.size) * 0.7 { a.facing = -side }
        if b.state == .walking && !b.seeking && b.facing == -side && abs(dx) < (a.size + b.size) * 0.7 { b.facing = side }
    }

    /// Walks over to its friend, or leaps up to the ledge its friend is on.
    private func seek(_ c: inout Cat, _ friend: Cat) {
        c.seeking = true
        c.social = .none
        if c.ledge == friend.ledge {
            c.state = .walking
            c.facing = friend.p.x >= c.p.x ? 1 : -1
            c.timer = 15
            return
        }
        guard let id = friend.ledge, let l = ledges[id] else { return }
        let side: Float = c.p.x <= friend.p.x ? -1 : 1
        let x = min(max(friend.p.x + side * (c.size + friend.size) * 0.7, l.x0 + c.size), l.x0 + l.width - c.size)
        guard let col = l.column(at: x), l.visible[col] else { return }
        let rise = l.y - c.p.y
        if abs(x - c.p.x) < 420 && rise < 340 {
            jump(&c, to: SIMD2(x, l.y + l.h[col]))
        } else {
            // Too far to leap: head that way and see.
            c.state = .walking
            c.facing = friend.p.x >= c.p.x ? 1 : -1
            c.timer = 6
            c.descend = l.y < c.p.y
        }
    }

    private func follow(_ c: inout Cat, _ leader: Cat) {
        c.state = .walking
        c.social = .none
        c.facing = leader.facing
        c.timer = leader.timer + rand(0.2, 0.8)
    }

    private func placeSideBySide(_ a: inout Cat, _ b: inout Cat, side: Float, gap: Float, on l: Ledge) {
        let middle = (a.offset + b.offset) / 2
        let half = (a.size + b.size) * gap
        a.offset = min(max(middle - side * half, 0), l.width)
        b.offset = min(max(middle + side * half, 0), l.width)
    }

    private func heartsBetween(_ a: Cat, _ b: Cat, _ count: Int) {
        let mid = (a.center + b.center) / 2 + SIMD2(0, a.size * 1.2)
        for k in 0..<count {
            hearts.append(Heart(p: mid + SIMD2(rand(-6, 6), Float(k) * 6), v: SIMD2(rand(-10, 10), rand(28, 42))))
        }
    }

    private func fly(_ c: inout Cat, _ dt: Float, _ active: [Ledge]) {
        let y0 = c.p.y
        c.v.y -= Self.gravity * dt
        c.p += c.v * dt
        c.angle += c.spin * dt
        let margin = c.size
        if c.p.x < margin && c.v.x < 0 || c.p.x > size.x - margin && c.v.x > 0 {
            c.v.x *= -0.4
        }
        c.p.x = min(max(c.p.x, margin), size.x - margin)
        if c.v.y <= 0, let (l, _) = landing(x: c.p.x, from: y0, to: c.p.y, active) {
            settle(&c, on: l)
            kick(at: c.p, toward: c.v.x >= 0 ? 1 : -1, amount: 14, on: l)
            c.v = .zero
            c.angle = 0
            c.spin = 0
            if c.tumbling {
                // Lands in a heap, legs in the air.
                c.tumbling = false
                flop(&c, on: l)
            } else if c.carrying, case .returning = c.errand {
                c.state = .walking
            } else if c.snowy > 0.2 {
                beginShaking(&c)
            } else if c.fleeing > 0 {
                c.state = .walking
                c.timer = 3
            } else {
                c.state = .sitting
                c.timer = rand(0.8, 1.6)
            }
        }
        if c.p.y < -80 { respawn(&c, x: rand(0.2, 0.8) * size.x) }
    }

    private func settle(_ c: inout Cat, on l: Ledge) {
        c.ledge = l.id
        c.offset = c.p.x - l.x0
        c.lastLedge = SIMD2(l.x0, l.y)
    }

    private func away(_ c: inout Cat, _ dt: Float) {
        c.timer -= dt
        guard c.timer <= 0 else { return }
        guard let ground = ledges[Self.groundID] else {
            respawn(&c, x: size.x * 0.5)
            return
        }
        // Back from the kitchen with a mug, from either side, to somewhere new each time.
        let fromLeft = Bool.random()
        c.offset = fromLeft ? -c.size * 2 : ground.width + c.size * 2
        c.facing = fromLeft ? 1 : -1
        c.ledge = ground.id
        c.lastLedge = SIMD2(ground.x0, ground.y)
        c.carrying = true
        var low = size.x * 0.06, high = size.x * 0.94
        if let dock = ledges[Self.dockID] {
            // The ground under the Dock is behind its glass: stay on the near side of it.
            if fromLeft { high = min(high, dock.x0 - c.size * 3) } else { low = max(low, dock.x0 + dock.width + c.size * 3) }
        }
        if let dock = ledges[Self.dockID], dock.width > c.size * 6, Float.random(in: 0..<1) < 0.35 {
            // Up onto the Dock's glass with it.
            let x = rand(dock.x0 + c.size * 2, dock.x0 + dock.width - c.size * 2)
            c.errand = .returning(target: x, ledge: dock.id)
        } else {
            let spot = high > low ? rand(low, high) : (fromLeft ? low : high)
            c.errand = .returning(target: spot, ledge: ground.id)
        }
        c.state = .walking
    }

    private func grounded(_ c: inout Cat, _ dt: Float, _ active: [Ledge]) {
        guard let id = c.ledge, let l = ledges[id] else {
            fall(&c)
            return
        }
        // Carried along by a window moving slowly; thrown off by one dragged or shaken.
        let ledgeAt = SIMD2(l.x0, l.y)
        let moved = ledgeAt - c.lastLedge
        c.lastLedge = ledgeAt
        if simd_length(moved) > 12 {
            startle(&c, from: c.p.x - moved.x)
            c.v.x += moved.x / max(dt, 1.0 / 60) * 0.15
            return
        }

        switch c.state {
        case .walking: walk(&c, l, dt, active)
        case .sitting: sit(&c, l, dt, active)
        case .sleeping:
            c.timer -= dt
            if c.timer <= 0 { c.stroking = 0 }
            // Little z's drift up from a sleeping cat.
            c.swatTimer -= dt
            if c.swatTimer <= 0 {
                c.swatTimer = rand(1.1, 1.6)
                let head = c.p + SIMD2(c.facing * c.size * 0.75, c.size * 1.0)
                var z = Heart(p: head, v: SIMD2(c.facing * rand(6, 12), rand(16, 24)))
                z.isZ = true
                hearts.append(z)
            }
            if c.timer <= 0 {
                c.state = .sitting
                c.timer = 1.5
            }
        case .playing: play(&c, l, dt, active)
        case .shaking: shakeOff(&c, dt)
        case .flopped:
            c.timer -= dt
            if c.timer <= 0 {
                // Up again, a little embarrassed, and the snow shaken off.
                c.snowy = max(c.snowy, 0.5)
                beginShaking(&c)
            }
        case .digging: dig(&c, l, dt)
        case .grooming:
            c.timer -= dt
            if c.timer <= 0 {
                c.state = .sitting
                c.timer = rand(1, 2)
            }
        default: break
        }
        guard c.state != .airborne, c.state != .away, c.ledge == l.id else { return }

        let x = l.x0 + c.offset
        if let col = l.column(at: x) {
            guard l.visible[col] else {
                fall(&c)
                return
            }
            let depth = l.h[col]
            c.p = SIMD2(x, l.y + depth - min(depth, 5) * 0.5)
        } else if l.kind == .ground {
            c.p = SIMD2(x, l.y)       // walking off the side of the screen, or back on
        } else {
            fall(&c)
        }
    }

    private func walk(_ c: inout Cat, _ l: Ledge, _ dt: Float, _ active: [Ledge]) {
        var speed: Float = (c.errand == .none ? 36 : 72) * c.size / 18
        if c.fleeing > 0 {
            speed *= 3
            c.fleeing -= dt
            if c.fleeing <= 0 {
                c.state = .sitting
                c.timer = rand(2, 4)
            }
        }
        c.offset += c.facing * speed * dt
        c.phase += dt * speed * 0.17 * 18 / c.size
        c.stepTravel += speed * dt
        if c.stepTravel > c.size * 0.6 {
            c.stepTravel = 0
            pawPrint(at: l.x0 + c.offset + c.facing * c.size * 0.4, on: l)
        }

        if case .returning(let target, let goal) = c.errand, goal != l.id, let dock = ledges[goal], l.kind == .ground {
            // Heading for the Dock: leap up from beside it.
            let edge = c.facing > 0 ? dock.x0 : dock.x0 + dock.width
            if abs(l.x0 + c.offset - edge) < 110 + c.size, c.facing * (edge - (l.x0 + c.offset)) > 0 {
                let landX = min(max(edge + c.facing * c.size * 2.5, dock.x0 + c.size), dock.x0 + dock.width - c.size)
                if let col = dock.column(at: landX) {
                    jump(&c, to: SIMD2(landX, dock.y + dock.h[col]))
                    _ = target
                    return
                }
            }
        }
        if case .returning(let target, let goal) = c.errand, goal == l.id, abs(l.x0 + c.offset - target) < 4,
           l.column(at: l.x0 + c.offset) != nil {
            // Sets the mug down in front of itself and sits back, pleased.
            var m = Mug(p: c.p + SIMD2(c.facing * c.size * 1.25, 0))
            m.ledge = l.id
            m.offset = c.offset + c.facing * c.size * 1.25
            m.resting = true
            mugs.append(m)
            if mugs.count > 5 { mugs.removeFirst() }
            c.carrying = false
            c.errand = .none
            c.nextCoffee = rand(60, 120)
            c.state = .sitting
            c.timer = 5
            for k in 0..<3 {
                hearts.append(Heart(p: c.center + SIMD2(c.facing * c.size * 0.6, c.size * 0.8 + Float(k) * 4),
                                    v: SIMD2(rand(-12, 12), rand(25, 45))))
            }
            return
        }

        let margin = c.size * 0.7
        let x = l.x0 + c.offset
        let ahead = l.column(at: x + c.facing * margin)
        let atEnd = ahead == nil || !(l.visible[ahead!])
            || (underDock(x + c.facing * margin, on: l) && !underDock(x, on: l))
        if c.errand == .leaving && l.kind == .ground {
            if c.offset < -c.size * 2 || c.offset > l.width + c.size * 2 {
                c.state = .away
                c.timer = rand(3, 5)
            }
            return
        }
        if case .returning(let target, let goal) = c.errand {
            // Coming in from off screen: only the far end counts. On the Dock, it turns towards its spot.
            if goal == l.id && c.facing * (target - x) < 0 && l.column(at: x) != nil { c.facing = -c.facing }
            if atEnd && l.column(at: x) != nil { c.facing = -c.facing }
            return
        }
        // Now and then it trips over its own paws.
        if c.fleeing <= 0 && Float.random(in: 0..<1) < dt * 0.012 {
            flop(&c, on: l)
            return
        }
        if atEnd {
            if l.kind == .window && Float.random(in: 0..<1) < 0.3 {
                // Misjudges the edge and tumbles off it (not off the Dock, whose ground lies behind its glass).
                c.state = .airborne
                c.ledge = nil
                c.tumbling = true
                c.v = SIMD2(c.facing * rand(50, 90), rand(40, 120))
                c.spin = -c.facing * rand(5, 8)
            } else if l.kind != .ground && (c.descend || Bool.random()) {
                c.descend = false
                hop(&c, SIMD2(c.facing * 110, 260))
            } else {
                c.facing = -c.facing
            }
            return
        }
        c.timer -= dt
        if c.timer <= 0 {
            c.state = .sitting
            c.timer = rand(2, 6)
        }
    }

    private func sit(_ c: inout Cat, _ l: Ledge, _ dt: Float, _ active: [Ledge]) {
        c.timer -= dt
        if c.social != .none, Float.random(in: 0..<1) < dt * 2 {
            heartsAbove(c)
        }
        guard c.timer <= 0, c.petting < 0.5 else { return }
        c.social = .none
        let roll = Float.random(in: 0..<1)
        if c.nextCoffee <= 0 && l.kind == .ground && mugs.count < 5 {
            c.errand = .leaving
            c.facing = l.x0 + c.offset < size.x / 2 ? -1 : 1
            c.state = .walking
        } else if c.nextPlay <= 0, let dock = ledges[Self.dockID], snowy(dock) {
            if l.id == dock.id {
                startPlaying(&c)
            } else if let target = landingSpot(on: dock, from: c) {
                jump(&c, to: target)
            } else {
                wander(&c)
            }
        } else if Float.random(in: 0..<1) < 0.22 {
            startGrooming(&c)
        } else if l.kind == .dock && snowy(l) && roll < 0.3 {
            startPlaying(&c)
        } else if roll < 0.45, depth(under: c, on: l) > 3 {
            startDigging(&c)
        } else if l.kind != .ground && roll < 0.3 {
            c.descend = true
            wander(&c)
        } else if roll < 0.2, let target = climbTarget(from: c, active) {
            jump(&c, to: target)
        } else if roll < 0.42 {
            c.state = .sleeping
            c.timer = rand(15, 35)
        } else {
            wander(&c)
        }
    }

    /// The stretch of ground hidden behind the Dock, which the cat walks around rather than through.
    private func underDock(_ x: Float, on l: Ledge) -> Bool {
        guard l.kind == .ground, let dock = ledges[Self.dockID] else { return false }
        return x > dock.x0 - 20 && x < dock.x0 + dock.width + 20
    }

    private func wander(_ c: inout Cat) {
        c.state = .walking
        if Bool.random() { c.facing = -c.facing }
        c.timer = rand(3, 9)
    }

    // MARK: - Playing in the snow

    private func snowy(_ l: Ledge) -> Bool { l.total / max(l.width, 1) > 2 }

    private func depth(under c: Cat, on l: Ledge) -> Float {
        guard let col = l.column(at: l.x0 + c.offset + c.facing * c.size * 0.8) else { return 0 }
        return l.h[col]
    }

    /// Flat on its side in the snow, legs in the air, with a puff of powder and a cat-shaped dent.
    private func flop(_ c: inout Cat, on l: Ledge) {
        c.state = .flopped
        c.timer = rand(1.4, 2.4)
        c.fleeing = 0
        c.angle = 0
        let x = l.x0 + c.offset
        kick(at: SIMD2(x - c.size * 0.5, c.p.y), toward: -1, amount: 16, on: l)
        kick(at: SIMD2(x + c.size * 0.5, c.p.y), toward: 1, amount: 16, on: l)
    }

    private func heartsAbove(_ c: Cat) {
        guard c.social == .licked else { return }
        hearts.append(Heart(p: c.center + SIMD2(0, c.size * 1.3), v: SIMD2(rand(-8, 8), rand(25, 35))))
    }

    private func startGrooming(_ c: inout Cat) {
        c.state = .grooming
        c.groomBack = Bool.random()
        c.timer = rand(3, 6)
    }

    private func startDigging(_ c: inout Cat) {
        c.state = .digging
        c.timer = rand(2.5, 5)
        c.swatTimer = 0
        c.phase = 0
    }

    /// Paws at the drift in front of it, throwing the snow back between its legs.
    private func dig(_ c: inout Cat, _ l: Ledge, _ dt: Float) {
        c.timer -= dt
        c.swatTimer -= dt
        c.phase += dt * 22
        if c.swatTimer <= 0 {
            c.swatTimer = 0.1
            let paw = l.x0 + c.offset + c.facing * c.size * 0.75
            guard let col = l.column(at: paw) else { return }
            var taken: Float = 0
            for k in -2...2 {
                let j = col + k
                guard j >= 0, j < l.h.count, l.visible[j] else { continue }
                let cut = min(l.h[j], 0.6)
                l.h[j] -= cut
                taken += cut * columnWidth
            }
            if taken > 0.3 {
                l.restless = 60
                for _ in 0..<3 {
                    let v = SIMD2(-c.facing * rand(90, 240), rand(90, 260))
                    addSpray(at: SIMD2(paw - c.facing * c.size * 0.6, l.y + l.h[col] + 3), velocity: v, amount: taken / 3)
                }
            } else {
                c.timer = min(c.timer, 0.3)    // dug down to the bottom
            }
        }
        if c.timer <= 0 {
            c.state = .sitting
            c.timer = rand(1.5, 3)
        }
    }

    private func startPlaying(_ c: inout Cat) {
        c.state = .playing
        c.timer = rand(6, 12)
        c.swatTimer = 0.3
        c.phase = 0
        c.nextPlay = rand(25, 50)
    }

    /// Crouched in the drift, it bats at the snow, sends it flying and now and then pounces on it.
    private func play(_ c: inout Cat, _ l: Ledge, _ dt: Float, _ active: [Ledge]) {
        c.timer -= dt
        c.swatTimer -= dt
        c.phase += dt * 9
        if c.swatTimer <= 0 {
            let paw = l.x0 + c.offset + c.facing * c.size * 1.0
            kick(at: SIMD2(paw, c.p.y), toward: c.facing, amount: rand(10, 22), on: l)
            c.swatTimer = rand(0.35, 0.8)
            let roll = Float.random(in: 0..<1)
            if roll < 0.18 {
                // Pounce.
                hop(&c, SIMD2(c.facing * rand(70, 120), rand(220, 300)))
                return
            } else if roll < 0.35 {
                c.facing = -c.facing
            }
        }
        if c.timer <= 0 {
            c.state = .sitting
            c.timer = rand(2, 4)
        }
    }

    /// Scoops snow from around `point` and flings it as powder.
    private func kick(at point: SIMD2<Float>, toward dir: Float, amount: Float, on l: Ledge) {
        guard let col = l.column(at: point.x) else { return }
        var taken: Float = 0
        for k in -2...2 {
            let j = col + k
            guard j >= 0, j < l.h.count, l.visible[j] else { continue }
            let cut = min(l.h[j], amount / 10)
            l.h[j] -= cut
            taken += cut * columnWidth
        }
        guard taken > 0.5 else { return }
        l.restless = 60
        let pieces = min(max(Int(taken / 3), 2), 14)
        for _ in 0..<pieces {
            let v = SIMD2(dir * rand(40, 170), rand(80, 220))
            addSpray(at: SIMD2(point.x, l.y + l.h[col] + 2), velocity: v, amount: taken / Float(pieces))
        }
    }

    private func pawPrint(at x: Float, on l: Ledge) {
        guard let col = l.column(at: x), l.visible[col], l.h[col] > 2 else { return }
        l.h[col] -= min(0.9, l.h[col] - 1)
        if col + 1 < l.h.count { l.h[col + 1] -= min(0.5, max(l.h[col + 1] - 1, 0)) }
    }

    // MARK: - Jumps

    private func hop(_ c: inout Cat, _ v: SIMD2<Float>) {
        c.state = .airborne
        c.ledge = nil
        c.v = v
    }

    private func fall(_ c: inout Cat) {
        c.state = .airborne
        c.ledge = nil
        c.v = SIMD2(c.facing * 30, 0)
    }

    /// A visible spot on a ledge above to climb onto, within a cat's leap.
    private func climbTarget(from c: Cat, _ active: [Ledge]) -> SIMD2<Float>? {
        var options: [SIMD2<Float>] = []
        for l in active where l.kind != .ground && l.id != c.ledge {
            let rise = l.y - c.p.y
            guard rise > 30, rise < 330 else { continue }
            if let spot = landingSpot(on: l, from: c) { options.append(spot) }
        }
        return options.randomElement()
    }

    private func landingSpot(on l: Ledge, from c: Cat) -> SIMD2<Float>? {
        let rise = l.y - c.p.y
        guard rise < 360 else { return nil }
        let margin = Int(c.size / columnWidth) + 2
        guard l.h.count > margin * 2 else { return nil }
        var best: Int?
        var bestDistance = Float.infinity
        for i in stride(from: margin, to: l.h.count - margin, by: 4) where l.visible[i] {
            let d = abs(l.centerX(i) - c.p.x)
            if d > 30 && d < 300 && d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        guard let i = best else { return nil }
        return SIMD2(l.centerX(i), l.y + l.h[i])
    }

    /// Leaps along an arc that clears `target` and comes down on it.
    private func jump(_ c: inout Cat, to target: SIMD2<Float>) {
        let g = Self.gravity
        let rise = max(target.y - c.p.y, 0) + 45
        let vy = sqrt(2 * g * rise)
        let up = vy / g
        let down = sqrt(2 * max(c.p.y + rise - target.y, 1) / g)
        let vx = (target.x - c.p.x) / (up + down)
        c.facing = vx >= 0 ? 1 : -1
        hop(&c, SIMD2(vx, vy))
    }

    // MARK: - Petting

    private func pet(_ c: inout Cat, _ dt: Float) {
        // Sitting, it raises a paw to a cursor that comes close without touching it.
        // Glances at the viewer now and then; looks when petted, startled or snowed on.
        c.lookCooldown -= dt
        c.lookTime -= dt
        if c.lookCooldown <= 0 {
            c.lookTime = rand(1.5, 3.5)
            c.lookCooldown = rand(8, 18)
        }
        let attentive = c.petting > 0.3 || c.startle > 0.5 || c.state == .shaking
        let target: Float = attentive || c.lookTime > 0 ? 1 : 0
        c.look += (target - c.look) * min(1, dt * 6)

        // Resting the cursor on it, or stroking it back and forth; a cursor flying past doesn't count.
        let speed = simd_length(cursorVelocity)
        guard let cur = cursor, c.contains(cur), speed < 1100, c.fleeing <= 0,
              c.state == .sitting || c.state == .walking || c.state == .sleeping || c.state == .playing
        else {
            c.petting = max(0, c.petting - dt)
            c.stroking = max(0, c.stroking - dt * 0.5)
            return
        }
        c.petting += dt
        if speed > 40 { c.stroking += dt }
        // Stroked long enough, it purrs itself to sleep.
        if c.stroking > 2.5 && c.state != .sleeping {
            c.state = .sleeping
            c.timer = rand(20, 35)
            c.social = .none
            c.swatTimer = 0.4
        }
        if c.state == .sleeping { c.timer = max(c.timer, 8) }
        guard c.petting > 0.6 else { return }
        if c.state == .walking || c.state == .playing {
            c.state = .sitting
        }
        if c.state == .sitting { c.timer = max(c.timer, 1.5) }
        c.heartTimer -= dt
        if c.heartTimer <= 0 {
            c.heartTimer = 0.55
            let head = c.p + SIMD2(c.facing * c.size * 0.2, c.size * 1.9)
            hearts.append(Heart(p: head, v: SIMD2(rand(-14, 14), rand(28, 44))))
        }
    }

    // MARK: - Mugs and hearts

    private func updateMugs(_ dt: Float, _ active: [Ledge]) {
        guard !mugs.isEmpty else { return }
        var keep: [Mug] = []
        for var m in mugs {
            m.age += dt
            if m.resting {
                if let id = m.ledge, let l = ledges[id], let col = l.column(at: l.x0 + m.offset), l.visible[col] {
                    let depth = l.h[col]
                    m.p = SIMD2(l.x0 + m.offset, l.y + depth - min(depth, 4) * 0.6)
                } else {
                    m.resting = false
                    m.ledge = nil
                    m.v = .zero
                }
            } else {
                let y0 = m.p.y
                m.v.y -= Self.gravity * dt
                m.p += m.v * dt
                if m.v.y <= 0, let (l, _) = landing(x: m.p.x, from: y0, to: m.p.y, active) {
                    m.resting = true
                    m.ledge = l.id
                    m.offset = m.p.x - l.x0
                    m.v = .zero
                }
            }
            if m.p.y > -40 && m.age < 900 { keep.append(m) }
        }
        mugs = keep
    }

    private func updateHearts(_ dt: Float) {
        guard !hearts.isEmpty else { return }
        for i in hearts.indices {
            hearts[i].p += hearts[i].v * dt
            hearts[i].p.x += sin(time * 3 + hearts[i].seed) * 10 * dt
            hearts[i].life -= dt * 0.55
        }
        hearts.removeAll { $0.life <= 0 }
    }

    // MARK: - Testing

    /// Sends the cat for coffee now, from wherever it is on the ground.
    func fetchCoffeeNow() {
        guard var c = cat, let ground = ledges[Self.groundID] else { return }
        c.state = .walking
        c.ledge = ground.id
        c.offset = min(max(c.p.x - ground.x0, 20), ground.width - 20)
        c.lastLedge = SIMD2(ground.x0, ground.y)
        c.errand = .leaving
        c.facing = c.p.x < size.x / 2 ? -1 : 1
        cat = c
    }

    /// Makes the cat trip, tumble off its ledge, or dig, for the self-test.
    func catDo(_ action: String) {
        guard var c = cat, let id = c.ledge, let l = ledges[id] else { return }
        switch action {
        case "flop": flop(&c, on: l)
        case "dig": startDigging(&c)
        case "tumble":
            c.state = .airborne
            c.ledge = nil
            c.tumbling = true
            c.v = SIMD2(c.facing * 70, 100)
            c.spin = -c.facing * 6
        default: break
        }
        cat = c
    }

    /// Puts the cat on the Dock to play.
    func playOnDockNow() {
        guard var c = cat, let dock = ledges[Self.dockID] else { return }
        c.ledge = dock.id
        c.offset = dock.width * 0.5
        c.lastLedge = SIMD2(dock.x0, dock.y)
        c.p = SIMD2(dock.x0 + c.offset, dock.y)
        startPlaying(&c)
        c.timer = 30
        cat = c
    }
}
