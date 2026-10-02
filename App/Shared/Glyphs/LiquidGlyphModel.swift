import SwiftUI
import Synchronization

/// Liquid, a Glyph style: a body of juice floating in the square, with no cup and no straw. Running (Slim, the default),
/// it is a thin band that crests run along, left to right, each throwing a droplet up that falls back behind it; Full
/// is the round body that rocks under rolling waves while bubbles rise inside. Delegating (the main turn waits on its
/// subagents), the band lies calm while three droplets float over it and rise in turn (`HelperBeat`). Waiting for you,
/// a jet rises out of it and pinches into a "!" (approval) or curls over into a "?" (question), holds, and drops back in
/// with a splash. Done, it settles, a pale check rises out of it and a glint slides once along the surface. Idle, it
/// rests flat and still.
///
/// The model is pure: `frame(mood:from:changeAge:time:side:)` returns the shapes of one moment, in points, as a
/// function of the clock and the last mood change alone, so a row a list update re-creates carries on where it was and
/// every render is reproducible. `LiquidGlyphView` fills them in a `Canvas` at the screen's scale. The free surface is
/// a cubic spline through the wave function; the marks are circles, tapers and round-capped strokes. Definition comes
/// from tone, never from blur: a light meniscus along the surface, a darker lower body with a thin rim of light under
/// it, a specular glint, and a lit and a shaded edge on each mark.
enum LiquidGlyph {
    // MARK: Primitives

    /// A shade of the glyph's colour: `light` runs from black (−1) through the colour (0) to white (1).
    struct Tone: Equatable, Sendable {
        var light: Double
        var opacity: Double

        init(_ light: Double = 0, opacity: Double = 1) {
            self.light = light
            self.opacity = opacity
        }
    }

    /// One colour stop of a gradient, `location` 0…1 from its start to its end.
    struct Stop: Equatable, Sendable {
        var location: Double
        var tone: Tone

        init(_ location: Double, _ tone: Tone) {
            self.location = location
            self.tone = tone
        }
    }

    /// How a shape is filled: one tone, or a linear gradient of tones between two points (padded past its ends).
    enum Paint: Equatable, Sendable {
        case solid(Tone)
        case linear([Stop], from: CGPoint, to: CGPoint)
    }

    /// Keeps a fill inside `path`, or outside it when `inverse`. With a `feather`, the fill also fades in from nothing at
    /// the top of the path's bounds to full `feather` points below it (the rim's glow, which a hard cut at the band's top
    /// would leave as a flat shelf over the waving line).
    struct Clip: Equatable, Sendable {
        var path: Path
        var inverse = false
        var feather: CGFloat = 0
    }

    /// One filled shape, in points in the glyph's square, drawn inside all of its clips, blurred by `blur` points (the
    /// rim's glow; the glyph's shapes are never blurred).
    struct Primitive: Equatable, Sendable {
        var path: Path
        var paint: Paint
        var clips: [Clip] = []
        var blur: CGFloat = 0
    }

    // MARK: Clock

    /// How often a moving glyph redraws: 30 times a second, like Pixel's.
    static let motionInterval: TimeInterval = 1.0 / 30
    /// A second glyph's `frameOffset` shifts its clock by this much a step, so two side by side move differently.
    static let offsetShift: TimeInterval = 0.77
    /// The needs-you beat: a mark rises, holds and drops back once a beat, the same period as Pixel's breath.
    static let beat: TimeInterval = 3.2
    /// A change into done or idle has played out after this long: from then on the frame no longer changes.
    static let settleTime: TimeInterval = 1.25
    /// The view stops redrawing a done or idle glyph this long after a change (a little after it has settled).
    static let pauseAfter: TimeInterval = 1.5

    /// Whether a mood moves for as long as it lasts: running rolls, delegating's droplets rise in turn and a needs-you
    /// mark beats; done and idle settle.
    nonisolated static func keepsMoving(_ mood: GlyphMood) -> Bool { mood == .running || mood == .delegating || mood.needsYou }

    /// The moment a still glyph shows (renders, Reduce Motion, `animated: false`): running mid-roll, delegating's
    /// droplets all at rest, a needs-you mark formed and holding, done and idle at rest. `frameOffset` picks another
    /// pose, like Pixel's still frames.
    nonisolated static func stillTime(_ mood: GlyphMood, frameOffset: Int = 0, running: LiquidRunningLook = .slim) -> TimeInterval {
        if mood == .delegating { return HelperBeat.stillTime(offset: frameOffset) }
        // Slim: a crest in the middle of the band, its droplet near the top of its arc.
        if mood == .running, running == .slim { return crestPeriod * (0.56 + Double(frameOffset)) }
        return mood.needsYou ? beat * (0.5 + Double(frameOffset)) : 1.15 + Double(frameOffset) * offsetShift
    }

    /// The settled still frame of `mood`.
    nonisolated static func still(_ mood: GlyphMood, side: CGFloat, frameOffset: Int = 0, running: LiquidRunningLook = .slim) -> [Primitive] {
        frame(mood: mood, time: stillTime(mood, frameOffset: frameOffset, running: running), side: side, running: running)
    }

    /// The shapes of one moment. `from` is the mood before the last change and `changeAge` the seconds since it
    /// (infinite, or `from` nil, for a glyph that has not changed since it appeared: it shows its mood settled).
    /// `time` is the clock in seconds, already shifted by the glyph's frame offset. `running` is Settings › Island ›
    /// Running: how a running glyph looks.
    nonisolated static func frame(mood: GlyphMood, from: GlyphMood? = nil, changeAge: TimeInterval = .infinity,
                                  time: TimeInterval, side: CGFloat, running: LiquidRunningLook = .slim) -> [Primitive] {
        Moment(mood: mood, from: from, changeAge: changeAge, time: time, side: Double(side), running: running).primitives()
    }

    // MARK: Poses

    /// The body's resting shape in one mood, in units of the square (y down): surface level, underside, left and right
    /// ends and end-cap radius, and how much it moves (waves, rocking, bubbles, the travelling crests). Running Full
    /// fills most of the square; running Slim and delegating are a thin band across the middle, with room above it for
    /// the crest's droplets or the helpers; a needs-you or done body sits low and flat to leave room for its mark; idle
    /// rests in the middle. Each layout is optically centred as a whole, mark included.
    struct Pose: Equatable, Sendable {
        var level, bottom, left, right, cap, waves, rock, bubbles: Double
        var crest = 0.0

        static func of(_ mood: GlyphMood, running look: LiquidRunningLook = .slim) -> Pose {
            switch mood {
            case .running where look == .full:
                Pose(level: 0.2, bottom: 0.82, left: 0.03, right: 0.97, cap: 0.2, waves: 1.25, rock: 0.12, bubbles: 1)
            case .running: Pose(level: 0.52, bottom: 0.75, left: 0.04, right: 0.96, cap: 0.11, waves: 0.5, rock: 0.03, bubbles: 0, crest: 1)
            case .delegating: Pose(level: 0.54, bottom: 0.75, left: 0.07, right: 0.93, cap: 0.105, waves: 0.18, rock: 0, bubbles: 0)
            case .approval, .question: Pose(level: 0.705, bottom: 0.955, left: 0.07, right: 0.93, cap: 0.11, waves: 0.45, rock: 0.03, bubbles: 0)
            case .done: Pose(level: 0.705, bottom: 0.955, left: 0.07, right: 0.93, cap: 0.11, waves: 0, rock: 0, bubbles: 0)
            case .idle: Pose(level: 0.355, bottom: 0.665, left: 0.05, right: 0.95, cap: 0.15, waves: 0, rock: 0, bubbles: 0)
            }
        }

        func blended(to other: Pose, by t: Double) -> Pose {
            Pose(level: lerp(level, other.level, t), bottom: lerp(bottom, other.bottom, t), left: lerp(left, other.left, t),
                 right: lerp(right, other.right, t), cap: lerp(cap, other.cap, t), waves: lerp(waves, other.waves, t),
                 rock: lerp(rock, other.rock, t), bubbles: lerp(bubbles, other.bubbles, t), crest: lerp(crest, other.crest, t))
        }
    }

    // MARK: Slim running's crests

    /// Two crests run along the slim band, half a `crestPeriod` apart, each from past the left end to past the right one.
    static let crestPeriod: TimeInterval = 1.5
    /// A crest's height (units; a quarter more under 20 pt), and its back and front half-widths (steeper in front).
    static let crestHeight = 0.15, crestBack = 0.16, crestFront = 0.1
    /// Where a crest is along its run (0 … 1) when it throws its droplet, and how long the droplet flies before it has
    /// sunk back under the band.
    static let leapAt = 0.42, leapFlight: TimeInterval = 0.66

    /// Where crest `k`'s top is (units across) at `time`: 0 … 1 of its run maps to −0.2 … 1.2.
    nonisolated static func crestRun(time: TimeInterval, crest k: Int) -> Double {
        let turns = time / crestPeriod + 0.5 * Double(k)
        return turns - turns.rounded(.down)
    }

    // MARK: Delegating's helpers

    /// The three droplets over the calm band: across, and the height (units, y down) they rest at; their radius; how
    /// far a hop lifts one; how long each takes to rise out of the band after a change (the next one starting
    /// `helperStagger` later), and to drop back in when the mood moves on.
    static let helperXs = [0.3, 0.5, 0.7], helperRest = 0.35, helperRadius = 0.066, helperHop = 0.085
    static let helperRise: TimeInterval = 0.5, helperStagger: TimeInterval = 0.11, helperFall: TimeInterval = 0.36

    // MARK: Needs-you beat

    /// A needs-you jet: how far it has grown (0 under the surface … 1 full height), how far it has pinched into its dot
    /// (0 one column … 1 apart), and how far it has dropped (units, down; a little negative while it floats).
    struct Jet: Equatable, Sendable {
        var grow: Double
        var pinch: Double
        var drop: Double
    }

    /// Where the beat's mark is and how long ago a mark last hit the juice (nil: no hit yet).
    struct Beat: Equatable, Sendable {
        var jet: Jet?
        var sinceImpact: Double?
        /// The jet's phase while it rises (0 … `pinchEnd`), which lifts a mound under it.
        var rise: Double?
    }

    /// Beat phases: grow 0 … 0.14, pinch 0.11 … 0.22, hold (floating) until 0.84, fall until 0.95, then gone.
    static let growEnd = 0.14, pinchStart = 0.11, pinchEnd = 0.22, fallStart = 0.84, fallEnd = 0.95
    /// How far a falling mark drops (units): enough to sink all of it under the surface.
    static let fallDepth = 0.8
    /// A mark floats this far up and down while it holds (units).
    static let float = 0.014
    /// The phase at which a falling mark's dot meets the surface.
    static let impactPhase = fallStart + (fallEnd - fallStart) * cbrt(markClearance / fallDepth)
    /// The gap under a formed mark's dot, down to the needs-you surface (units).
    static let markClearance = Pose.of(.approval).level - (Bang.dot + Bang.dotRadius)
    /// After a change into needs-you the new mark holds at least this long before it joins the clock's beat.
    static let minimumHold: TimeInterval = 1.0
    /// A mark left behind by a change drops back in over this long.
    static let exitFall: TimeInterval = 0.36

    /// The jet at `phase` (0 … 1) of the beat; nil once it has sunk.
    nonisolated static func jet(phase: Double) -> Jet? {
        guard phase < fallEnd else { return nil }
        if phase >= fallStart {
            return Jet(grow: 1, pinch: 1, drop: easeIn((phase - fallStart) / (fallEnd - fallStart)) * fallDepth)
        }
        let floating = phase >= pinchEnd ? -float * sin(2 * .pi * (phase - pinchEnd) / (fallStart - pinchEnd)) : 0
        return Jet(grow: easeOut(phase / growEnd), pinch: smooth((phase - pinchStart) / (pinchEnd - pinchStart)), drop: floating)
    }

    /// The needs-you mark at `time`. Settled, it follows the clock's beat, so every needs-you glyph beats in step and a
    /// re-created row picks up mid-beat. After a change into needs-you (`changeTime`), the mark rises `delay` seconds
    /// later, then holds until the clock's next fall, so the beat joins the clock without a jump.
    nonisolated static func needsBeat(changeTime: Double?, delay: Double, time: Double) -> Beat {
        var fallAt = -Double.infinity
        if let changeTime {
            let start = changeTime + delay, riseEnd = start + pinchEnd * beat
            fallAt = (ceil((riseEnd + minimumHold) / beat - fallStart) + fallStart) * beat
            if time < fallAt {
                let local = time - start
                guard local >= 0 else { return Beat() }
                if local < pinchEnd * beat { return Beat(jet: jet(phase: local / beat), rise: local / beat) }
                let envelope = smooth((time - riseEnd) / 0.3) * smooth((fallAt - time) / 0.3)
                let floating = -float * sin(2 * .pi * (time - riseEnd) / ((fallStart - pinchEnd) * beat)) * envelope
                return Beat(jet: Jet(grow: 1, pinch: 1, drop: floating))
            }
        }
        let turns = time / beat, phase = turns - floor(turns)
        let impactTime = (floor(turns - impactPhase) + impactPhase) * beat
        return Beat(jet: jet(phase: phase), sinceImpact: impactTime >= fallAt ? time - impactTime : nil,
                    rise: phase < pinchEnd ? phase : nil)
    }

    /// The mark a needs-you glyph showed when its mood changed at `changeTime`, dropping back into the juice: from
    /// where it was, or, when it was already falling, finishing that fall on the clock.
    nonisolated static func exitBeat(changeTime: Double, age: Double, time: Double) -> Beat {
        let turn = floor(changeTime / beat), phase = changeTime / beat - turn
        if phase >= fallStart {
            let impactTime = (turn + impactPhase) * beat
            let current = floor(time / beat) == turn ? jet(phase: time / beat - turn) : nil
            return Beat(jet: current, sinceImpact: time >= impactTime ? time - impactTime : nil)
        }
        guard var falling = jet(phase: phase) else { return Beat() }
        // Only a mark that stood clear of the juice splashes when it lands.
        let impactAge = exitFall * cbrt(markClearance / fallDepth)
        let since = age >= impactAge && falling.grow > 0.5 ? age - impactAge : nil
        guard age < exitFall else { return Beat(sinceImpact: since) }
        falling.drop += easeIn(age / exitFall) * fallDepth
        return Beat(jet: falling, sinceImpact: since)
    }

    // MARK: Marks (units of the square)

    /// "!": a bar tapering from its top to its foot, and a round dot clearly apart under it.
    enum Bang {
        static let top = 0.11, topRadius = 0.088, foot = 0.345, footRadius = 0.058
        static let dot = 0.555, dotRadius = 0.074
    }

    /// "?": a round-capped stroke up the stem, curling right into a bowl over the top that ends in a bead at the left,
    /// open below the bead so the hook reads as a hook, and a dot under the stem.
    enum Question {
        static let width = 0.112, bead = 0.063
        static let centre = CGPoint(x: 0.5, y: 0.2), radius = 0.118
        static let arcStart = 40.0 * .pi / 180, arcEnd = -178.0 * .pi / 180
        static let stemTop = 0.335, stemFoot = 0.372
        static let dot = 0.562, dotRadius = 0.07
    }

    /// The check: a round-capped stroke that rises out of the juice.
    enum Check {
        static let points = [CGPoint(x: 0.235, y: 0.425), CGPoint(x: 0.425, y: 0.612), CGPoint(x: 0.775, y: 0.148)]
        static let width = 0.12
        /// How far below its place it starts (units).
        static let depth = 0.66
    }

    /// Which mark a needs-you jet forms: "!" for an approval, "?" for a question.
    enum Mark: Equatable, Sendable {
        case bang, question

        init(_ mood: GlyphMood) { self = mood == .question ? .question : .bang }
    }

    // MARK: Geometry helpers

    /// Adds an arc of `radius` around `centre` from `start` to `end` (radians, y down, either direction) as cubic
    /// Béziers of at most a quarter turn each. Every closed shape here is built with it so all wind the same way and
    /// overlapping parts of one mark fill as one.
    nonisolated static func addArc(_ path: inout Path, centre: CGPoint, radius: Double, from start: Double, to end: Double,
                                   move: Bool) {
        let sweep = end - start
        let count = max(1, Int(ceil(abs(sweep) / (.pi / 2) - 1e-9)))
        let delta = sweep / Double(count), k = 4.0 / 3.0 * tan(delta / 4) * radius
        func point(_ a: Double) -> CGPoint { CGPoint(x: centre.x + radius * cos(a), y: centre.y + radius * sin(a)) }
        if move { path.move(to: point(start)) } else { path.addLine(to: point(start)) }
        var a = start
        for _ in 0..<count {
            let b = a + delta, p0 = point(a), p3 = point(b)
            path.addCurve(to: p3, control1: CGPoint(x: p0.x - k * sin(a), y: p0.y + k * cos(a)),
                          control2: CGPoint(x: p3.x + k * sin(b), y: p3.y - k * cos(b)))
            a = b
        }
    }

    nonisolated static func addCircle(_ path: inout Path, _ centre: CGPoint, _ radius: Double) {
        guard radius > 0 else { return }
        addArc(&path, centre: centre, radius: radius, from: 0, to: 2 * .pi, move: true)
        path.closeSubpath()
    }

    /// The convex hull of two circles (a tapered capsule), wound like `addArc`'s circles.
    nonisolated static func addTaper(_ path: inout Path, _ c1: CGPoint, _ r1: Double, _ c2: CGPoint, _ r2: Double) {
        let r1 = max(0, r1), r2 = max(0, r2)
        let dx = c2.x - c1.x, dy = c2.y - c1.y, d = hypot(dx, dy)
        guard d > abs(r1 - r2) + 1e-9 else {
            addCircle(&path, r1 >= r2 ? c1 : c2, max(r1, r2))
            return
        }
        let a = atan2(dy, dx), b = acos((r1 - r2) / d)
        addArc(&path, centre: c1, radius: r1, from: a + b, to: a - b + 2 * .pi, move: true)
        addArc(&path, centre: c2, radius: r2, from: a - b, to: a + b, move: false)
        path.closeSubpath()
    }

    /// A fixed number in 0 ..< 1 for (`index`, `seed`): bubbles are placed by it, so every frame, render and
    /// re-created view draws the same ones.
    nonisolated static func hash(_ index: Int, _ seed: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(truncatingIfNeeded: seed) &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 30
        h &*= 0xBF58_476D_1CE4_E5B9
        h ^= h >> 27
        h &*= 0x94D0_49BB_1331_11EB
        h ^= h >> 31
        return Double(h >> 11) / Double(UInt64(1) << 53)
    }
}

// MARK: - One moment

extension LiquidGlyph {
    /// One of delegating's droplets: which (0 … 2, left to right), how far it has risen out of the band (0 under it … 1
    /// in place, a little past 1 as it overshoots), how high its hop has it (`HelperBeat.lift`), and how far it has
    /// dropped back (units, down).
    struct Helper: Equatable, Sendable {
        var index: Int
        var rise: Double
        var lift: Double
        var drop: Double
    }

    /// Everything that moves at one moment, worked out once, then turned into shapes by `primitives()`.
    private struct Moment {
        let side: Double
        let time: Double
        var pose: Pose
        /// Surface tilt (units per unit), wave boost after a hit, the body's bob, the mound under a rising jet, and the
        /// ring a hit sends out.
        var slope = 0.0, boost = 0.0, bob = 0.0, mound = 0.0, ripple = 0.0, rippleAge = 0.0
        var jets: [(Mark, Jet)] = []
        /// Delegating's droplets, rising out, floating or dropping back in.
        var helpers: [Helper] = []
        /// How far the check has risen (1 in place); nil when there is none.
        var check: Double?
        /// The done glint's sweep along the surface, 0 … 1.
        var sweep: Double?
        /// Seconds since a mark hit the juice, while its droplets fly.
        var splash: Double?
        /// Small glyphs get bigger waves so the motion stays visible, and drop the finest ripple.
        let waveScale: Double, fine: Double
        /// The lit and shaded edges' width (units): at least half a point.
        let edge: Double

        init(mood: GlyphMood, from: GlyphMood?, changeAge: TimeInterval, time: TimeInterval, side: Double, running: LiquidRunningLook) {
            self.side = side
            self.time = time
            let size = clamp01((side - 14) / 46)
            waveScale = lerp(1.5, 1, size)
            fine = side >= 40 ? 1 : 0.35
            edge = max(0.55 / side, 0.021)
            let age = max(0, changeAge)
            let previous = age.isFinite && from != mood ? from : nil
            let changeTime = time - age
            // Done and idle calm down completely by `settleTime`, whatever sloshes on the way.
            let calm = keepsMoving(mood) ? 1 : 1 - smooth((age - 0.85) / (settleTime - 0.85))

            pose = previous.map { Pose.of($0, running: running).blended(to: .of(mood, running: running), by: smooth(age / 0.75)) }
                ?? .of(mood, running: running)

            // Delegating's droplets rise out of the band one after another, and drop back in when the mood moves on.
            if mood == .delegating {
                for index in 0..<HelperBeat.count {
                    let rise = previous == nil ? 1 : clamp01((age - 0.08 - helperStagger * Double(index)) / helperRise)
                    guard rise > 0 else { continue }
                    helpers.append(Helper(index: index, rise: rise, lift: HelperBeat.lift(at: time, index: index), drop: 0))
                }
            } else if previous == .delegating, age < helperFall {
                for index in 0..<HelperBeat.count {
                    helpers.append(Helper(index: index, rise: 1, lift: HelperBeat.lift(at: changeTime, index: index),
                                          drop: easeIn(age / helperFall) * 0.5))
                }
            }

            var impact: Double?
            var rise: Double?
            if let previous, previous.needsYou {
                let exit = exitBeat(changeTime: changeTime, age: age, time: time)
                if let jet = exit.jet { jets.append((Mark(previous), jet)) }
                impact = exit.sinceImpact
            }
            if mood.needsYou {
                let delay = previous?.needsYou == true || previous == .done ? 0.28 : 0.06
                let beat = needsBeat(changeTime: previous == nil ? nil : changeTime, delay: delay, time: time)
                if let jet = beat.jet { jets.append((Mark(mood), jet)) }
                rise = beat.rise
                if let since = beat.sinceImpact { impact = min(impact ?? since, since) }
            }
            if let rise { mound = 0.07 * sin(.pi * clamp01(rise / 0.2)) }

            var slosh = 0.0
            if let ti = impact {
                let settle = smooth(ti / 0.1), decay = exp(-ti / 0.75), fade = (1 - smooth((ti - 0.9) / 0.5)) * calm
                slosh = -0.3 * decay * sin(2 * .pi * ti / 1.05) * settle * fade
                boost = 1.3 * decay * settle * fade
                bob = 0.02 * exp(-ti / 0.35) * sin(2 * .pi * ti / 0.7) * smooth(ti / 0.05) * fade
                ripple = 0.032 * exp(-ti / 0.4) * smooth(ti / 0.06) * fade
                rippleAge = ti
                if ti < 0.36, calm > 0 { splash = ti }
            }
            if previous != nil {
                slosh += 0.3 * exp(-age / 0.45) * sin(2 * .pi * age / 0.9) * (1 - smooth((age - 0.8) / 0.4)) * calm
            }
            let smallRock = min(1.5, max(1, 1 + (28 - side) / 28))
            slope = pose.rock * (sin(time * 2 * .pi / 3.6) + 0.35 * sin(time * 2 * .pi / 1.7 + 0.8)) * smallRock + slosh

            if mood == .done {
                check = previous == nil ? 1 : easeOut((age - 0.22) / 0.6)
                if previous != nil, age > 0.45, age < 1.2 { sweep = (age - 0.45) / 0.75 }
            } else if previous == .done, age < 0.4 {
                check = 1 - easeIn(age / 0.4)
            }
        }

        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * side, y: y * side) }

        var level: Double { pose.level + bob }

        /// The free surface's height at `x` (units): three rolling waves, the rocking tilt, and while a mark is about, the
        /// mound under a rising jet and the ring a hit sends out.
        func surface(_ x: Double) -> Double {
            let t = time
            let waves = 0.017 * sin(x * 15 + t * 2.6) + 0.010 * sin(x * 24 - t * 3.6 + 1.3) + 0.005 * fine * sin(x * 37 + t * 5.8 + 2.2)
            var y = level + pose.waves * (1 + boost) * waveScale * waves + slope * (x - 0.5) - crests(x)
            let d = x - 0.5
            if mound > 0 { y -= mound * exp(-(d * d) / 0.0081) }
            if ripple > 0 { y -= ripple * cos(2 * .pi * (abs(d) / 0.2 - rippleAge / 0.55)) * exp(-(d * d) / 0.09) }
            return y
        }

        func surfaceSlope(_ x: Double) -> Double { (surface(x + 0.004) - surface(x - 0.004)) / 0.008 }

        /// How far slim running's crests lift the surface at `x` (units): two humps, steeper in front, running left to
        /// right, each rising in over the band's left end and sinking away over its right one.
        func crests(_ x: Double) -> Double {
            guard pose.crest > 0.001 else { return 0 }
            let height = crestHeight * lerp(1.25, 1, clamp01((side - 14) / 14)) * pose.crest
            var lift = 0.0
            for k in 0..<2 {
                let centre = -0.2 + 1.4 * crestRun(time: time, crest: k), d = x - centre
                let width = d > 0 ? crestFront : crestBack
                let window = smooth((centre - pose.left) / 0.22) * smooth((pose.right - centre) / 0.22)
                lift += height * window * exp(-(d * d) / (width * width))
            }
            return lift
        }

        /// The body's outline: the surface as a cubic Hermite spline (its true slope at every knot), end caps that follow
        /// it, and an underside that hangs a little in the middle like a heavy drop.
        func bodyPath() -> Path {
            let bottom = pose.bottom + bob, cap = pose.cap, left = pose.left, right = pose.right
            let xl = left + cap, xr = right - cap
            let sL = surface(xl), sR = surface(xr), dL = surfaceSlope(xl), dR = surfaceSlope(xr)
            let hL = max(0.04, bottom - sL) / 2, hR = max(0.04, bottom - sR) / 2
            let yL = bottom - hL, yR = bottom - hR, k = 0.5523, hang = (xr - xl) * 0.28
            let belly = lerp(0.01, 0.017, clamp01((side - 14) / 46)) * (1 + 0.4 * pose.waves * sin(time * 2.6) + 0.6 * abs(bob) / 0.02)
            var path = Path()
            path.move(to: pt(left, yL))
            path.addCurve(to: pt(xl, sL), control1: pt(left, yL - hL * k), control2: pt(xl - cap * k, sL - dL * cap * k))
            let knots = side >= 40 ? 24 : 14
            var x0 = xl, y0 = sL, d0 = dL
            for i in 1...knots {
                let x1 = xl + (xr - xl) * Double(i) / Double(knots), y1 = i == knots ? sR : surface(x1)
                let d1 = i == knots ? dR : surfaceSlope(x1), h = x1 - x0
                path.addCurve(to: pt(x1, y1), control1: pt(x0 + h / 3, y0 + d0 * h / 3), control2: pt(x1 - h / 3, y1 - d1 * h / 3))
                (x0, y0, d0) = (x1, y1, d1)
            }
            path.addCurve(to: pt(right, yR), control1: pt(xr + cap * k, sR + dR * cap * k), control2: pt(right, yR - hR * k))
            path.addCurve(to: pt(xr, bottom), control1: pt(right, yR + hR * k), control2: pt(xr + cap * k, bottom))
            path.addCurve(to: pt(0.5, bottom + belly), control1: pt(xr - hang, bottom), control2: pt(0.5 + hang, bottom + belly))
            path.addCurve(to: pt(xl, bottom), control1: pt(0.5 - hang, bottom + belly), control2: pt(xl + hang, bottom))
            path.addCurve(to: pt(left, yL), control1: pt(xl - cap * k, bottom), control2: pt(left, yL + hL * k))
            path.closeSubpath()
            return path
        }

        func primitives() -> [Primitive] {
            var out: [Primitive] = []
            let body = bodyPath()
            let top = level - 0.07, underside = pose.bottom + bob + 0.02
            // The body: light under the surface, the colour through the middle, darker toward the underside.
            out.append(Primitive(path: body, paint: .linear([Stop(0, Tone(0.3)), Stop(0.34, Tone(0.03)), Stop(1, Tone(-0.44))],
                                                            from: pt(0.5, top), to: pt(0.5, underside))))
            appendBubbles(to: &out, body: body)
            // A thin rim of the colour along the underside, so the dark lower body still has an edge on black.
            out.append(Primitive(path: body, paint: .solid(Tone(-0.02, opacity: 0.9)),
                                 clips: [Clip(path: body.offsetBy(dx: 0, dy: -edge * 0.8 * side), inverse: true)]))
            // The meniscus: a light band along the surface, wrapping over the shoulders.
            out.append(Primitive(path: body, paint: .solid(Tone(0.66, opacity: 0.96)),
                                 clips: [Clip(path: body.offsetBy(dx: 0, dy: edge * side), inverse: true)]))
            appendGlint(to: &out, body: body)
            appendCrestLight(to: &out, body: body)
            if let sweep {
                let left = pose.left, right = pose.right
                let x = left + (right - left) * (0.5 - 0.5 * cos(.pi * sweep)), strength = sin(.pi * sweep)
                out.append(Primitive(path: body,
                                     paint: .linear([Stop(0, Tone(1, opacity: 0)), Stop(0.5, Tone(1, opacity: strength)), Stop(1, Tone(1, opacity: 0))],
                                                    from: pt(x - 0.16, 0), to: pt(x + 0.16, 0)),
                                     clips: [Clip(path: body.offsetBy(dx: 0, dy: edge * 1.9 * side), inverse: true)]))
            }
            // Marks stand outside the body and above the surface, so they rise out of it and sink back into it.
            let above = Path(CGRect(x: 0, y: -side, width: side, height: (surface(0.5) + 0.03) * side + side))
            let clips = [Clip(path: body, inverse: true), Clip(path: above)]
            for (mark, jet) in jets {
                let shape = mark == .bang ? bangPath(jet) : questionPath(jet)
                appendMark(to: &out, shape: shape, top: 0.02 + jet.drop, bottom: 0.64 + jet.drop, lights: (0.36, 0.04), clips: clips)
            }
            if !helpers.isEmpty {
                // Clipped above the surface where each one is, so a rising droplet comes up out of the band.
                let top = helperRest - helperRadius - helperHop
                appendMark(to: &out, shape: helpersPath(), top: top, bottom: helperRest + helperRadius, lights: (0.42, 0.02),
                           clips: [Clip(path: body, inverse: true), Clip(path: Path(CGRect(x: 0, y: -side, width: side, height: (level + 0.06) * side + side)))])
            }
            appendLeaps(to: &out, body: body)
            if let check {
                let drop = (1 - check) * Check.depth
                appendMark(to: &out, shape: checkPath(drop: drop), top: 0.09 + drop, bottom: 0.69 + drop, lights: (0.74, 0.5), clips: clips)
            }
            appendSplash(to: &out)
            return out
        }

        /// A few bubbles rise through a running body, each on its own period and lane (from `hash`), growing as they rise.
        func appendBubbles(to out: inout [Primitive], body: Path) {
            guard pose.bubbles > 0.01 else { return }
            let count = side >= 20 ? 4 : 3, span = pose.right - pose.left
            for index in 0..<count {
                let period = 1.8 + 0.9 * hash(index, 11), offset = hash(index, 12)
                let lane = pose.left + span * (0.18 + 0.64 * (Double(index) + hash(index, 13)) / Double(count))
                let turns = time / period + offset, phase = turns - floor(turns)
                let x = lane + 0.012 * sin(time * 4.1 + Double(index) * 2)
                let low = pose.bottom + bob - 0.05, high = surface(x) + 0.05
                let y = low - phase * (low - high)
                let radius = max(0.017 + 0.016 * phase, 0.55 / side)
                let alpha = pose.bubbles * pow(sin(.pi * phase), 0.8) * 0.85
                guard alpha > 0.01, high < low else { continue }
                let centre = pt(x, y), r = radius * side
                var dot = Path()
                addCircle(&dot, centre, r)
                guard side >= 40 else {
                    out.append(Primitive(path: dot, paint: .solid(Tone(0.62, opacity: alpha)), clips: [Clip(path: body)]))
                    continue
                }
                // Big enough to show what it is: a clear bubble with a bright skin and a speck of light.
                var skin = dot, speck = Path()
                addArc(&skin, centre: centre, radius: r * 0.72, from: 2 * .pi, to: 0, move: true)
                skin.closeSubpath()
                addCircle(&speck, CGPoint(x: centre.x - r * 0.35, y: centre.y - r * 0.35), r * 0.28)
                out.append(Primitive(path: dot, paint: .solid(Tone(0.5, opacity: alpha * 0.3)), clips: [Clip(path: body)]))
                out.append(Primitive(path: skin, paint: .solid(Tone(0.7, opacity: alpha)), clips: [Clip(path: body)]))
                out.append(Primitive(path: speck, paint: .solid(Tone(0.95, opacity: alpha)), clips: [Clip(path: body)]))
            }
        }

        /// The specular glint: a small bright streak and a dot just under the surface near the left shoulder, riding
        /// the waves and drifting with the rocking.
        func appendGlint(to out: inout [Primitive], body: Path) {
            let span = pose.right - pose.left
            let x = pose.left + span * 0.2 + span * 0.04 * pose.rock / 0.12 * sin(time * 2 * .pi / 3.6 + 0.6)
            let depth = max(0.055, edge * 2.6)
            let y = surface(x) + depth, angle = atan(surfaceSlope(x))
            let streak = CGRect(x: -0.05 * side, y: -0.021 * side, width: 0.1 * side, height: 0.042 * side)
            let place = CGAffineTransform(translationX: x * side, y: y * side).rotated(by: angle)
            var dot = Path()
            addCircle(&dot, pt(x + 0.085 * cos(angle), y + 0.085 * sin(angle) + 0.004), 0.016 * side)
            let paint = Paint.solid(Tone(0.93, opacity: 0.92))
            out.append(Primitive(path: Path(ellipseIn: streak).applying(place), paint: paint, clips: [Clip(path: body)]))
            out.append(Primitive(path: dot, paint: paint, clips: [Clip(path: body)]))
        }

        /// A mark lit from above: a gradient from `lights.0` at its top to `lights.1` at its foot, a light edge on the
        /// upper left, a shaded edge on the lower right, each `edge` wide.
        func appendMark(to out: inout [Primitive], shape: Path, top: Double, bottom: Double, lights: (Double, Double), clips: [Clip]) {
            let e = edge * side
            out.append(Primitive(path: shape, paint: .linear([Stop(0, Tone(lights.0)), Stop(1, Tone(lights.1))],
                                                             from: pt(0.5, top), to: pt(0.5, bottom)), clips: clips))
            out.append(Primitive(path: shape, paint: .solid(Tone(max(lights.0, 0.56) + 0.2, opacity: 0.95)),
                                 clips: clips + [Clip(path: shape.offsetBy(dx: e * 0.55, dy: e), inverse: true)]))
            out.append(Primitive(path: shape, paint: .solid(Tone(lights.1 - 0.3, opacity: 0.9)),
                                 clips: clips + [Clip(path: shape.offsetBy(dx: -e * 0.55, dy: -e), inverse: true)]))
        }

        /// "!": while it grows, the bar, dot and the necks between them rise from under the surface as one column; as it
        /// pinches, the necks thin away and the dot swells until it floats clear of the bar.
        func bangPath(_ jet: Jet) -> Path {
            let g = jet.grow, q = jet.pinch, k = 1 - q, lv = level, drop = jet.drop
            let top = lerp(lv + 0.02, Bang.top, g) + drop, foot = lerp(lv + 0.05, Bang.foot, g) + drop
            let dot = lerp(lv + 0.08, Bang.dot, g) + drop
            let topRadius = lerp(0.05, Bang.topRadius, g), footRadius = lerp(0.05, Bang.footRadius, g)
            let dotRadius = lerp(0.05, Bang.dotRadius, q)
            var path = Path()
            addTaper(&path, pt(0.5, top), topRadius * side, pt(0.5, foot), footRadius * side)
            addCircle(&path, pt(0.5, dot), dotRadius * side)
            if k > 0.01 {
                addTaper(&path, pt(0.5, foot), footRadius * k * side, pt(0.5, dot), 0.05 * k * k * side)
                addTaper(&path, pt(0.5, dot), 0.05 * k * k * side, pt(0.5, lv + 0.12), 0.07 * k * side)
            }
            return path
        }

        /// The "?"'s spine from `from` (units) up the stem, curling right into the bowl and over to its bead.
        func questionSpine(from start: CGPoint, drop: Double) -> Path {
            let c = Question.centre, r = Question.radius, a = Question.arcStart
            let arcStart = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a) + drop)
            var path = Path()
            path.move(to: pt(start.x, start.y + drop))
            path.addLine(to: pt(0.5, Question.stemTop + drop))
            path.addCurve(to: pt(arcStart.x, arcStart.y), control1: pt(0.5, Question.stemTop - 0.03 + drop),
                          control2: pt(arcStart.x - 0.034 * sin(a), arcStart.y + 0.034 * cos(a)))
            addArc(&path, centre: pt(c.x, c.y + drop), radius: r * side, from: a, to: Question.arcEnd, move: false)
            return path
        }

        /// One outline covering both shapes (Core Graphics' union, so the result is a plain path that later clips and
        /// offsets treat like any other).
        func merged(_ a: Path, _ b: Path) -> Path { Path(a.cgPath.union(b.cgPath)) }

        func stroke(_ path: Path, _ width: Double) -> Path {
            path.strokedPath(StrokeStyle(lineWidth: width * side, lineCap: .round, lineJoin: .round))
        }

        /// "?": while it grows, a round-capped stroke runs up from under the surface along the spine, a bead at its tip;
        /// as it pinches, the part below the stem thins away and leaves the dot.
        func questionPath(_ jet: Jet) -> Path {
            let lv = level, base = lv + 0.12, w = Question.width, c = Question.centre, r = Question.radius
            let end = Question.arcEnd, drop = jet.drop
            let terminal = pt(c.x + r * cos(end), c.y + r * sin(end) + drop)
            var bead = Path()
            if jet.pinch <= 0, jet.grow < 1 {
                let spine = questionSpine(from: CGPoint(x: 0.5, y: base), drop: 0)
                // Roughly where the spine crosses the surface, as a fraction of its length.
                let length = (base - Question.stemTop) + 0.11 + r * abs(end - Question.arcStart)
                let trimmed = spine.trimmedPath(from: 0, to: lerp(clamp01((base - lv) / length), 1, jet.grow))
                if let tip = trimmed.currentPoint { addCircle(&bead, tip, Question.bead * side) }
                return merged(stroke(trimmed, w), bead)
            }
            if jet.pinch >= 1 { return formedQuestion().offsetBy(dx: 0, dy: drop * side) }
            let k = 1 - jet.pinch
            addCircle(&bead, terminal, Question.bead * side)
            addCircle(&bead, pt(0.5, Question.dot + drop), lerp(w / 2, Question.dotRadius, jet.pinch) * side)
            var shape = merged(stroke(questionSpine(from: CGPoint(x: 0.5, y: Question.stemFoot), drop: drop), w), bead)
            if k > 0.01 {
                var neck = Path()
                neck.move(to: pt(0.5, base))
                neck.addLine(to: pt(0.5, Question.stemFoot + drop))
                shape = merged(shape, stroke(neck, w * k))
            }
            return shape
        }

        /// The formed "?" (pinched, not dropped) as one outline, built once per size. From the pinch on, about 70 % of
        /// every beat and for as long as a question waits, the mark only floats and falls, so each frame moves this
        /// outline instead of running two Core Graphics unions.
        func formedQuestion() -> Path {
            if let cached = Self.formedQuestions.withLock({ $0[side] }) { return cached }
            let c = Question.centre, r = Question.radius, end = Question.arcEnd
            var bead = Path()
            addCircle(&bead, pt(c.x + r * cos(end), c.y + r * sin(end)), Question.bead * side)
            addCircle(&bead, pt(0.5, Question.dot), Question.dotRadius * side)
            let shape = merged(stroke(questionSpine(from: CGPoint(x: 0.5, y: Question.stemFoot), drop: 0), Question.width), bead)
            Self.formedQuestions.withLock { cache in
                // A handful of sizes ever draw (the pill, the rows, Settings); a render sweep of sizes starts over.
                if cache.count >= 16 { cache.removeAll() }
                cache[side] = shape
            }
            return shape
        }

        /// `formedQuestion()`'s outlines, by side in points.
        private static let formedQuestions = Mutex<[Double: Path]>([:])

        func checkPath(drop: Double) -> Path {
            var line = Path()
            line.addLines(Check.points.map { pt($0.x, $0.y + drop) })
            return stroke(line, Check.width)
        }

        /// Delegating's droplets as one outline. Rising, each is a bead on a neck of juice drawn up out of the band that
        /// thins away as it comes clear (as the "!"'s jet pinches); floating, a round droplet that its hop lifts; dropping,
        /// it falls back in from where it was.
        func helpersPath() -> Path {
            var path = Path()
            for helper in helpers {
                let x = helperXs[helper.index], rise = helper.rise
                let grown = easeOut(rise), overshoot = 0.02 * sin(.pi * clamp01((rise - 0.55) / 0.45))
                let y = lerp(surface(x) + 0.05, helperRest - overshoot, grown) - helperHop * helper.lift + helper.drop
                let radius = helperRadius * (0.55 + 0.45 * smooth(rise / 0.6))
                addCircle(&path, pt(x, y), radius * side)
                let neck = 1 - smooth((rise - 0.35) / 0.4)
                if neck > 0.01 {
                    addTaper(&path, pt(x, y), radius * 0.7 * neck * side, pt(x, surface(x) + 0.04), helperRadius * 0.9 * neck * side)
                }
            }
            return path
        }

        /// Slim running: a bell of light rides under each crest, so the band reads lit where the work is moving, as an
        /// indeterminate progress bar's shimmer does.
        func appendCrestLight(to out: inout [Primitive], body: Path) {
            guard pose.crest > 0.01 else { return }
            for k in 0..<2 {
                let centre = -0.2 + 1.4 * crestRun(time: time, crest: k)
                let window = smooth((centre - pose.left) / 0.22) * smooth((pose.right - centre) / 0.22) * pose.crest
                guard window > 0.01 else { continue }
                let stops = (0...6).map { i -> Stop in
                    let u = Double(i) / 6
                    return Stop(u, Tone(0.62, opacity: 0.6 * window * pow(sin(.pi * u), 2)))
                }
                out.append(Primitive(path: body, paint: .linear(stops, from: pt(centre - 0.15, 0), to: pt(centre + 0.11, 0)),
                                     clips: [Clip(path: body.offsetBy(dx: 0, dy: edge * side), inverse: true)]))
            }
        }

        /// Slim running: each crest throws a droplet up off its top as it passes the middle; it arcs forward and falls
        /// back into the band behind the crest.
        func appendLeaps(to out: inout [Primitive], body: Path) {
            guard pose.crest > 0.01 else { return }
            let radius = max(0.052, 0.75 / side)
            var drops = Path()
            for k in 0..<2 {
                let run = crestRun(time: time, crest: k), tau = (run - leapAt) * crestPeriod
                guard tau > 0, tau < leapFlight else { continue }
                let x0 = -0.2 + 1.4 * leapAt, y0 = level - crestHeight * lerp(1.25, 1, clamp01((side - 14) / 14)) * pose.crest
                let x = x0 + 0.42 * tau, y = y0 - 1.25 * tau + 2.6 * tau * tau
                guard y < surface(x) - 0.2 * radius else { continue }
                addCircle(&drops, pt(x, y), radius * (0.8 + 0.2 * pose.crest) * side)
            }
            guard !drops.isEmpty else { return }
            out.append(Primitive(path: drops, paint: .solid(Tone(0.5, opacity: min(1, pose.crest * 1.2))), clips: [Clip(path: body, inverse: true)]))
        }

        /// Two droplets thrown out to the sides as a mark lands, falling back under the surface.
        func appendSplash(to out: inout [Primitive]) {
            guard let ti = splash else { return }
            let radius = max(0.03, 0.6 / side), alpha = 1 - smooth((ti - 0.22) / 0.14)
            for direction in [-1.0, 1.0] {
                let x = 0.5 + direction * (0.08 + 0.45 * ti), y = level - 0.03 - 0.85 * ti + 2.6 * ti * ti
                guard y < surface(x) - 0.005 else { continue }
                var drop = Path()
                addCircle(&drop, pt(x, y), radius * side)
                out.append(Primitive(path: drop, paint: .solid(Tone(0.4, opacity: alpha))))
            }
        }
    }
}

// MARK: - The rim

/// The Liquid rim: a line of juice along the closed pill's bottom edge while anything runs, in the pill's lowest points.
/// A full-colour core (2 pt thick in the pill's 3 pt band, 2.25 in a taller one) rolls in a gentle travelling wave (in
/// the pill's band, too short to roll in, its top rises and falls with the wave while its bottom holds) and tapers to a
/// point at each end by the body's corner curves (within the wing each end shows in, so a short wing's segment still
/// reads whole), with a lit ridge along its top, a pale glint
/// travelling across it and a soft glow that stays inside the band. When nothing runs it drains from both ends toward
/// the middle, thinning and fading, then draws nothing. Like the glyph, a pure function of the clock and the last change.
enum LiquidRim {
    /// Seconds to fill out from the middle after running starts, and to drain away after it stops.
    static let fillTime: TimeInterval = 0.6, drainTime: TimeInterval = 0.9
    /// How soft the glow and the glint's bloom are (blur radius, points). Both are clipped to the band, and fade in over
    /// its top `glowFeather` points instead of being cut flat there: beside the notch the black body goes on above the
    /// band, so a cut would show as a straight shelf over the crests.
    static let glowBlur: CGFloat = 1.2
    static let glowFeather: CGFloat = 1.5

    /// The core's thickness in a band `height` tall: 2 pt in the pill's 3 pt band, 2.25 pt in a band 3.25 pt or taller.
    nonisolated static func core(height: CGFloat) -> CGFloat { min(2.25, max(1, height - 1)) }

    /// The rim's shapes at `time`, in points in a `width` × `height` band, in drawing order: the glow (blurred), the
    /// core, its lit ridge, the glint over the core and the glint's bloom (blurred). `changeAge` is the seconds since
    /// `running` last changed (infinite when it has not changed since the rim appeared). `ends` is how much of the line
    /// shows from each end (the pill's wings; nil: all of it), and each end tapers within its own.
    nonisolated static func frame(running: Bool, changeAge: TimeInterval = .infinity, time: TimeInterval,
                                  width: CGFloat, height: CGFloat, ends: RimEnds? = nil) -> [LiquidGlyph.Primitive] {
        let age = max(0, changeAge)
        let amount = running ? (age.isFinite ? smooth(age / fillTime) : 1) : (age.isFinite ? 1 - smooth(age / drainTime) : 0)
        guard amount > 0.002, width > 4, height > 0 else { return [] }
        let w = Double(width), h = Double(height), full = Double(core(height: height))
        // The core thins as the line fills out or drains; its tips stay half a point inside the band's ends.
        let half = full / 2 * (0.55 + 0.45 * amount)
        let span = 0.08 + 0.92 * smooth(amount), inner = w - 1
        let xa = 0.5 + inner * (0.5 - span / 2), xb = 0.5 + inner * (0.5 + span / 2), length = xb - xa
        // The waves grow in over 30 pt from each end. Where the band has room the whole core rolls on them, at most 1 pt
        // from the band's middle and 0.3 pt clear of both edges (`lift`). The pill's 3 pt band has room for a fifth of
        // that: the core rolls what it can, and its top rises and falls the rest (`rise`), up to 0.05 pt from the band's
        // top (the black body goes on above it), while its bottom holds 0.3 pt clear of the pill's edge. So the wave
        // still reads, and under the notch the band's last point stays a steady hairline.
        // A short visible end (a narrow wing) takes a shorter ramp and taper, so its segment still reads whole.
        let endL = ends.map { Double($0.left) } ?? w, endR = ends.map { Double($0.right) } ?? w
        let rampL = min(30, w * 0.18, max(3, endL / 2)) * span, rampR = min(30, w * 0.18, max(3, endR / 2)) * span
        let roll = min(1, max(0, h / 2 - full / 2 - 0.3)), travel = min(1, max(0, h / 2 - full / 2 - 0.05))
        let lift = roll * amount, rise = max(0, travel - roll) * amount, base = h / 2
        let rock = 0.14 * sin(time * 2 * .pi / 3.6)
        func wave(_ x: Double) -> Double {
            let envelope = smooth((x - xa) / rampL) * smooth((xb - x) / rampR)
            let waves = 0.68 * sin(2 * .pi * (x / 64 - time / 2.1)) + 0.18 * sin(2 * .pi * (x / 27 - time / 1.3) + 1.1)
            return envelope * (waves + rock * (x / w - 0.5) * 2)
        }
        func y(_ x: Double) -> Double { base - (lift + rise / 2) * wave(x) }
        // The core tapers to a point over its last 18 pt at each end (less on a short line or a short visible end).
        let taperL = min(18, length * 0.3, max(3, endL * 0.45)), taperR = min(18, length * 0.3, max(3, endR * 0.45))
        func thickness(_ x: Double) -> Double {
            (half + rise / 2 * wave(x)) * (smooth((x - xa) / taperL) * smooth((xb - x) / taperR)).squareRoot()
        }
        func slope(_ x: Double) -> Double { (y(x + 0.25) - y(x - 0.25)) / 0.5 }
        /// A ribbon along the line: `scale` × the core's half-thickness either side of a centre line moved `offset` ×
        /// that half-thickness up along the normal, its two edges cubic Hermite splines meeting at the tips.
        func ribbon(scale: Double, offset: Double = 0) -> Path {
            // A knot every 3 pt.
            let knots = max(8, Int(length / 3)), step = length / Double(knots)
            func edge(_ x: Double, _ side: Double) -> CGPoint {
                let s = slope(x), n = 1 / (1 + s * s).squareRoot(), t = thickness(x)
                let up = t * (offset + side * scale)
                return CGPoint(x: x + up * s * n, y: y(x) - up * n)
            }
            func derivative(_ x: Double, _ side: Double) -> CGPoint {
                let e = 0.2, a = edge(max(xa, x - e), side), b = edge(min(xb, x + e), side), d = min(xb, x + e) - max(xa, x - e)
                return CGPoint(x: (b.x - a.x) / d, y: (b.y - a.y) / d)
            }
            // Along the top edge from the left tip, then back along the bottom edge from the right one.
            var path = Path()
            for side in [1.0, -1.0] {
                var x0 = side > 0 ? xa : xb, p0 = edge(x0, side), d0 = derivative(x0, side)
                if side > 0 { path.move(to: p0) }
                for i in 1...knots {
                    let x1 = side > 0 ? xa + step * Double(i) : xb - step * Double(i), dx = x1 - x0
                    let p1 = edge(x1, side), d1 = derivative(x1, side)
                    path.addCurve(to: p1, control1: CGPoint(x: p0.x + d0.x * dx / 3, y: p0.y + d0.y * dx / 3),
                                  control2: CGPoint(x: p1.x - d1.x * dx / 3, y: p1.y - d1.y * dx / 3))
                    (x0, p0, d0) = (x1, p1, d1)
                }
            }
            path.closeSubpath()
            return path
        }
        let a = amount
        // The tips fade over their last few points too, so they end soft rather than cut.
        let tipL = min(0.1, min(8, max(2, endL * 0.25)) / max(1, length)), tipR = min(0.1, min(8, max(2, endR * 0.25)) / max(1, length))
        func faded(_ tone: Double, _ opacity: Double) -> LiquidGlyph.Paint {
            .linear([.init(0, .init(tone, opacity: 0)), .init(tipL, .init(tone, opacity: opacity)),
                     .init(1 - tipR, .init(tone, opacity: opacity)), .init(1, .init(tone, opacity: 0))],
                    from: CGPoint(x: xa, y: 0), to: CGPoint(x: xb, y: 0))
        }
        // The glint: a bell of light 52 pt wide (at most 60 % of a short line, such as the top bar's) travelling left
        // to right, faded with the line's own ends so it never shows past them.
        let turns = time / 3.2, glint = xa + ((turns - floor(turns)) * 1.5 - 0.25) * length
        let bellWidth = min(52, length * 0.6)
        let fade = { (x: Double) in smooth((x - xa) / (length * 0.13)) * smooth((xb - x) / (length * 0.13)) }
        func bell(_ strength: Double) -> LiquidGlyph.Paint {
            let stops = (0...8).map { i -> LiquidGlyph.Stop in
                let u = Double(i) / 8, x = glint + bellWidth * (u - 0.5)
                return .init(u, .init(0.85, opacity: strength * a * pow(sin(.pi * u), 2) * fade(x)))
            }
            return .linear(stops, from: CGPoint(x: glint - bellWidth / 2, y: 0), to: CGPoint(x: glint + bellWidth / 2, y: 0))
        }
        let tube = ribbon(scale: 1)
        let band = [LiquidGlyph.Clip(path: Path(CGRect(x: 0, y: 0, width: w, height: h)), feather: glowFeather)]
        return [
            .init(path: ribbon(scale: 1.35), paint: faded(0.12, 0.8 * a), clips: band, blur: glowBlur),
            .init(path: tube, paint: faded(0.04, a)),
            .init(path: ribbon(scale: 0.34, offset: 0.4), paint: faded(0.6, 0.75 * a)),
            .init(path: tube, paint: bell(0.95)),
            .init(path: ribbon(scale: 1.2), paint: bell(0.6), clips: band, blur: glowBlur),
        ]
    }
}

// MARK: - Easing

nonisolated private func clamp01(_ v: Double) -> Double { v < 0 ? 0 : (v > 1 ? 1 : v) }
nonisolated private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
nonisolated private func smooth(_ v: Double) -> Double { let v = clamp01(v); return v * v * (3 - 2 * v) }
nonisolated private func easeOut(_ v: Double) -> Double { let v = clamp01(v); return 1 - pow(1 - v, 3) }
nonisolated private func easeIn(_ v: Double) -> Double { let v = clamp01(v); return v * v * v }
