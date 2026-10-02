import CoreGraphics
import Foundation
import SwiftUI

/// One grain as the Sand glyph draws it: its centre and diameter in points, its shade (−1 black … 0 the glyph's colour
/// … +1 white) and its opacity. `layer` keeps the pile under the stream and the stream under a mark.
struct SandGrain: Equatable, Sendable {
    enum Layer: Int, Sendable { case pile, stream, mark }

    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var shade: Double
    var alpha: Double
    var layer: Layer
}

/// The done glyph's glint: a four-point star at a centre, with its radius in points and its opacity.
struct SandSparkle: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var radius: CGFloat
    var alpha: Double
}

/// A solid shape in a shade of the colour and at an opacity, its outline in points: a formed mark's body at the small
/// sizes, drawn under the mark's grains and over the pile's, or the rim's glow (`SandRim.glow`).
struct SandSolid: Equatable, Sendable {
    var path: Path
    var shade: Double
    var alpha: Double
}

/// What one moment of the Sand glyph draws: its grains in drawing order, the solid bodies of its formed marks, the
/// done sparkle if it glints, and how strong the glow is (0…1: a needs-you glyph's glow swells as its mark forms).
struct SandFrame: Equatable, Sendable {
    var grains: [SandGrain] = []
    var solids: [SandSolid] = []
    var sparkle: SandSparkle?
    var glow: Double = 1
}

/// The Sand glyph: an hourglass with the glass taken away. A stream of grains falls into a pile that is the same size
/// in every mood, so it never reads as a meter.
///
/// - Running: a steady pour with travelling gaps and a few loose grains (under 30 pt a dense one about four grains
///   wide onto a fuller pile, so it never reads as a needle); the peak grows a little, then slides down one flank, and
///   loose grains roll off the edge.
/// - Delegating (the main turn waits on its subagents): the stream stops and the pile rests; its top grains fly up into
///   three small clumps side by side over it, which rise in turn and settle (`HelperBeat`), like Pixel's dots and
///   Liquid's droplets.
/// - Approval and question: the stream stops. Every 2.8 s the pile throws its top grains up into a "!" or curls them
///   into a "?" (the pile dips where they left), a glint runs up the mark, and after about two thirds of the beat it
///   crumbles back into the pile with a small spray.
/// - Done: the pile settles smooth, a pale check rises out of it and a sparkle glints once at its tip.
/// - Idle: a still, lower-contrast pile.
///
/// Every grain's position is a function of the clock and of the last mood change (`from`, `changeAge`); there are no
/// physics and no random numbers at draw time (`SandHash`). Done and idle are still within `settleTime` of a change.
enum SandGlyph {
    /// How often a moving glyph redraws, like Pixel's.
    static let motionInterval: TimeInterval = 1.0 / 30
    /// `frameOffset` shifts the clock by this much a step, so two glyphs side by side move differently.
    static let offsetShift: TimeInterval = 0.77
    /// Done and idle are still this long after a change; the view then pauses its timeline.
    static let settleTime: TimeInterval = 1.5

    /// The pile's base line in the unit square (y down). Its shape is the geometry's (`SandPile`).
    static let base = 0.96

    /// Needs-you: the mark forms, holds and crumbles once a beat.
    static let beat: TimeInterval = 2.8
    /// Running: the peak grows, then slides, once a slump.
    static let slump: TimeInterval = 2.3
    /// The stream's seconds between grains: a fifth of that under 30 pt, where the stream is about four grains wide, and
    /// a third above 40 pt.
    static let streamStep: TimeInterval = 0.014
    /// How long one of the stream's gaps is.
    static let streamGap: TimeInterval = 0.042
    /// Where the stream's grains appear.
    static let streamTop = 0.04
    /// The stream's start speed (box/s) and gravity (box/s²).
    static let streamSpeed = 0.45, gravity = 3.0
    /// How long a grain that lands from the stream rolls.
    static let roll: TimeInterval = 0.32
    /// How fast a needs-you mark's grains fall back into the pile (box/s²).
    static let collapseGravity = 14.0

    /// Delegating's clumps: across, the height they rest at and their radius (unit square), how far a hop lifts one,
    /// and how long each takes to fly up after a change, the next one `helperStagger` later.
    static let helperXs = [0.3, 0.5, 0.7], helperY = 0.43, helperRadius = 0.074, helperHop = 0.075
    static let helperFlight: TimeInterval = 0.42, helperStagger: TimeInterval = 0.12

    /// Whether a mood keeps moving once settled: running, delegating and needs-you do, done and idle hold still.
    static func keepsMoving(_ mood: GlyphMood) -> Bool { mood == .running || mood == .delegating || mood.needsYou }

    /// Whether a glyph in `mood`, `changeAge` seconds after its last change, draws the same frame from now on.
    static func isSettled(_ mood: GlyphMood, changeAge: TimeInterval) -> Bool {
        !keepsMoving(mood) && changeAge >= settleTime
    }

    /// The still frame for renders, Reduce Motion and dimmed glyphs: running mid-trickle (`offset` picks the moment),
    /// a needs-you mark fully formed after its glint has passed and before it crumbles, done with its check, idle.
    /// Its stream is unbroken, so a still running glyph never reads as a "!".
    static func stillFrame(mood: GlyphMood, side: CGFloat, offset: Int = 0) -> SandFrame {
        let time = mood == .delegating ? HelperBeat.stillTime(offset: offset) : mood.needsYou ? 0.7 * beat : 0.35 + Double(offset) * offsetShift
        return frame(mood: mood, from: nil, changeAge: .infinity, time: time, side: side, fromLasted: nil, still: true)
    }

    // MARK: The frame

    /// Everything the glyph draws at `time` (the clock, already shifted by the view's `frameOffset`), `side` points
    /// square. `from` is the mood before the last change and `changeAge` the seconds since it (nil and ignored when the
    /// glyph started settled in `mood`); `fromLasted` is how long `from` had lasted.
    static func frame(mood: GlyphMood, from: GlyphMood?, changeAge: TimeInterval, time: TimeInterval, side: CGFloat,
                      fromLasted: TimeInterval? = nil) -> SandFrame {
        frame(mood: mood, from: from, changeAge: changeAge, time: time, side: side, fromLasted: fromLasted, still: false)
    }

    /// `still`: the stream pours without gaps or loose grains.
    private static func frame(mood: GlyphMood, from: GlyphMood?, changeAge: TimeInterval, time: TimeInterval, side: CGFloat,
                              fromLasted: TimeInterval?, still: Bool) -> SandFrame {
        let geometry = SandGeometry.forSide(Double(side))
        let s = Double(side), p = geometry.pitch, grain = geometry.grain
        let age = from == nil ? .infinity : max(0, changeAge)
        let changedAt = time - age

        // Contrast (idle is flatter) and the done pile's smoothing, eased from the mood before.
        let fade = smooth(age / 0.35)
        let damp = from.map { mix(contrast($0), contrast(mood), fade) } ?? contrast(mood)
        let settleTarget = mood == .done ? 1.0 : 0
        let settle = from.map { mix($0 == .done ? 1 : 0, settleTarget, smooth((age - 0.15) / 0.8)) } ?? settleTarget

        // Running: how strongly the pile slumps, and the window of time in which the stream pours.
        let runAmount: Double
        var pourFrom = -Double.infinity, pourUntil = -Double.infinity
        if mood == .running {
            runAmount = from == nil || from == .running ? 1 : smooth(age / 0.8)
            pourUntil = .infinity
            if let from, from != .running { pourFrom = changedAt }
        } else {
            runAmount = from == .running ? 1 - smooth(age / 0.5) : 0
            if from == .running { pourUntil = changedAt }
        }

        // Needs-you: where the beat is; a change starts a fresh beat, a glyph that started settled beats on the clock.
        let phase = mood.needsYou ? frac((from == nil ? time : age) / beat) : 0

        // The mark the mood before leaves behind: it falls back into the pile for 0.7 s.
        var exit: (kind: SandMarkKind, amount: Double)?
        if let from, age < 0.7, let kind = markKind(from) {
            let amount: Double
            if from.needsYou {
                amount = formed(frac((fromLasted ?? changedAt) / beat))
            } else if from == .delegating {
                amount = fromLasted.map { helpersFormed($0, index: HelperBeat.count - 1) } ?? 1
            } else {
                amount = fromLasted.map(risen) ?? 1
            }
            if amount > 0.05 { exit = (kind, amount) }
        }

        // The pile's surface: the resting cone, the running bump, and a dip where a mark's grains left.
        var dip = mood.needsYou ? formed(phase) : mood == .done ? risen(age)
            : mood == .delegating ? 0.4 * (from == nil ? 1 : helpersFormed(age, index: HelperBeat.count - 1)) : 0
        if let exit { dip = max(dip, exit.amount * (1 - sstep(0.1, 0.45, age))) }
        let bump = runAmount > 0.001 ? slumpBump(time) : nil
        let bumpHeight = (bump?.height ?? 0) * runAmount, bumpX = bump?.x ?? 0.5
        let pile = geometry.pile, dipDepth = pile.dip * dip
        func surface(_ x: Double, rest: Double) -> Double {
            var h = rest
            if bumpHeight > 0 { let q = (x - bumpX) / 0.06; h += bumpHeight * exp(-q * q) }
            if dipDepth > 0 { let r = (x - 0.5) / 0.16; h -= dipDepth * exp(-r * r) }
            return h
        }
        func height(_ x: Double) -> Double { surface(x, rest: pile.height(at: x)) }

        var grains: [SandGrain] = []
        grains.reserveCapacity(geometry.cells.count + 160)
        func add(_ x: Double, _ y: Double, _ size: Double, _ shade: Double, _ alpha: Double, _ layer: SandGrain.Layer) {
            grains.append(SandGrain(x: CGFloat(x * s), y: CGFloat(y * s), size: CGFloat(size * s),
                                    shade: max(-1, min(1, shade)), alpha: min(1, alpha), layer: layer))
        }

        // The pile. A grain shows as the surface covers its row; its own threshold makes the edge sandy, and done pulls
        // every threshold to one value (and the jitter in) so the surface settles smooth. Grains are lit at the top,
        // darker toward the base, a little brighter on the left flank, and a rare one glints.
        let jitter = 1 - 0.7 * settle
        for cell in geometry.cells {
            let cover = (surface(cell.x, rest: cell.rest) - cell.floor) / geometry.rowPitch
            let threshold = cell.threshold + (0.5 - cell.threshold) * settle
            let alpha = c01((cover - threshold) / 0.22 + 0.5)
            guard alpha > 0.02 else { continue }
            let top = 1 - sstep(0.8, 2.4, cover)
            var shade = mix(-0.45, 0.1, cell.floor / pile.height) + 0.36 * top + 0.12 * (0.5 - cell.x) / pile.halfWidth
                + cell.noise * (geometry.crisp ? 0.13 : 0.26) * (1 - 0.5 * settle)
            if cell.glint, top > 0.5 { shade += 0.35 }
            add(cell.x + cell.jitterX * jitter, base - cell.floor - 0.5 * geometry.rowPitch + cell.jitterY * jitter,
                grain * cell.size * (0.6 + 0.4 * alpha), shade * damp, alpha, .pile)
        }

        // Running: loose grains roll ahead of the slump and drop off the edge.
        if let bump, bump.progress >= 0 {
            for r in 0..<3 {
                let d = 0.4 * pow(bump.progress, 1.5) + 0.03 + 0.025 * Double(r), x = 0.5 + bump.side * d
                var y = base - height(x) - 0.55 * p - 0.5 * p * abs(sin(.pi * (bump.progress * 4 + Double(r) * 0.5)))
                if d > pile.halfWidth - 0.03 { y += (d - (pile.halfWidth - 0.03)) * 3 }
                let alpha = runAmount * (1 - sstep(0.8, 1, bump.progress)) * sstep(0, 0.1, bump.progress)
                guard alpha > 0.02, y < base else { continue }
                add(x, y, grain * 0.9, (0.3 - 0.1 * Double(r)) * damp, alpha, .stream)
            }
        }

        // The stream: grains are born on a fixed time grid while it pours, fall under gravity with a few loose ones
        // drifting off the line, and some roll into the pile after landing. Short runs of missing grains make gaps
        // that race down the stream, so the motion reads at 14 pt. Under 30 pt it is a dense pour about four grains
        // wide (4 pt in the 28 pt pill), of full-size grains lighter than the pile, so it reads as a pour rather than
        // a needle.
        if pourUntil > time - 1.2 {
            let crisp = geometry.crisp
            let step = s > 40 ? streamStep / 3 : crisp ? streamStep / 5 : streamStep
            let spread = s > 40 ? 0.7 : crisp ? 3.2 : 0.12, rolls = s > 40 ? 0.15 : crisp ? 0.08 : 0.4
            let land = base - height(0.5) - 0.3 * p, drop = land - streamTop
            let fall = (-streamSpeed + (streamSpeed * streamSpeed + 2 * gravity * drop).squareRoot()) / gravity
            let first = Int(((time - fall - roll) / step).rounded(.up)), last = Int((time / step).rounded(.down))
            if first <= last {
                for k in first...last {
                    let born = Double(k) * step
                    guard born >= pourFrom, born <= pourUntil else { continue }
                    guard still || SandHash.unit(Int((born / streamGap).rounded(.down)), 41, 3) > 0.15 else { continue }
                    let tau = time - born, h = SandHash.unit(k, 9, 13)
                    if tau < fall {
                        // Under 30 pt the pour narrows a little as it speeds up, so it stays as dense all the way down.
                        let y = streamTop + streamSpeed * tau + 0.5 * gravity * tau * tau
                        var x = 0.5 + (h - 0.5) * spread * p * (crisp ? 1 - 0.3 * (y - streamTop) / drop : 1)
                        let loose = still ? 1 : SandHash.unit(k, 9, 17)
                        if loose < 0.14 { x += (loose < 0.07 ? -1 : 1) * (0.07 + 0.12 * h) * tau * tau }
                        let alpha = c01((y - streamTop) / 0.06 + 0.15)
                        let shade = crisp ? 0.3 + 0.22 * frac(h * 7.3) : 0.12 + 0.36 * frac(h * 7.3)
                        add(x, y, grain * (loose < 0.14 ? 0.9 : crisp ? 1 : 0.78), shade * damp, alpha, .stream)
                    } else if SandHash.unit(k, 9, 19) < rolls {
                        let rolled = (tau - fall) / roll, side = h < 0.5 ? -1.0 : 1
                        let x = 0.5 + side * p * (0.3 + 3.4 * easeOut(rolled))
                        add(x, base - height(x) - 0.42 * p, grain * 0.85, 0.34 * damp, 1 - smooth(rolled), .stream)
                    }
                }
            }
        }

        // The marks' motion (local functions, so they read this frame's surface).

        /// Under 30 pt, a mark's solid body: its outline filled under its grains, so its edge is continuous and the
        /// grains only add texture.
        var solids: [SandSolid] = []
        func solid(_ kind: SandMarkKind, shade: Double, amount: Double) {
            guard geometry.crisp, amount > 0.01 else { return }
            solids.append(SandSolid(path: kind.outline.applying(CGAffineTransform(scaleX: s, y: s)), shade: shade,
                                    alpha: 0.55 * amount))
        }

        /// Under 30 pt, one of delegating's clumps' solid body, lifted with its hop.
        func helperSolid(_ index: Int, lift: Double, amount: Double) {
            guard geometry.crisp, amount > 0.01 else { return }
            var path = Path()
            LiquidGlyph.addCircle(&path, CGPoint(x: helperXs[index] * s, y: (helperY - lift) * s), helperRadius * s)
            solids.append(SandSolid(path: path, shade: 0.16, alpha: 0.55 * amount))
        }

        /// Delegating: the pile's top grains fly up along jets into three clumps, left one first, and each clump then
        /// rises and settles in turn on the shared clock (`HelperBeat`), a touch brighter at the top of its hop. A glyph
        /// that started settled shows them in place. Each clump's solid body shows once its grains have landed.
        func helpers() {
            let lifts = (0..<HelperBeat.count).map { helperHop * HelperBeat.lift(at: time, index: $0) }
            for index in 0..<HelperBeat.count {
                helperSolid(index, lift: lifts[index], amount: from == nil ? 1 : helpersFormed(age, index: index))
            }
            for m in geometry.helpers {
                let index = SandMarkShape.helperIndex(m.x)
                let k = from == nil ? 1 : (age - (0.08 + helperStagger * Double(index) + 0.05 * m.order + 0.02 * m.h)) / helperFlight
                guard k > 0 else { continue }
                var (x, y) = k < 1 ? jet(m, progress: easeBack(k), pile: pile, pitch: p, grain: grain) : (m.x, m.y)
                y -= lifts[index] * smooth(k)
                if s >= 40, k >= 1 {
                    x += 0.05 * p * sin(2 * .pi * (time / (0.9 + m.h) + m.order))
                    y += 0.05 * p * cos(2 * .pi * (time / (1.1 + m.order) + m.h))
                }
                add(x, y, grain * m.size, m.shade + 0.25 * lifts[index] / helperHop, 1, .mark)
            }
        }

        /// A needs-you mark over one beat: its grains leap from the top of the pile along a jet (a quadratic curve
        /// with a small overshoot), hold with a glint running up them, then fall back under gravity, a small spray
        /// kicking up where they land. Its solid body shows once every grain has landed and goes before the first
        /// falls. Above 40 pt the held mark bobs and its grains shimmer.
        func needs(_ kind: SandMarkKind) {
            solid(kind, shade: 0.16, amount: sstep(0.14, 0.26, phase) * (1 - sstep(0.72, 0.79, phase)))
            let marks = geometry.marks(kind)
            let large = s >= 40, bob = large ? -0.01 * sin(2 * .pi * time / 1.4) : 0
            let sweep = (phase - 0.24) / 0.4
            for m in marks {
                let launch = 0.1 * m.order + 0.015 * m.h, k = (phase - launch) / 0.11
                guard k > 0 else { continue }
                let release = 0.78 + 0.06 * (1 - m.order) + 0.012 * m.h
                var x: Double, y: Double, alpha = 1.0, shade = m.shade
                if phase < release {
                    if k < 1 {
                        (x, y) = jet(m, progress: easeBack(k), pile: pile, pitch: p, grain: grain)
                    } else {
                        x = m.x
                        y = m.y + bob
                        if large {
                            x += 0.07 * p * sin(2 * .pi * (time / (0.9 + m.h) + m.order))
                            y += 0.07 * p * cos(2 * .pi * (time / (1.1 + m.order) + m.h))
                        }
                    }
                    if sweep > 0, sweep < 1 {
                        let q = (m.diagonal - (-0.35 + 0.8 * sweep)) / 0.06
                        shade += 0.42 * exp(-q * q)
                    }
                } else {
                    let tau = (phase - release) * beat
                    x = m.x + (m.x - 0.5) * 0.25 * tau
                    y = m.y + bob + 0.5 * collapseGravity * tau * tau
                    let floor = base - height(x) - 0.3 * p
                    guard y < floor else { continue }
                    alpha = c01((floor - y) / (1.5 * p))
                }
                add(x, y, grain * m.size, shade, alpha, .mark)
            }
            // A small spray where the mark lands back in the pile.
            let spray = (phase - 0.86) * beat
            if spray > 0, spray < 0.34 {
                let y0 = base - height(0.5) - 0.5 * p
                for i in 0..<8 {
                    let side = i & 1 == 0 ? -1.0 : 1, r = Double(i / 2)
                    let x = 0.5 + side * (0.04 + (0.28 + 0.1 * r) * spray)
                    let y = y0 - (0.9 + 0.22 * r) * spray + 4 * spray * spray
                    guard y < base - height(x) - 0.4 * p else { continue }
                    add(x, y, grain * 0.85, 0.3 + 0.08 * r, 1 - smooth(spray / 0.34), .mark)
                }
            }
        }

        /// The done check rises out of the pile left to right, each grain along its own jet; its grains are pale
        /// (the colour mixed well toward white), and its solid body fills in as the last of them land.
        func risingCheck() {
            solid(.check, shade: 0.5, amount: sstep(0.95, 1.3, age))
            for m in geometry.check {
                let k = (age - (0.25 + 0.5 * m.order + 0.015 * m.h)) / 0.42
                guard k > 0 else { continue }
                let (x, y) = k < 1 ? jet(m, progress: easeBack(k), pile: pile, pitch: p, grain: grain) : (m.x, m.y)
                add(x, y, grain * m.size, 0.4 + 0.55 * m.shade, 1, .mark)
            }
        }

        /// The mood before's mark falling back into the pile; its solid body goes at once.
        func falling(_ kind: SandMarkKind, age: TimeInterval, amount: Double) {
            // Delegating's clumps fall from where their hops had them when the mood changed.
            let lifts = (0..<HelperBeat.count).map { kind == .dots ? helperHop * HelperBeat.lift(at: changedAt, index: $0) : 0 }
            if kind == .dots {
                for index in 0..<HelperBeat.count { helperSolid(index, lift: lifts[index], amount: amount * (1 - smooth(age / 0.1))) }
            } else {
                solid(kind, shade: kind == .check ? 0.5 : 0.16, amount: amount * (1 - smooth(age / 0.1)))
            }
            for m in geometry.marks(kind) {
                let tau = max(0, age - 0.06 * (1 - m.order))
                let lift = kind == .dots ? lifts[SandMarkShape.helperIndex(m.x)] : 0
                let x = m.x + (m.x - 0.5) * 0.25 * tau, y = m.y - lift + 0.5 * collapseGravity * tau * tau
                let floor = base - height(x) - 0.3 * p
                guard y < floor else { continue }
                let shade = kind == .check ? 0.4 + 0.55 * m.shade : m.shade
                add(x, y, grain * m.size, shade, amount * c01((floor - y) / (1.5 * p)), .mark)
            }
        }

        // The marks: the mood before's falls away, this mood's forms.
        if let exit {
            falling(exit.kind, age: age, amount: exit.amount)
        }
        var glow: Double
        switch mood {
        case .approval, .question:
            needs(mood == .approval ? .bang : .ques)
            glow = 0.55 + 0.45 * formed(phase)
        case .done:
            risingCheck()
            glow = 1
        case .delegating:
            helpers()
            glow = 0.8
        case .running: glow = 0.8
        case .idle: glow = 0.5
        }

        var sparkle: SandSparkle?
        if mood == .done, from != nil, age >= 1.0, age <= 1.45 {
            let glint = sin(.pi * (age - 1.0) / 0.45)
            let radius = max(0.085, 1.3 / s) * (0.55 + 0.45 * glint)
            let x = min(1 - radius * 0.9, geometry.checkTip.x + 0.07), y = max(radius * 0.9, geometry.checkTip.y - 0.08)
            sparkle = SandSparkle(x: CGFloat(x * s), y: CGFloat(y * s), radius: CGFloat(radius * s), alpha: glint)
        }
        return SandFrame(grains: grains, solids: solids, sparkle: sparkle, glow: glow)
    }

    /// Where a mark grain is along its jet, `progress` 0 (just leaving the pile) … 1 (in place, past 1 overshooting;
    /// the overshoot never lifts a grain out of the square).
    private static func jet(_ m: SandMarkGrain, progress e: Double, pile: SandPile, pitch: Double, grain: Double) -> (Double, Double) {
        let sy = base - pile.height(at: m.sourceX) + 0.6 * pitch
        let cy = m.y + (sy - m.y) * 0.3
        let u = 1 - e
        let y = u * u * sy + 2 * u * e * cy + e * e * m.y
        return (u * u * m.sourceX + 2 * u * e * m.controlX + e * e * m.x, max(0.6 * grain, y))
    }

    /// Running: the peak gains a little sand, then that bump slides down one flank and off the edge, once a `slump`.
    private static func slumpBump(_ time: TimeInterval) -> (x: Double, height: Double, side: Double, progress: Double) {
        let n = (time / slump).rounded(.down), u = time / slump - n
        let side: Double = SandHash.unit(Int(n), 3, 5) < 0.5 ? -1 : 1, peak = 0.05
        if u < 0.7 { return (0.5, peak * (u / 0.7), side, -1) }
        let v = (u - 0.7) / 0.3
        return (0.5 + side * 0.44 * pow(v, 1.5), peak * (1 - 0.3 * v) * (1 - sstep(0.7, 1, v)), side, v)
    }

    /// How formed a needs-you mark is at `phase` of its beat: it forms over the first 16 %, holds, and crumbles
    /// between 80 and 93 %.
    static func formed(_ phase: Double) -> Double { sstep(0, 0.16, phase) * (1 - sstep(0.8, 0.93, phase)) }

    /// How far the done check has risen `age` seconds after the change.
    static func risen(_ age: TimeInterval) -> Double { sstep(0.25, 1.1, age) }

    /// How far delegating's clump `index` has formed `age` seconds after the change (all its grains landed at 1).
    static func helpersFormed(_ age: TimeInterval, index: Int) -> Double {
        let start = 0.08 + helperStagger * Double(index) + helperFlight * 0.6
        return sstep(start, start + helperFlight * 0.8, age)
    }

    private static func contrast(_ mood: GlyphMood) -> Double { mood == .idle ? 0.55 : 1 }

    private static func markKind(_ mood: GlyphMood) -> SandMarkKind? {
        switch mood {
        case .approval: .bang
        case .question: .ques
        case .done: .check
        case .delegating: .dots
        case .running, .idle: nil
        }
    }
}

// MARK: - The rim

/// The Sand rim: while anything runs, a dense line of grains flows left to right along the closed pill's bottom edge,
/// in the body's lowest points (the pill's 3 pt band). Its bed is three grains deep (about 2 pt, never under 1.8),
/// each row a little faster than the one under it, with gentle ripples travelling along it; brighter grains ride its
/// crests and a few hop above them, and its ends taper. When the work stops the grains slow to a halt and the line drains
/// from both ends into the middle, then nothing is drawn; when work starts it fills out from the middle.
enum SandRim {
    /// How long the rim takes to drain after the work stops; after this it draws nothing and the view's timeline pauses.
    static let drainTime: TimeInterval = 0.9
    /// The glow: one strip along the bed (`glow`), blurred by this many points behind the grains, at this opacity, inside
    /// the band, and faded in over the band's top `glowFeather` points rather than cut flat there, like Liquid's.
    static let glowBlur: CGFloat = 1.1
    static let glowOpacity = 0.75
    static let glowFeather: CGFloat = 1.5
    /// The bed's grain pitch along the line (pt), and its rows' speeds (pt/s), bottom to top, then the crest grains'.
    static let pitch = 0.62
    static let rowSpeeds = [7.0, 9.5, 12.5, 15.5]
    /// The moment a still rim shows (renders, Reduce Motion).
    static let stillTime: TimeInterval = 0.35

    /// Whether the rim draws nothing from now on.
    static func isDrained(running: Bool, changeAge: TimeInterval) -> Bool { !running && changeAge >= drainTime }

    /// What the grains and the glow share at one moment: how full the line is, its clock, how far its ends taper, and
    /// where the bed rests. nil when the rim draws nothing.
    private struct Line {
        let w, h, amount, clock, reachL, reachR, base, apart, k: Double

        init?(running: Bool, changeAge: TimeInterval, time: TimeInterval, width: CGFloat, height: CGFloat, ends: RimEnds?) {
            let age = max(0, changeAge)
            amount = running ? smooth(age / 0.6) : 1 - smooth(age / drainTime)
            guard amount > 0.001, width > 1, height > 0 else { return nil }
            w = Double(width)
            h = Double(height)
            // The grains shrink a little in a band under 3.5 pt; the bed keeps its depth (`apart`).
            k = min(1, h / 3.5)
            var clock = time
            if !running {
                // The grains slow to a halt.
                let stop = 0.35
                clock = (time - age) + stop * (1 - exp(-age / stop))
            }
            self.clock = clock
            // The ends taper over 20 pt, or a fifth of a short line (the top bar's), or less than half of a short
            // visible end (a narrow wing), so it never fades away whole; filling and draining, they move in to the middle.
            let endL = ends.map { Double($0.left) } ?? w, endR = ends.map { Double($0.right) } ?? w
            reachL = min(20, w * 0.2, max(3, endL * 0.45)) + (1 - amount) * w / 2
            reachR = min(20, w * 0.2, max(3, endR * 0.45)) + (1 - amount) * w / 2
            // The bed rests a little above the band's bottom (the pill's edge), its rows 0.6 pt apart down to the pill's
            // 3 pt band: about 2 pt of grains there too.
            base = h * 0.58
            apart = 0.6 * min(1, h / 3)
        }

        /// The ripples: 0.3 pt either way in a band 5 pt or taller, 0.15 in the pill's 3 pt one, so the bed and the crest
        /// grains over it stay in the band (within a twentieth of a point, where the canvas clips them).
        func ripple(_ x: Double) -> Double { min(0.3, 0.075 * (h - 1)) * sin(2 * .pi * (x / 38 - clock / 2.4)) }
        func crest(_ x: Double) -> Double { smooth(0.5 + 0.9 * sin(2 * .pi * (x / 29 - clock / 1.7) + 0.6)) }
        /// 1 along the line, falling to 0 over each end's reach.
        func edges(_ x: Double) -> Double { sstep(0, reachL, x) * sstep(w, w - reachR, x) }
    }

    /// The rim's grains at `time`, `width` × `height` points, bed first. `changeAge` is the seconds since `running` last
    /// changed (infinity when it has not changed since the rim appeared). `ends` is how much of the line shows from each
    /// end (the pill's wings; nil: all of it).
    static func frame(running: Bool, changeAge: TimeInterval, time: TimeInterval, width: CGFloat, height: CGFloat,
                      ends: RimEnds? = nil) -> [SandGrain] {
        guard let line = Line(running: running, changeAge: changeAge, time: time, width: width, height: height, ends: ends) else { return [] }
        let w = line.w, amount = line.amount, clock = line.clock, base = line.base, apart = line.apart, k = line.k
        let pad = 8.0, count = Int(((w + 2 * pad) / pitch).rounded(.up)), length = Double(count) * pitch
        var grains: [SandGrain] = []
        grains.reserveCapacity(4 * count + Int(w / 6) + 4)
        // Rows 0 to 2 are the bed, bottom to top; row 3 is the crest grains on top of it.
        let lift = [-1.0, 0, 1, 1.9]
        for row in 0..<4 {
            let shift = row & 1 == 1 ? 0.5 * pitch : 0
            for j in 0..<count {
                let g = hashes(row, j)
                let x = frac((Double(j) * pitch + shift + rowSpeeds[row] * clock) / length) * length - pad + (g.h0 - 0.5) * 0.24 * pitch
                let edges = line.edges(x)
                guard edges > 0.01 else { continue }
                // Toward the ends the upper rows go first, so the line tapers.
                let taper = pow(edges, 0.5 + 0.5 * Double(row))
                let c = line.crest(x)
                var alpha: Double, shade: Double
                switch row {
                case 0: (alpha, shade) = (0.9 + 0.1 * g.h1, -0.08 + 0.2 * g.h4)
                case 1: (alpha, shade) = (0.9 + 0.1 * g.h1, 0.06 + 0.22 * g.h4 + 0.08 * c)
                case 2: (alpha, shade) = (0.85 + 0.15 * c, 0.2 + 0.2 * g.h4 + 0.16 * c)
                default: (alpha, shade) = (c * c * (0.45 + 0.55 * g.h1), 0.42 + 0.22 * g.h4)
                }
                alpha *= amount * taper
                guard alpha > 0.03 else { continue }
                let size = (0.78 + 0.2 * g.h3) * (0.75 + 0.25 * k) * (row == 3 ? 0.9 : 1)
                let y = base + line.ripple(x) - lift[row] * apart * (0.35 + 0.65 * edges) + (g.h2 - 0.5) * 0.24 * k
                grains.append(SandGrain(x: CGFloat(x), y: CGFloat(y), size: CGFloat(size), shade: shade, alpha: min(1, alpha),
                                        layer: row == 3 ? .stream : .pile))
            }
        }
        // A few grains hop off the crests, faster than the bed, and land back on it; they settle as the line drains.
        let hoppers = max(4, Int((w / 6).rounded())), run = w + 2 * pad
        for i in 0..<hoppers {
            let g = hashes(4, i)
            let x = frac(g.h0 + (18 + 14 * g.h1) * clock / run) * run - pad
            let edges = line.edges(x)
            let hop = abs(sin(.pi * (clock / (0.36 + 0.36 * g.h3) + g.h4)))
            let alpha = amount * edges * edges * (0.55 + 0.45 * g.h4) * (0.4 + 0.6 * hop)
            guard alpha > 0.03 else { continue }
            let size = (0.7 + 0.16 * g.h3) * (0.75 + 0.25 * k)
            let top = base + line.ripple(x) - 1.9 * apart - size / 2
            let y = max(size / 2 + 0.15, top - (0.3 + 1.1 * k * g.h2) * hop * amount)
            grains.append(SandGrain(x: CGFloat(x), y: CGFloat(y), size: CGFloat(size), shade: 0.45 + 0.25 * g.h4, alpha: alpha,
                                    layer: .stream))
        }
        return grains
    }

    /// The rim's glow at `time`: one strip along the bed, as deep as its three rows (a little deeper under the crests),
    /// rippling and tapering with it, in about the bed's mean shade at `glowOpacity`. The view blurs it by `glowBlur`
    /// behind the grains: one blurred fill a frame, where blurring the grains themselves drew every grain twice. nil
    /// when the rim draws nothing.
    static func glow(running: Bool, changeAge: TimeInterval, time: TimeInterval, width: CGFloat, height: CGFloat,
                     ends: RimEnds? = nil) -> SandSolid? {
        guard let line = Line(running: running, changeAge: changeAge, time: time, width: width, height: height, ends: ends) else { return nil }
        let grain = 0.88 * (0.75 + 0.25 * line.k), steps = max(8, Int((line.w / 1.5).rounded(.up))), step = line.w / Double(steps)
        // Row 1 runs along the middle; rows 0 and 2 sit `apart` either side of it, closing in toward the ends as the
        // grains do, and the strip thins with the upper rows' taper.
        func edge(_ x: Double, _ side: Double) -> CGPoint {
            let e = line.edges(x), middle = line.base + line.ripple(x)
            let half = (line.apart * (0.35 + 0.65 * e) + grain / 2) * e.squareRoot()
            let crest = side < 0 ? 0.9 * line.apart * pow(line.crest(x), 2) * e : 0
            return CGPoint(x: x, y: middle + side * half - crest)
        }
        var path = Path()
        path.move(to: edge(0, -1))
        for i in 1...steps { path.addLine(to: edge(Double(i) * step, -1)) }
        for i in (0...steps).reversed() { path.addLine(to: edge(Double(i) * step, 1)) }
        path.closeSubpath()
        return SandSolid(path: path, shade: 0.18, alpha: glowOpacity * line.amount)
    }

    /// A rim grain's five fixed numbers (`SandHash` of its row and index).
    private struct GrainHashes {
        let h0, h1, h2, h3, h4: Double

        init(_ k: Int) {
            (h0, h1, h2) = (SandHash.unit(k, 21, 1), SandHash.unit(k, 21, 2), SandHash.unit(k, 21, 3))
            (h3, h4) = (SandHash.unit(k, 21, 4), SandHash.unit(k, 21, 5))
        }
    }

    /// Grain `index` of `row` (4: the hoppers): from the table for a line up to about 620 pt, hashed as it draws past.
    private static func hashes(_ row: Int, _ index: Int) -> GrainHashes {
        index < tableColumns ? grainHashes[row * tableColumns + index] : GrainHashes(row << 16 | index)
    }

    /// Every grain's fixed numbers for a line up to about 620 pt, worked out once rather than every frame.
    private static let tableColumns = 1024
    private static let grainHashes = (0..<5 * tableColumns).map { GrainHashes(($0 / tableColumns) << 16 | $0 % tableColumns) }

    /// The still rim (renders, Reduce Motion): a running line at `stillTime`, or nothing.
    static func stillFrame(running: Bool, width: CGFloat, height: CGFloat, ends: RimEnds? = nil) -> [SandGrain] {
        running ? frame(running: true, changeAge: .infinity, time: stillTime, width: width, height: height, ends: ends) : []
    }

    /// The still rim's glow, or nothing.
    static func stillGlow(running: Bool, width: CGFloat, height: CGFloat, ends: RimEnds? = nil) -> SandSolid? {
        running ? glow(running: true, changeAge: .infinity, time: stillTime, width: width, height: height, ends: ends) : nil
    }
}

// MARK: - Easing

private func c01(_ v: Double) -> Double { v < 0 ? 0 : v > 1 ? 1 : (v.isNaN ? 0 : v) }
private func smooth(_ v: Double) -> Double { let v = c01(v); return v * v * (3 - 2 * v) }
private func sstep(_ a: Double, _ b: Double, _ v: Double) -> Double { smooth((v - a) / (b - a)) }
private func easeOut(_ v: Double) -> Double { let v = c01(v); return 1 - pow(1 - v, 3) }
private func easeBack(_ v: Double) -> Double { let v = c01(v) - 1; return 1 + v * v * (2.6 * v + 1.6) }
private func frac(_ v: Double) -> Double { v - v.rounded(.down) }
/// `a` to `b` by `t`, exactly `b` once `t` reaches 1 (so a settled frame equals one that started settled).
private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { t >= 1 ? b : a + (b - a) * t }

extension SandGeometry {
    func marks(_ kind: SandMarkKind) -> [SandMarkGrain] {
        switch kind {
        case .bang: bang
        case .ques: ques
        case .check: check
        case .dots: helpers
        }
    }
}
