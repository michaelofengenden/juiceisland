import AppKit
import Darwin
import Foundation
import QuartzCore
import Synchronization

/// How fast the island asks the display to run while it moves. Apple's ProMotion guide puts a large, fast morph the eye
/// tracks in its "high-impact" class: 80 to 120 Hz, preferring 120.
enum IslandFramePacing {
    static let motion = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    /// The recorder's own link while it only records: slow enough that it never asks the display for more than the
    /// island's own frames do. It reads the display's frame and samples the model; the frames come from the renders.
    static let observe = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
}

/// One display-link callback: the vsync it reports, the one it targets, the display's frame, and when the callback ran
/// (all `CACurrentMediaTime`).
struct FrameTick: Equatable, Sendable {
    var timestamp: CFTimeInterval
    var targetTimestamp: CFTimeInterval
    var duration: CFTimeInterval
    var callback: CFTimeInterval
}

/// A per-vsync clock that runs only between `start` and `stop`: the panel's display link in the app, a fake in tests.
@MainActor
protocol MotionFrameClock: AnyObject {
    func start(_ tick: @escaping @MainActor (FrameTick) -> Void)
    func stop()
    var isRunning: Bool { get }
    /// The range it asks the display for.
    var range: CAFrameRateRange { get }
}

/// The panel view's display link (`NSView.displayLink`): it follows the view's display, fires only while the view is on
/// one, and exists only between `start` and `stop`, so nothing ticks at rest.
@MainActor
final class DisplayLinkClock: NSObject, MotionFrameClock {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var handler: (@MainActor (FrameTick) -> Void)?
    let range: CAFrameRateRange

    init(view: NSView, range: CAFrameRateRange) {
        self.view = view
        self.range = range
    }

    var isRunning: Bool { link != nil }

    func start(_ tick: @escaping @MainActor (FrameTick) -> Void) {
        guard link == nil, let view else { return }
        handler = tick
        let link = view.displayLink(target: self, selector: #selector(fire(_:)))
        link.preferredFrameRateRange = range
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        handler = nil
    }

    @objc private func fire(_ link: CADisplayLink) {
        handler?(FrameTick(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp, duration: link.duration,
                           callback: CACurrentMediaTime()))
    }
}

/// The surface as SwiftUI draws it: `NotchSurfaceShape.path(in:)` reports each geometry it builds while a recording is
/// armed (one a frame: the mask's, whose clipped canvas is the black). Disarmed, a report is one relaxed atomic load.
enum SurfaceRenderTap {
    struct Render: Equatable, Sendable {
        var time: CFTimeInterval
        var geometry: SurfaceGeometry
        var onMain: Bool
    }

    private static let armed = Atomic<Bool>(false)
    private static let buffer = Mutex<[Render]>([])
    /// A tap left armed with nothing draining it (no tick comes) never grows past this.
    static let limit = 2000

    static var isArmed: Bool { armed.load(ordering: .relaxed) }

    static func arm(_ on: Bool) {
        armed.store(on, ordering: .relaxed)
        buffer.withLock { $0.removeAll(keepingCapacity: on) }
    }

    @inline(__always)
    static func record(_ geometry: SurfaceGeometry) {
        guard armed.load(ordering: .relaxed) else { return }
        let render = Render(time: CACurrentMediaTime(), geometry: geometry, onMain: pthread_main_np() != 0)
        buffer.withLock { renders in
            if let last = renders.last, last.geometry == geometry, render.time - last.time < 0.002 { return }
            guard renders.count < limit else { return }
            renders.append(render)
        }
    }

    /// Moves what was recorded to the end of `out`, keeping the buffer's storage.
    static func drain(into out: inout [Render]) {
        buffer.withLock { renders in
            out.append(contentsOf: renders)
            renders.removeAll(keepingCapacity: true)
        }
    }
}

/// Diagnostics › Motion (both off by default): records each island motion on the owner's display, asks for 120 Hz while
/// the island moves, or both. From the event that sets something moving until the model is at rest (an interruption
/// stays one motion; 3 s at most), it keeps each display-link tick, each outline SwiftUI drew, the model's outline at
/// each vsync and each choreography job's lateness, and then writes one `MotionReport`. Only pacing, it runs the link
/// while the island moves and writes nothing. Nothing runs at rest: no link, no timer, the render tap disarmed.
@MainActor
final class MotionRecorder {
    /// What Diagnostics › Motion asks for; with neither switch on there is no recorder at all.
    struct Mode: Equatable, Sendable {
        let record: Bool
        let pace: Bool

        init?(record: Bool, pace: Bool) {
            guard record || pace else { return nil }
            self.record = record
            self.pace = pace
        }

        /// The link's range: the 120 Hz vote while pacing, a slow observer's while it only records.
        var range: CAFrameRateRange { pace ? IslandFramePacing.motion : IslandFramePacing.observe }
    }

    /// The longest one recording runs: a motion that never comes to rest, or a panel off every display.
    static let cap: TimeInterval = 3

    let clock: MotionFrameClock
    let mode: Mode
    /// This recorder's longest recording (`cap`; a test on a starved main thread gives it longer).
    private let longest: TimeInterval
    private let model: @MainActor () -> IslandChoreography?
    private let now: @MainActor () -> TimeInterval
    private let write: @MainActor (MotionReport) -> Void
    private var recording: Recording?

    struct Recording {
        var events: [MotionReport.Event] = []
        var start: CFTimeInterval
        var ticks: [FrameTick] = []
        var renders: [SurfaceRenderTap.Render] = []
        /// The model's outline at each render's moment, in step with `renders`.
        var renderModel: [SurfaceGeometry] = []
        /// And one display frame later: whether the model owed the display a new frame after each render.
        var renderModelNext: [SurfaceGeometry] = []
        var model: [MotionReport.ModelSample] = []
        var jobs: [MotionReport.Job] = []
        var cpuStart: UInt64
        /// The recorder's own main-thread CPU (ns).
        var ownCPU: UInt64 = 0
        var load: Double
    }

    init(clock: MotionFrameClock, mode: Mode, model: @escaping @MainActor () -> IslandChoreography?,
         now: @escaping @MainActor () -> TimeInterval = { IslandMotionDirector.now }, longest: TimeInterval = MotionRecorder.cap,
         write: @escaping @MainActor (MotionReport) -> Void) {
        self.clock = clock
        self.mode = mode
        self.longest = longest
        self.model = model
        self.now = now
        self.write = write
    }

    var isRecording: Bool { recording != nil }

    /// After the director applied `event` (a job: nil): starts a recording when something now moves, and notes the event
    /// in the one running.
    func observe(_ event: String?) {
        let t = CACurrentMediaTime()
        // A recording past its longest whose link never ticked to end it (the panel's view on no running display): it
        // ends here, cut short, and this event starts the next motion's own.
        if let start = recording?.start, t - start > longest { finish(truncated: true) }
        if recording == nil {
            guard let m = model(), !m.isAtRest(at: now()) else { return }
            recording = Recording(start: t, cpuStart: Self.threadCPU(), load: Self.load())
            if mode.record { SurfaceRenderTap.arm(true) }
            clock.start { [weak self] tick in self?.tick(tick) }
        }
        guard let start = recording?.start else { return }
        if mode.record, let event { recording?.events.append(.init(name: event, ms: MotionReport.round((t - start) * 1000))) }
    }

    /// The director's timer fired for the jobs due at `due` (model time), running `steps`.
    func jobFired(due: TimeInterval, steps: [String]) {
        guard mode.record, let start = recording?.start else { return }
        let late = (now() - due) * IslandMotion.slowdown * 1000
        recording?.jobs.append(.init(steps: steps, lateMS: MotionReport.round(late),
                                     ms: MotionReport.round((CACurrentMediaTime() - start) * 1000)))
    }

    /// The panel ordered out or the island was built again: whatever runs ends now.
    func interrupt() {
        guard recording != nil else { return }
        finish(truncated: true)
    }

    private func tick(_ tick: FrameTick) {
        let cpu = Self.threadCPU()
        guard let start = recording?.start else { return }
        guard let m = model() else { return finish(truncated: true) }
        if mode.record {
            // Written in place (optional chaining), so no tick copies what was recorded so far.
            recording?.ticks.append(tick)
            let before = recording?.renders.count ?? 0
            SurfaceRenderTap.drain(into: &recording!.renders)
            for render in recording!.renders[before...] {
                recording?.renderModel.append(m.surface(at: render.time / IslandMotion.slowdown))
                recording?.renderModelNext.append(m.surface(at: (render.time + tick.duration) / IslandMotion.slowdown))
            }
            recording?.model.append(.init(ms: (tick.timestamp - start) * 1000, geometry: m.surface(at: tick.timestamp / IslandMotion.slowdown)))
        }
        let atRest = m.isAtRest(at: now())
        recording?.ownCPU &+= Self.threadCPU() &- cpu
        if atRest { finish(truncated: false) } else if tick.callback - start > longest { finish(truncated: true) }
    }

    private func finish(truncated: Bool) {
        clock.stop()
        guard var recording else { return }
        self.recording = nil
        guard mode.record else { return }
        let before = recording.renders.count
        SurfaceRenderTap.drain(into: &recording.renders)
        SurfaceRenderTap.arm(false)
        if let m = model() {
            let frame = recording.ticks.last?.duration ?? 1.0 / 120
            for render in recording.renders[before...] {
                recording.renderModel.append(m.surface(at: render.time / IslandMotion.slowdown))
                recording.renderModelNext.append(m.surface(at: (render.time + frame) / IslandMotion.slowdown))
            }
        }
        write(MotionReport.make(recording, range: clock.range, truncated: truncated,
                                mainCPU: Double(Self.threadCPU() &- recording.cpuStart) / 1e6, loadEnd: Self.load()))
    }

    static func threadCPU() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    /// The one-minute load average.
    static func load() -> Double {
        var load = [0.0, 0, 0]
        return getloadavg(&load, 3) > 0 ? load[0] : -1
    }
}

extension IslandChoreography.Event {
    /// A fixed name for a motion report: never a session, a layout or a pill's content (P115).
    var recordName: String {
        switch self {
        case let .swell(on): on ? "swell" : "unswell"
        case let .open(reason, presentation): "open-\(reason.recordName)-\(presentation.recordName)"
        case let .close(style): "close-\(style.recordName)"
        case .retreat: "retreat"
        case .resume: "resume"
        case let .present(presentation): "present-\(presentation.recordName)"
        case .list(.showAll): "show-all"
        case let .list(.strip(open)): open ? "strip-open" : "strip-fold"
        case .content: "content"
        case .pill: "pill"
        case .show: "show"
        case .hide: "hide"
        case .display: "display"
        case .reduceMotion: "reduce-motion"
        case .tuning: "tuning"
        case .outline: "outline"
        }
    }
}

extension IslandChoreography.Step {
    /// A fixed name for a motion report's job log: never a part's, a row's or a session's id (P115).
    var recordName: String {
        switch self {
        case let .liquid(beat): "liquid.\(beat)"
        case .openHeight: "openHeight"
        case .header: "header"
        case .reveal: "reveal"
        case .foldHeight: "foldHeight"
        case .foldWidth: "foldWidth"
        case .pillIn: "pillIn"
        case .pillSleep: "pillSleep"
        case .fit: "fit"
        case .arriveContent: "arriveContent"
        case .tuck: "tuck"
        case .departSnapshot: "departSnapshot"
        case .barSwap: "barSwap"
        case .drop: "drop"
        case .glideStart: "glideStart"
        case .cross: "cross"
        case .glideHome: "glideHome"
        case .listIn: "listIn"
        case .cardGone: "cardGone"
        case .glideReset: "glideReset"
        case .leavingGone: "leavingGone"
        case .contentHeight: "contentHeight"
        case .reducedOpen: "reducedOpen"
        case .reducedIn: "reducedIn"
        case .reducedClose: "reducedClose"
        case .reducedHeight: "reducedHeight"
        case .reducedDepart: "reducedDepart"
        case .shoulders: "shoulders"
        case .listSwap: "listSwap"
        }
    }
}

extension IslandHoverMachine.OpenReason {
    fileprivate var recordName: String {
        switch self {
        case .hover: "hover"
        case .click: "click"
        case .attention: "attention"
        }
    }
}

extension IslandHoverMachine.CloseStyle {
    fileprivate var recordName: String {
        switch self {
        case .fold: "fold"
        case .abort: "abort"
        case .dismiss: "dismiss"
        }
    }
}

extension IslandPresentation {
    fileprivate var recordName: String {
        if case .card = self { return "card" }
        return "list"
    }
}
