import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The live island in a hosting view that is never ordered in, on a real director whose job clock the test drives: the
/// root view as the panel hosts it, the controller's card snapshot, the island's measurements flushed at once (a test
/// holds the main queue, so the director's next-turn flush cannot run). Glyphs stand still. Frames are drawn with
/// `cacheDisplay`; a window with no display link steps SwiftUI's animations as the run loop turns.
@MainActor
final class LiveIslandHarness {
    let env: AppEnvironment
    let ui = IslandUIState()
    let clock = FakeJobClock(now: 10)
    let director: IslandMotionDirector
    let hosting: NSHostingView<AnyView>
    let window: NSWindow
    static let notch = IslandTheme.Metrics.referenceNotch
    static let size = CGSize(width: IslandPanelSizing.canvasWidth, height: 520)

    /// `maxHeight`: the tallest the island may be, as the live panel passes it (the list then in its scroll view);
    /// `observe` sees every measurement the director gets.
    init(env: AppEnvironment = .demo(), presenting id: String?, tuning: MotionTuning = MotionTuning(), maxHeight: CGFloat? = nil,
         observe: (@MainActor (IslandMeasure) -> Void)? = nil) {
        _ = NSApplication.shared
        self.env = env
        let layout = DMotionRenders.measure(env: env, notch: Self.notch, card: id)
        let model = IslandChoreography(metrics: .init(targets: SurfaceTargets(notch: Self.notch, pill: .empty), layout: layout, tuning: tuning),
                                       surface: .island, presentation: id.map { .card(sessionID: $0) } ?? .list, at: 10)
        let director = IslandMotionDirector(model: model, ui: ui, clock: clock)
        self.director = director
        let root = IslandRootView(ui: ui, notch: Self.notch, canvas: Self.size, maxHeight: maxHeight, actions: IslandViewActions(), pillClicked: {},
                                  measured: { [weak director] in
                                      observe?($0)
                                      director?.measured($0)
                                  })
        hosting = NSHostingView(rootView: AnyView(root.environment(env).environment(\.colorScheme, .dark)
                .glyphMotion(SurfaceMotion(.hidden))))
        window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: Self.size)
        director.perform = { [unowned self] effect in
            // As the panel controller does.
            guard case let .cardSnapshot(id) = effect else { return }
            let card = id.flatMap { self.env.card(for: $0) ?? self.ui.card }
            if self.ui.card != card { self.ui.card = card }
            if self.ui.aheadCard != nil, self.ui.aheadCard?.sessionID == id || id == nil { self.ui.aheadCard = nil }
        }
        ui.presentation = model.presentation
        ui.card = id.flatMap { env.card(for: $0) }
        director.reset(model)
        settle()
    }

    /// Lays out, lets the run loop turn, flushes what was measured and runs every job due, until nothing is left.
    func settle(_ seconds: TimeInterval = 0.6) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            director.flushMeasurements()
            while clock.fire() {}
        } while Date() < end
    }

    /// Plays the island in real time for `seconds`: SwiftUI's animations run on the clock as the run loop turns, and the
    /// model's jobs fire as their moments come (the job clock follows the real one from where it was). `sample` is called
    /// at each turn with the time since the start.
    func play(for seconds: TimeInterval, sample: (TimeInterval) throws -> Void = { _ in }) rethrows {
        let start = CACurrentMediaTime(), base = clock.now
        var elapsed: TimeInterval = 0
        repeat {
            elapsed = CACurrentMediaTime() - start
            while let due = clock.due, due <= base + elapsed { clock.fire(late: base + elapsed - due) }
            clock.now = base + elapsed
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
            director.flushMeasurements()
            try sample(elapsed)
        } while elapsed < seconds
    }

    /// The canvas as drawn now, as an image.
    func snapshot() throws -> NSImage {
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: hosting.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// The panel's list ⇄ card, as the controller sends it.
    func present(_ presentation: IslandPresentation) {
        ui.presentation = presentation
        director.send(.present(presentation))
    }

    /// The canvas as drawn now: RGBA bytes, `hosting`'s backing scale.
    func image() throws -> [UInt8] {
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try #require(rep.bitmapData)
        return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerPlane))
    }

    /// How bright `image` is between `top` and `bottom` points down the canvas (the sum of its colour channels there,
    /// every other device pixel each way).
    func brightness(_ image: [UInt8], from top: CGFloat, to bottom: CGFloat) -> Double {
        let width = Int(Self.size.width * scale), rows = image.count / (width * 4)
        let first = max(0, Int(top * scale)), last = min(rows, Int(bottom * scale))
        var sum = 0
        for row in Swift.stride(from: first, to: last, by: 2) {
            var i = row * width * 4
            let end = i + width * 4
            while i < end {
                sum += Int(image[i]) + Int(image[i + 1]) + Int(image[i + 2])
                i += 8
            }
        }
        return Double(sum)
    }

    var scale: CGFloat { window.backingScaleFactor }

    /// How bright the canvas is between `top` and `bottom` points down it, as `brightness(_:from:to:)` reads a whole
    /// image, drawing only that band: a whole canvas takes 30 ms or more to draw headless, so a fade of 100 ms was read
    /// in two or three frames and a busy Mac left too few to see it (the card's fade test failed once so, P301).
    func brightness(from top: CGFloat, to bottom: CGFloat) throws -> Double {
        hosting.layoutSubtreeIfNeeded()
        let band = CGRect(x: 0, y: top, width: Self.size.width, height: bottom - top)
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: band))
        hosting.cacheDisplay(in: band, to: rep)
        let data = try #require(rep.bitmapData)
        var sum = 0
        for row in Swift.stride(from: 0, to: rep.pixelsHigh, by: 2) {
            var i = row * rep.bytesPerRow
            let end = i + rep.pixelsWide * 4
            while i < end {
                sum += Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2])
                i += 8
            }
        }
        return Double(sum)
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    /// The calling thread's CPU time for `body`, in ms.
    static func cpu(_ body: () -> Void) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        body()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6
    }
}

/// A small view drawn with `cacheDisplay` in a window that is never ordered in, sampled as SwiftUI steps its animations
/// (with no display link it steps them as the run loop turns). Times are `CACurrentMediaTime`, taken as each frame is
/// read.
@MainActor
final class ProbeHost<Content: View> {
    let hosting: NSHostingView<Content>
    let window: NSWindow
    let size: CGSize

    init(_ size: CGSize, _ content: Content) {
        _ = NSApplication.shared
        self.size = size
        hosting = NSHostingView(rootView: content)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    var scale: CGFloat { window.backingScaleFactor }

    func image() throws -> [UInt8] {
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try #require(rep.bitmapData)
        return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerPlane))
    }

    /// The red, green and blue of the pixel at `(x, y)` points (its top-left device pixel).
    func pixel(_ image: [UInt8], x: CGFloat, y: CGFloat) -> (Int, Int, Int) {
        let row = Int(y * scale), column = Int(x * scale), stride = Int(size.width * scale) * 4
        let i = row * stride + column * 4
        return (Int(image[i]), Int(image[i + 1]), Int(image[i + 2]))
    }

    /// Frames for `seconds`, each with its time, and `atLeast` of them however long that takes: the run loop runs other
    /// suites' main-actor work too, which under load can take most of a short window (two frames in 150 ms, once).
    func sample(for seconds: TimeInterval, every step: TimeInterval = 0.003,
                atLeast: Int = 0) throws -> [(t: CFTimeInterval, image: [UInt8])] {
        var frames: [(CFTimeInterval, [UInt8])] = []
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end || frames.count < atLeast {
            RunLoop.current.run(until: Date().addingTimeInterval(step))
            let t = CACurrentMediaTime()
            frames.append((t, try image()))
        }
        return frames
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

/// A white 20 pt square on black, moved down by a channel's offset (`ChannelOffset`, as a row's glide is drawn).
struct OffsetProbe: View {
    let box: ChannelBox

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            Rectangle().fill(.white).frame(width: 20, height: 20).modifier(ChannelOffset(box: box))
        }
        .frame(width: 40, height: 420, alignment: .top)
    }

    /// The square's top edge in `image`, to a fraction of a device pixel (its first lit row's coverage down the middle).
    @MainActor static func top(_ image: [UInt8], host: ProbeHost<OffsetProbe>) -> Double? {
        let rows = Int(host.size.height * host.scale)
        for row in 0..<rows {
            let (r, _, _) = host.pixel(image, x: 20, y: CGFloat(row) / host.scale)
            if r > 8 { return (Double(row) + 1 - Double(r) / 255) / Double(host.scale) }
        }
        return nil
    }
}

/// A white 60 pt square on black, in focus by a channel (`ChannelFocus` with no blur or drift: its opacity alone).
struct FocusProbe: View {
    let box: ChannelBox

    var body: some View {
        ZStack {
            Color.black
            Rectangle().fill(.white).frame(width: 60, height: 60).modifier(ChannelFocus(box: box, blur: 0, drift: 0))
        }
        .frame(width: 80, height: 80)
    }
}

/// A line of text and a square after it, whose place follows the text's width: in a list part, in a card's header, or
/// on its own (the control).
@MainActor
@Observable
final class TextHolder {
    var text = "Name the app"
}

struct TextProbe: View {
    enum Place { case alone, listPart, cardPart }
    let holder: TextHolder
    let ui: IslandUIState
    let place: Place

    var body: some View {
        let line = HStack(spacing: 6) {
            Text(holder.text).font(.system(size: 13)).foregroundStyle(.white).fixedSize()
            Rectangle().fill(.white).frame(width: 12, height: 12)
        }
        .frame(width: 360, height: 30, alignment: .leading)
        ZStack {
            Color.black
            switch place {
            case .alone: line
            case .listPart: line.islandPart(.row("x"), IslandLive(reduceMotion: false, report: { _ in }), ui: ui)
            case .cardPart: line.cardReveal(CardReveal(ui: ui, id: DIslandKeyTests.approval.sessionID), .cardHeader)
            }
        }
        .frame(width: 380, height: 40)
    }
}

/// Two list parts, each a red or green mark and a line of text, re-sorted on the list's glide as the live list is.
@MainActor
@Observable
final class OrderHolder {
    var order = ["a", "b"]
}

struct ReSortProbe: View {
    let holder: OrderHolder
    let ui: IslandUIState

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            VStack(spacing: 20) {
                ForEach(holder.order, id: \.self) { id in
                    HStack(spacing: 10) {
                        Rectangle().fill(id == "a" ? Color(red: 1, green: 0, blue: 0) : Color(red: 0, green: 1, blue: 0))
                            .frame(width: 12, height: 12)
                        Text(id == "a" ? "Ship the release" : "Bump the version").font(.system(size: 13)).foregroundStyle(.white)
                    }
                    .frame(width: 300, height: 30, alignment: .leading)
                    .islandPart(.row(id), IslandLive(reduceMotion: false, report: { _ in }), ui: ui)
                }
            }
            .animation(.linear(duration: 0.6), value: holder.order)
        }
        .frame(width: 320, height: 100, alignment: .top)
    }
}

/// Motion round B1: the content engine (E5: a store box per channel, each effect on its own curve, one plain
/// transaction per batch) and the ahead → live card switch as a channel write (E4(c)).
@MainActor
@Suite(.serialized)
struct MotionContentEngineTests {
    typealias Model = IslandChoreography
    static let approval = FixtureSessionFeed.ID.approval
    static let question = FixtureSessionFeed.ID.question

    // MARK: E5: the channels as drawn

    /// A channel keeps its velocity through an interruption, as `withAnimation` did: a glide on the unfold turned back on
    /// the fold at 130 ms is drawn as the model's spring that keeps its speed (the model: `ShadowValue.retarget`), never as
    /// one that starts again from rest. Fitted over the whole motion with the best start (±8 ms), as the motion research
    /// fitted it (proto-swiftui §3.4).
    @Test func aChannelKeepsItsVelocityThroughAnInterruption() throws {
        var results: [(keep: Double, restart: Double)] = []
        for _ in 0..<3 {
            let ui = IslandUIState()
            let box = ui.live.glide("x")
            let host = ProbeHost(CGSize(width: 40, height: 420), OffsetProbe(box: box))
            defer { host.close() }
            IslandMotionDirector.write(.animate(IslandMotion.unfold, [.glide("x"): 200]), to: ui)
            let start = CACurrentMediaTime()
            var frames = try host.sample(for: 0.13)
            IslandMotionDirector.write(.animate(IslandMotion.fold, [.glide("x"): 0]), to: ui)
            let turn = CACurrentMediaTime() - start
            frames += try host.sample(for: 0.45)
            let drawn = frames.compactMap { frame in OffsetProbe.top(frame.image, host: host).map { (frame.t - start, $0) } }
            func error(keep: Bool, shift: Double) -> Double {
                var first = ShadowValue.rest(0)
                first.retarget(200, curve: IslandMotion.unfold, at: shift)
                let at = turn + shift
                var second = first
                if keep {
                    second.retarget(0, curve: IslandMotion.fold, at: at)
                } else {
                    second = ShadowValue(from: first.value(at: at), velocity: 0, target: 0, start: at, curve: IslandMotion.fold)
                }
                let squares = drawn.map { t, y in pow(y - (t < at ? first : second).value(at: t), 2) }
                return (squares.reduce(0, +) / Double(max(squares.count, 1))).squareRoot()
            }
            let shifts = stride(from: -0.008, through: 0.008, by: 0.0005)
            let keep = shifts.map { error(keep: true, shift: $0) }.min() ?? .infinity
            let restart = shifts.map { error(keep: false, shift: $0) }.min() ?? .infinity
            #expect(drawn.count > 40, "only \(drawn.count) frames drawn")
            results.append((keep, restart))
        }
        print("velocity through a turn: RMS pt keeping \(results.map { String(format: "%.2f", $0.keep) }), restarting \(results.map { String(format: "%.2f", $0.restart) })")
        let keep = results.map(\.keep).sorted()[1], restart = results.map(\.restart).sorted()[1]
        #expect(keep < 4 && keep * 3 < restart, "keeping \(keep) pt, restarting \(restart) pt")
    }

    /// Content crosses half-way where the model says (SwiftUI runs the model's springs, now scoped to each effect): a
    /// part's focus in and out, and a glide, each within two 120 Hz frames of the model's time.
    @Test func contentCrossesHalfWayWhereTheModelDoes() throws {
        func crossing(_ frames: [(t: Double, v: Double)], at level: Double, rising: Bool) -> Double? {
            for (a, b) in zip(frames, frames.dropFirst()) where rising ? (a.v < level && b.v >= level) : (a.v > level && b.v <= level) {
                guard b.t - a.t < 0.02 else { return nil }
                return a.t + (level - a.v) / (b.v - a.v) * (b.t - a.t)
            }
            return nil
        }
        func modelHalf(_ from: Double, _ to: Double, _ curve: IslandMotion.Curve) -> Double {
            var value = ShadowValue.rest(from)
            value.retarget(to, curve: curve, at: 0)
            var t = 0.0
            while (to > from ? value.value(at: t) < (from + to) / 2 : value.value(at: t) > (from + to) / 2) && t < 2 { t += 0.0001 }
            return t
        }
        var report: [String] = []
        // Focus in and out: the square's middle, against its brightness at half focus drawn still.
        for (from, to, curve) in [(0.0, 1.0, IslandMotion.focusIn), (1.0, 0.0, IslandMotion.focusOut)] {
            var measured: Double?
            for _ in 0..<3 where measured == nil {
                let ui = IslandUIState()
                let box = ui.live.part(.row("x"))
                ui.apply([.part(.row("x")): 0.5])
                let host = ProbeHost(CGSize(width: 80, height: 80), FocusProbe(box: box))
                defer { host.close() }
                let half = Double(host.pixel(try host.image(), x: 40, y: 40).0)
                ui.apply([.part(.row("x")): from])
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                IslandMotionDirector.write(.animate(curve, [.part(.row("x")): to]), to: ui)
                let start = CACurrentMediaTime()
                let frames = try host.sample(for: 0.35).map { ($0.t - start, Double(host.pixel($0.image, x: 40, y: 40).0)) }
                measured = crossing(frames, at: half, rising: to > from)
            }
            let model = modelHalf(from, to, curve)
            let drawn = try #require(measured, "no dense frames around half-way")
            report.append("focus \(from)→\(to): drawn \(Int(drawn * 1000)) ms, model \(Int(model * 1000)) ms")
            #expect(abs(drawn - model) <= 0.0167, "focus \(from) → \(to): half-way at \(drawn), the model's \(model)")
        }
        // A glide down 200 pt.
        var measured: Double?
        for _ in 0..<3 where measured == nil {
            let ui = IslandUIState()
            let host = ProbeHost(CGSize(width: 40, height: 420), OffsetProbe(box: ui.live.glide("x")))
            defer { host.close() }
            IslandMotionDirector.write(.animate(IslandMotion.glide, [.glide("x"): 200]), to: ui)
            let start = CACurrentMediaTime()
            let frames = try host.sample(for: 0.4).compactMap { f in OffsetProbe.top(f.image, host: host).map { (f.t - start, $0) } }
            measured = crossing(frames, at: 100, rising: true)
        }
        let model = modelHalf(0, 200, IslandMotion.glide)
        let drawn = try #require(measured, "no dense frames around half-way")
        report.append("glide: drawn \(Int(drawn * 1000)) ms, model \(Int(model * 1000)) ms")
        print("half-way points: " + report.joined(separator: "; "))
        #expect(abs(drawn - model) <= 0.0167, "glide: half-way at \(drawn), the model's \(model)")
    }

    /// A snap is a true snap (`.linear(duration: 0)`): written while a spring is in flight, the next frame is exactly the
    /// new value and every frame after it too, as the model's `retarget(nil)` has it. Written in a transaction that
    /// disables animations, the spring's displacement plays on over the new value: the reason channels are never written
    /// in one (P230).
    @Test func aSnapLandsExactlyWithASpringInFlight() throws {
        func frames(disabling: Bool) throws -> [Double] {
            let ui = IslandUIState()
            let host = ProbeHost(CGSize(width: 40, height: 420), OffsetProbe(box: ui.live.glide("x")))
            defer { host.close() }
            IslandMotionDirector.write(.animate(IslandMotion.unfold, [.glide("x"): 200]), to: ui)
            _ = try host.sample(for: 0.08)
            if disabling {
                IslandMotionDirector.withoutAnimation { ui.apply([.glide("x"): 300], motion: .spring(IslandMotion.unfold)) }
            } else {
                IslandMotionDirector.write(.animate(nil, [.glide("x"): 300]), to: ui)
            }
            return try host.sample(for: 0.15, atLeast: 8).compactMap { OffsetProbe.top($0.image, host: host) }
        }
        let snapped = try frames(disabling: false)
        #expect(snapped.count > 5 && snapped.allSatisfy { abs($0 - 300) < 0.5 }, "\(snapped.prefix(6))")
        let disabled = try frames(disabling: true)
        // A focus (opacity) written in a transaction that disables animations, 80 ms into a spring toward full.
        func focus(disabling: Bool) throws -> [Int] {
            let ui = IslandUIState()
            let box = ui.live.part(.row("x"))
            let host = ProbeHost(CGSize(width: 80, height: 80), FocusProbe(box: box))
            defer { host.close() }
            IslandMotionDirector.write(.animate(IslandMotion.unfold, [.part(.row("x")): 1]), to: ui)
            _ = try host.sample(for: 0.08)
            if disabling {
                IslandMotionDirector.withoutAnimation { ui.apply([.part(.row("x")): 0.5], motion: .spring(IslandMotion.unfold)) }
            } else {
                IslandMotionDirector.write(.animate(nil, [.part(.row("x")): 0.5]), to: ui)
            }
            return try host.sample(for: 0.15, atLeast: 8).map { host.pixel($0.image, x: 40, y: 40).0 }
        }
        let focusSnapped = try focus(disabling: false), focusDisabled = try focus(disabling: true)
        print("a snap with a spring in flight: offset \(snapped.prefix(3)), with animations disabled \(disabled.prefix(3).map { Int($0) }); "
            + "focus \(focusSnapped.prefix(4)), with animations disabled \(focusDisabled.prefix(8))")
        #expect(Set(focusSnapped).count == 1, "\(focusSnapped)")
    }

    /// No string inside a list part or a card part animates (E5, apple T10): a title that changes in an animated
    /// transaction swaps at once, where the same line on its own crossfades the two strings over the animation.
    @Test func noStringAnimatesInsideAPart() throws {
        func inBetween(_ place: TextProbe.Place) throws -> Int {
            let ui = IslandUIState(), holder = TextHolder()
            ui.card = DIslandKeyTests.approval
            ui.apply([.part(.row("x")): 1, .part(.cardHeader): 1])
            let host = ProbeHost(CGSize(width: 380, height: 40), TextProbe(holder: holder, ui: ui, place: place))
            defer { host.close() }
            // The line's text alone (it starts 10 pt in; the square after it starts past 95 pt and slides as layout does).
            func text(_ image: [UInt8]) -> [Int] {
                (0..<Int(40 * host.scale)).flatMap { row in (12..<95).map { x in host.pixel(image, x: CGFloat(x), y: CGFloat(row) / host.scale).0 } }
            }
            let before = text(try host.image())
            withAnimation(.linear(duration: 0.5)) { holder.text = "Nothing else to ship today" }
            let frames = try host.sample(for: 0.5).map { text($0.image) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let after = text(try host.image())
            #expect(before != after)
            return Set(frames).subtracting([before, after]).count
        }
        let alone = try inBetween(.alone), list = try inBetween(.listPart), card = try inBetween(.cardPart)
        print("text frames between a string change's two ends: alone \(alone), in a list part \(list), in a card part \(card)")
        #expect(alone > 3 && list == 0 && card == 0, "alone \(alone), list \(list), card \(card)")
    }

    /// A list part still moves as one: re-sorted on the list's glide, each part's text rides with its mark over frames of
    /// their own (its strings never animate, its place does, P233).
    @Test func aPartStillMovesAsOneWhenTheListReSorts() throws {
        let ui = IslandUIState(), holder = OrderHolder()
        ui.apply([.part(.row("a")): 1, .part(.row("b")): 1])
        let host = ProbeHost(CGSize(width: 320, height: 100), ReSortProbe(holder: holder, ui: ui))
        defer { host.close() }
        /// The top of the red (a) or green (b) mark, and the rows the text column lights.
        func marks(_ image: [UInt8]) -> (a: CGFloat?, b: CGFloat?, text: [CGFloat]) {
            var a: CGFloat?, b: CGFloat?, text: [CGFloat] = []
            for row in 0..<Int(100 * host.scale) {
                let y = CGFloat(row) / host.scale
                let (r, g, bl) = host.pixel(image, x: 16, y: y)
                if a == nil, r > 200, g < 120, bl < 120 { a = y }
                if b == nil, g > 200, r < 160, bl < 160 { b = y }
                if (34..<160).contains(where: { x in let p = host.pixel(image, x: CGFloat(x), y: y); return p.0 > 90 && p.1 > 90 && p.2 > 90 }) {
                    text.append(y)
                }
            }
            return (a, b, text)
        }
        let rest = marks(try host.image())
        let restA = try #require(rest.a), restB = try #require(rest.b)
        // Where each line's text sits from its mark, at rest.
        let lineA = rest.text.filter { abs($0 - restA - 6) < 12 }.map { $0 - restA }
        let lineB = rest.text.filter { abs($0 - restB - 6) < 12 }.map { $0 - restB }
        #expect(!lineA.isEmpty && !lineB.isEmpty)
        holder.order = ["b", "a"]
        let frames = try host.sample(for: 0.6).map(\.image)
        var between = 0, stray: [String] = []
        for frame in frames {
            let m = marks(frame)
            guard let a = m.a, let b = m.b, abs(a - restA) > 1, abs(a - restB) > 1 else { continue }
            between += 1
            // Every lit row of the text column belongs to a line where its mark is now.
            let bands = lineA.map { a + $0 } + lineB.map { b + $0 }
            for y in m.text where !bands.contains(where: { abs($0 - y) <= 1 }) { stray.append("\(y) with marks at \(a), \(b)") }
        }
        print("re-sort: \(between) frames between, \(stray.count) text rows away from their marks")
        #expect(between > 3 && stray.isEmpty, "\(between) between; \(stray.prefix(3))")
    }

    // MARK: E4(c): the card switch

    /// A card built ahead takes the showing one's place as a write of the channels and the layers' roles: neither card's
    /// views are built or evaluated again, so the switch's turn costs a small share of building a card (thread CPU, so the
    /// machine's load does not count). Before round B1 each layer's role changed its views' environment, and both cards
    /// were evaluated whole (12 to 26 ms in release, P196).
    @Test func theAheadToLiveSwitchCostsAChannelWrite() throws {
        var builds: [Double] = [], switches: [Double] = []
        for _ in 0..<3 {
            let island = LiveIslandHarness(presenting: Self.approval)
            let b = try #require(island.env.card(for: Self.question))
            // Built ahead beside the card that shows, as the panel builds the next that waits.
            builds.append(LiveIslandHarness.cpu {
                island.ui.aheadCard = b
                island.hosting.layoutSubtreeIfNeeded()
            })
            island.settle(0.2)
            switches.append(LiveIslandHarness.cpu {
                island.present(.card(sessionID: Self.question))
                island.hosting.layoutSubtreeIfNeeded()
            })
            #expect(island.ui.card?.sessionID == Self.question && island.ui.leavingCard?.sessionID == Self.approval
                && island.ui.aheadCard == nil)
            island.close()
        }
        let build = builds.sorted()[1], swap = switches.sorted()[1]
        print("card built ahead \(builds.map { String(format: "%.2f", $0) }) ms; ahead → live \(switches.map { String(format: "%.2f", $0) }) ms")
        #expect(swap < 0.5 * build, "the switch cost \(swap) ms against a build's \(build)")
    }

    /// The card that gives way fades out where it is drawn (P133, P231): the first frame after the switch still shows it,
    /// and it goes over frames of its own (the new card's header, whose cross is a job the test holds back, stays out),
    /// never an island emptied in one frame. Before round B1 the switch's writes landed in three updates, and the old
    /// card took the new one's zeroed channels in the first: the island was empty from the first frame.
    @Test func theCardThatGivesWayFadesWhereItIsDrawn() throws {
        let island = LiveIslandHarness(presenting: Self.approval)
        defer { island.close() }
        let b = try #require(island.env.card(for: Self.question))
        island.ui.aheadCard = b
        island.settle(0.3)
        let top = island.director.model.layout.header + 4, bottom = island.director.model.islandHeight
        let before = try island.brightness(from: top, to: bottom)
        island.present(.card(sessionID: Self.question))
        var shares: [Double] = []
        let end = CACurrentMediaTime() + 0.4
        repeat {
            shares.append(try island.brightness(from: top, to: bottom) / before)
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        } while CACurrentMediaTime() < end
        print("the old card's share of its brightness, frame by frame: \(shares.prefix(24).map { String(format: "%.2f", $0) })")
        #expect(before > 0 && (shares.first ?? 0) > 0.6, "the old card was cut: \(shares.prefix(3))")
        #expect(shares.filter { $0 > 0.1 && $0 < 0.9 }.count >= 2 && (shares.last ?? 1) < 0.1, "\(shares.prefix(24))")
    }
}
