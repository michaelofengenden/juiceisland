import AppKit
import Foundation
import QuartzCore
import Testing
@testable import JuiceIslandUI

/// A display link the test drives: by hand (`fire`), or on a strict main-queue timer at its rate (`automatic`).
@MainActor
final class FakeFrameClock: MotionFrameClock {
    let range: CAFrameRateRange
    /// How often it ticks, and the display frame it reports (an observing link ticks at 30 on a 120 Hz display).
    let frame: CFTimeInterval
    let display: CFTimeInterval
    let automatic: Bool
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var ticks = 0
    private var handler: (@MainActor (FrameTick) -> Void)?
    private var timer: DispatchSourceTimer?

    init(range: CAFrameRateRange = IslandFramePacing.motion, frame: CFTimeInterval = 1.0 / 120, display: CFTimeInterval = 1.0 / 120,
         automatic: Bool = false) {
        self.range = range
        self.frame = frame
        self.display = display
        self.automatic = automatic
    }

    var isRunning: Bool { handler != nil }

    func start(_ tick: @escaping @MainActor (FrameTick) -> Void) {
        starts += 1
        handler = tick
        guard automatic else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + frame, repeating: frame, leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fire(at: CACurrentMediaTime()) } }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        stops += 1
        handler = nil
        timer?.cancel()
        timer = nil
    }

    /// A callback at `t`, `late` after its vsync (`t` snapped to the display's grid). Counted only while running, as a
    /// real link that is not there never calls.
    func fire(at t: CFTimeInterval, late: CFTimeInterval = 0) {
        guard let handler else { return }
        ticks += 1
        let vsync = (t / frame).rounded(.down) * frame
        handler(FrameTick(timestamp: vsync, targetTimestamp: vsync + frame, duration: display, callback: t + late))
    }
}

/// Diagnostics › Motion (E0): the recorder's report, its fixed names, and that nothing ticks at rest, with a fake
/// display link. The tap in the surface's path is global, so this suite runs serialized; other suites may draw an island
/// while a test here records, so frame counts from the tap are never pinned.
@MainActor
@Suite(.serialized)
struct MotionRecorderTests {
    typealias Model = IslandChoreography
    static let frame = 1.0 / 120
    static let record = MotionRecorder.Mode(record: true, pace: false)!
    static let pace = MotionRecorder.Mode(record: false, pace: true)!

    static func model(surface: Model.Surface = .closed) -> Model {
        DIslandMotionTests.model(surface: surface)
    }

    static func geometry(width: CGFloat, height: CGFloat = 33) -> SurfaceGeometry {
        SurfaceGeometry(width: width, height: height, ear: 3, radius: 12.5)
    }

    /// The model on a virtual clock, which the recorder reads as the director's.
    final class Virtual {
        var model: Model
        var t = 0.0
        let base = CACurrentMediaTime()
        init(_ model: Model) { self.model = model }

        func handle(_ event: Model.Event) { _ = model.handle(event, at: t) }

        /// Plays `events` a display frame at a time, as the director would (jobs as they fall due, the recorder told of
        /// each), drawing the model's outline each frame and ticking `clock`, until the recording ends (or `limit` frames).
        @MainActor
        func play(_ events: [(TimeInterval, Model.Event)] = [], recorder: MotionRecorder, clock: FakeFrameClock, limit: Int = 600) {
            var pending = events.sorted { $0.0 < $1.0 }
            var frames = 0
            repeat {
                t += MotionRecorderTests.frame
                while let (at, event) = pending.first, at <= t {
                    pending.removeFirst()
                    _ = model.advance(to: at)
                    _ = model.handle(event, at: at)
                    recorder.observe(event.recordName)
                }
                if let due = model.nextJobTime, due <= t {
                    recorder.jobFired(due: due, steps: model.dueSteps(by: t).map(\.recordName))
                    _ = model.advance(to: t)
                    recorder.observe(nil)
                }
                SurfaceRenderTap.record(model.surface(at: t))
                clock.fire(at: base + t)
                frames += 1
            } while (recorder.isRecording || !pending.isEmpty) && frames < limit
        }
    }

    static func recorder(_ virtual: Virtual, clock: FakeFrameClock, mode: MotionRecorder.Mode = record,
                         write: @escaping @MainActor (MotionReport) -> Void) -> MotionRecorder {
        MotionRecorder(clock: clock, mode: mode, model: { virtual.model }, now: { virtual.t }, write: write)
    }

    // MARK: The report's arithmetic

    /// 60 vsyncs at 120 Hz: one vsync the main thread missed, the outline not drawn for two frames and then for one, and
    /// the model 2 pt ahead of what was drawn. The report counts two hitches, three dropped frames, 25 ms of hitch time,
    /// one missed vsync and three stale ticks, and its JSON round-trips.
    @Test func theReportCountsHitchesMissedVsyncsAndStaleTicks() throws {
        let start = 100.0, f = Self.frame
        var recording = MotionRecorder.Recording(start: start, cpuStart: 0, load: 250)
        for i in 0..<60 where i != 30 {
            let t = start + Double(i) * f
            recording.ticks.append(FrameTick(timestamp: t, targetTimestamp: t + f, duration: f, callback: t + 0.0002))
            recording.model.append(.init(ms: Double(i) * f * 1000, geometry: Self.geometry(width: 236 + CGFloat(i) * 4 + 2)))
        }
        for i in 0..<60 where ![20, 21, 40].contains(i) {
            // Drawn 1 ms after each vsync, 2 pt behind the model (which moves 480 pt/s: 4 pt a frame), so 4.17 ms late.
            recording.renders.append(.init(time: start + Double(i) * f + 0.001, geometry: Self.geometry(width: 236 + CGFloat(i) * 4 + 0.48),
                                           onMain: true))
            recording.renderModel.append(Self.geometry(width: 236 + CGFloat(i) * 4 + 2.48))
        }
        recording.jobs = [.init(steps: ["openHeight"], lateMS: 9, ms: 30), .init(steps: ["header"], lateMS: 25, ms: 40)]
        recording.events = [.init(name: "open-click-list", ms: 0)]
        recording.ownCPU = 1_500_000
        let report = MotionReport.make(recording, range: IslandFramePacing.motion, truncated: false, mainCPU: 12, loadEnd: 251)
        #expect(report.display.missedVsyncs == 1)
        #expect(report.surface.frames == 57)
        #expect(report.surface.hitches == 2)
        #expect(report.surface.droppedFrames == 3)
        #expect(abs(report.surface.hitchMS - 25) < 0.05)
        #expect(report.surface.staleTicks == 3)
        #expect(report.surface.drawnVsModelPt.p50 == 2)
        #expect(abs(report.surface.drawnBehindModelMS.p50 - 4.17) < 0.1)
        #expect(report.jobsLateMS.max == 25 && report.recorderCPUMS == 1.5 && report.mainCPUMS == 12)
        #expect(abs(report.display.frameMS - 8.33) < 0.01)
        #expect(report.display.linkRange == [80, 120, 120])
        let json = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(MotionReport.self, from: json) == report)
    }

    /// A 300 ms motion drawn at a steady cadence with no gap, on a 120 Hz display: observed by the 30 Hz link, a steady
    /// 60 is no hitch (its rate says 60, for the 120 Hz vote to answer); with the vote, whose link asks for every
    /// display frame, the same 60 misses every other one; a steady 120 is clean either way.
    @Test func aSteadyCadenceIsNoHitchUnlessTheVoteAskedForMore() {
        func steady(drawnAt fps: Double, voted: Bool) -> MotionReport {
            let start = 100.0, display = 1.0 / 120, speed = 480.0, link = voted ? display : 1.0 / 30
            var r = MotionRecorder.Recording(start: start, cpuStart: 0, load: 1)
            var t = start
            while t <= start + 0.3 + 1e-9 {
                r.ticks.append(FrameTick(timestamp: t, targetTimestamp: t + link, duration: display, callback: t + 0.0002))
                r.model.append(.init(ms: (t - start) * 1000, geometry: Self.geometry(width: 236 + CGFloat((t - start) * speed))))
                t += link
            }
            t = start
            while t <= start + 0.3 + 1e-9 {
                let width = 236 + CGFloat((t - start) * speed)
                r.renders.append(.init(time: t + 0.001, geometry: Self.geometry(width: width), onMain: true))
                r.renderModel.append(Self.geometry(width: width))
                r.renderModelNext.append(Self.geometry(width: width + CGFloat(display * speed)))
                t += 1 / fps
            }
            r.events = [.init(name: "open-hover-list", ms: 0)]
            return MotionReport.make(r, range: voted ? IslandFramePacing.motion : IslandFramePacing.observe, truncated: false,
                                     mainCPU: 1, loadEnd: 1)
        }
        let observed60 = steady(drawnAt: 60, voted: false), voted60 = steady(drawnAt: 60, voted: true)
        let observed120 = steady(drawnAt: 120, voted: false), voted120 = steady(drawnAt: 120, voted: true)
        #expect(observed60.surface.hitches == 0 && observed60.surface.hitchRatioMSPerS == 0 && abs(observed60.surface.framesPerSecond - 60) < 1,
                "\(observed60.surface)")
        #expect(voted60.surface.hitches > 10 && voted60.surface.hitchRatioMSPerS > 10, "\(voted60.surface)")
        #expect(observed120.surface.hitches == 0 && voted120.surface.hitches == 0)
        #expect(abs(observed60.display.frameMS - 8.33) < 0.01 && abs(observed60.surface.cadenceMS - 16.67) < 0.01
                && abs(voted60.surface.cadenceMS - 8.33) < 0.01, "\(observed60.surface.cadenceMS) \(voted60.surface.cadenceMS)")
        let log = MotionLog()
        log.add(observed60)
        let row = DiagnosticsText.motion(log.entries[0])
        #expect(row.cells == ["open-hover-list", "60", "–", "0"] && row.tone == .normal)
    }

    // MARK: Fixed names

    /// Every event and every job step is written by a fixed name: a session id, a row or a part never reaches a report.
    @Test func everyEventAndStepHasAFixedName() {
        let id = "session-7f3a"
        let layout = DIslandMotionTests.layout()
        let events: [Model.Event] = [
            .swell(true), .swell(false), .open(.hover, .list), .open(.click, .card(sessionID: id)), .open(.attention, .card(sessionID: id)),
            .close(.fold), .close(.abort), .close(.dismiss), .retreat, .resume, .present(.card(sessionID: id)), .present(.list),
            .content(layout), .pill(DIslandMotionTests.referencePill), .show, .hide, .display(Self.model().metrics), .reduceMotion(true),
            .tuning(MotionTuning()),
        ]
        let names = events.map(\.recordName)
        #expect(Set(names) == ["swell", "unswell", "open-hover-list", "open-click-card", "open-attention-card", "close-fold", "close-abort",
                               "close-dismiss", "retreat", "resume", "present-card", "present-list", "content", "pill", "show", "hide",
                               "display", "reduce-motion", "tuning"])
        let steps: [Model.Step] = [
            .openHeight(trigger: 0), .header, .reveal(.row(id)), .foldHeight(IslandMotion.fold), .foldWidth(IslandMotion.fold), .pillIn,
            .pillSleep, .fit, .arriveContent, .tuck(IslandMotion.tuck), .departSnapshot, .barSwap, .drop, .glideStart(id, 12), .cross(id),
            .cross(nil), .glideHome(id, trigger: 0), .listIn(trigger: 0), .cardGone, .glideReset(id), .leavingGone, .contentHeight,
            .reducedOpen, .reducedIn([.row(id)]), .reducedClose, .reducedHeight, .reducedDepart,
        ]
        for name in names + steps.map(\.recordName) {
            #expect(name.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-") } && !name.contains("7f3a"), "\(name)")
        }
    }

    /// One recorded motion as JSON: the report's fixed keys, numbers and fixed names only (a card for a session, its row
    /// and the pill never named), and small: a few kilobytes.
    @Test func aReportIsSmallJSONOfFixedKeysAndNamesOnly() throws {
        let id = "r1"
        let virtual = Virtual(Self.model(surface: .island))
        let clock = FakeFrameClock()
        var reports: [MotionReport] = []
        let recorder = Self.recorder(virtual, clock: clock) { reports.append($0) }
        virtual.play([(0.01, .present(.card(sessionID: id))), (0.2, .close(.fold))], recorder: recorder, clock: clock)
        let report = try #require(reports.first)
        #expect(reports.count == 1 && report.name == "present-card" && report.events.map(\.name) == ["present-card", "close-fold"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(report)
        let text = String(decoding: json, as: UTF8.self)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(Set(object.keys) == ["version", "outline", "events", "durationMS", "truncated", "display", "surface", "jobsLateMS", "jobs",
                                     "mainCPUMS", "recorderCPUMS", "load", "thermal", "lowPower", "frames", "model"])
        let display = try #require(object["display"] as? [String: Any]), surface = try #require(object["surface"] as? [String: Any])
        #expect(Set(display.keys) == ["frameMS", "linkRange", "linkIntervalMS", "linkTicks", "missedVsyncs", "callbackLateMS"])
        #expect(Set(surface.keys) == ["frames", "framesPerSecond", "gapMS", "cadenceMS", "hitches", "droppedFrames", "hitchMS",
                                      "hitchRatioMSPerS", "staleTicks", "drawnVsModelPt", "drawnBehindModelMS", "offMainRenders"])
        let jobs = try #require(object["jobs"] as? [[String: Any]])
        #expect(!jobs.isEmpty && jobs.allSatisfy { Set($0.keys) == ["steps", "lateMS", "ms"] })
        #expect(report.jobs.flatMap(\.steps).contains("cross") && report.jobs.flatMap(\.steps).contains("foldHeight"))
        // No session, row or part id anywhere: the only strings are the fixed names.
        #expect(!text.contains("\"\(id)\"") && !text.contains("row(") && !text.contains("session"))
        var strings: [String] = []
        func collect(_ value: Any) {
            if let s = value as? String { strings.append(s) }
            if let a = value as? [Any] { a.forEach(collect) }
            if let d = value as? [String: Any] { d.values.forEach(collect) }
        }
        collect(object)
        #expect(Set(strings).isSubset(of: Set(report.events.map(\.name) + report.jobs.flatMap(\.steps) + IslandOutline.allCases.map(\.rawValue))))
        #expect(object["outline"] as? String == "swiftUI")
        #expect(json.count < 16_000, "\(json.count) bytes")
    }

    // MARK: Nothing ticks at rest

    /// Recording, on the model's own open played a frame at a time: the link starts once at the open, each job is logged,
    /// the link stops and the tap disarms once the model is at rest, and exactly one report is written. At rest a tick
    /// that still comes does nothing, and events that move nothing start nothing.
    @Test func itRecordsOneMotionAndNothingTicksAtRest() {
        let virtual = Virtual(Self.model())
        let clock = FakeFrameClock()
        var reports: [MotionReport] = []
        let recorder = Self.recorder(virtual, clock: clock) { reports.append($0) }

        recorder.observe("show")
        #expect(!recorder.isRecording && clock.starts == 0 && !SurfaceRenderTap.isArmed, "a model at rest starts nothing")

        virtual.handle(.open(.click, .list))
        recorder.observe(Model.Event.open(.click, .list).recordName)
        #expect(recorder.isRecording && clock.isRunning && SurfaceRenderTap.isArmed)
        virtual.play(recorder: recorder, clock: clock)
        #expect(!recorder.isRecording && !clock.isRunning && !SurfaceRenderTap.isArmed)
        #expect(clock.starts == 1 && clock.stops == 1 && reports.count == 1)
        let report = reports[0]
        #expect(report.name == "open-click-list" && !report.truncated)
        #expect(report.jobs.contains { $0.steps == ["openHeight"] } && report.jobs.contains { $0.steps.contains("fit") })
        #expect(report.jobs.allSatisfy { abs($0.lateMS) < 9 }, "virtual jobs run within a frame of their time")

        // At rest: a tick that still comes does nothing, and an event that moves nothing starts nothing.
        let ticks = clock.ticks
        virtual.t += 1
        clock.fire(at: virtual.base + virtual.t)
        virtual.handle(.pill(DIslandMotionTests.referencePill))
        recorder.observe("pill")
        virtual.handle(.content(virtual.model.layout))
        recorder.observe("content")
        virtual.handle(.tuning(MotionTuning()))
        recorder.observe("tuning")
        #expect(clock.ticks == ticks && clock.starts == 1 && reports.count == 1 && !SurfaceRenderTap.isArmed)
    }

    /// Asking for 120 Hz alone: the link runs at 80 to 120 Hz while the island moves and stops at rest; the tap never
    /// arms and nothing is written.
    @Test func pacingAloneRunsTheLinkOnlyWhileMovingAndWritesNothing() {
        let virtual = Virtual(Self.model())
        let clock = FakeFrameClock()
        var written = 0
        let recorder = Self.recorder(virtual, clock: clock, mode: Self.pace) { _ in written += 1 }
        virtual.handle(.swell(true))
        recorder.observe("swell")
        #expect(clock.isRunning && !SurfaceRenderTap.isArmed)
        virtual.play(recorder: recorder, clock: clock)
        #expect(!clock.isRunning && written == 0 && clock.starts == 1 && clock.stops == 1)
        #expect(Self.pace.range == IslandFramePacing.motion && Self.pace.range.preferred == 120 && Self.pace.range.minimum == 80)
        #expect(Self.record.range == IslandFramePacing.observe && Self.record.range.maximum == 30)
    }

    /// Both switches off: there is no recorder, so the director links nothing and arms nothing through a whole open and
    /// close, and the tap in the surface's path keeps nothing.
    @Test func withBothSwitchesOffNothingIsLinkedOrArmed() {
        #expect(MotionRecorder.Mode(record: false, pace: false) == nil)
        let director = IslandMotionDirector(model: Self.model(), ui: IslandUIState())
        #expect(director.recorder == nil)
        director.send(.open(.click, .list))
        director.send(.close(.fold))
        #expect(!SurfaceRenderTap.isArmed)
        SurfaceRenderTap.record(Self.geometry(width: 300))
        var drained: [SurfaceRenderTap.Render] = []
        SurfaceRenderTap.drain(into: &drained)
        #expect(drained.isEmpty)
    }

    /// A recording cut short (the panel ordered out, the island built again) ends at once: the link stops, the tap
    /// disarms, and its report says it was cut.
    @Test func anInterruptionEndsTheRecordingAtOnce() {
        let virtual = Virtual(Self.model())
        let clock = FakeFrameClock()
        var reports: [MotionReport] = []
        let recorder = Self.recorder(virtual, clock: clock) { reports.append($0) }
        virtual.handle(.open(.hover, .list))
        recorder.observe("open-hover-list")
        virtual.t += 0.05
        clock.fire(at: virtual.base + virtual.t)
        recorder.interrupt()
        #expect(!recorder.isRecording && !clock.isRunning && !SurfaceRenderTap.isArmed)
        #expect(reports.count == 1 && reports[0].truncated)
        recorder.interrupt()
        #expect(reports.count == 1 && clock.stops == 1)
    }

    /// A recording whose link never ticked (the panel's view on no running display, the displays asleep) and so never
    /// ended: the next motion's first event ends it, cut short, and starts that motion's own recording, which it names.
    @Test func aRecordingItsLinkNeverEndedLeavesTheNextMotionItsOwnReport() async throws {
        var model = Self.model()
        _ = model.handle(.open(.click, .list), at: 0)
        var reports: [MotionReport] = []
        let clock = FakeFrameClock()
        let recorder = MotionRecorder(clock: clock, mode: Self.record, model: { model }, now: { 0.01 }, longest: 0.05,
                                      write: { reports.append($0) })
        recorder.observe("open-click-list")
        try await Task.sleep(for: .milliseconds(120))
        var closing = Self.model(surface: .island)
        _ = closing.handle(.close(.fold), at: 0)
        model = closing
        recorder.observe("close-fold")
        #expect(reports.count == 1 && reports.first?.events.map(\.name) == ["open-click-list"] && reports.first?.truncated == true,
                "\(reports.map(\.events))")
        #expect(recorder.isRecording)
        model = Self.model()
        clock.fire(at: CACurrentMediaTime())
        #expect(reports.count == 2 && reports.last?.name == "close-fold" && reports.last?.events.map(\.name) == ["close-fold"])
    }

    /// On the real director, a click open and then a close are each one recording: the link starts once for each and
    /// stops at rest, each job's lateness is logged, and at rest nothing ticks for 300 ms. The recording may run a minute:
    /// the parallel suites can hold the main thread past the 3 s cap, whose tick would end the open's recording before
    /// its starved timer ran (seen in two full runs: the open's report without `openHeight`).
    @Test func theDirectorsMotionsAreRecordedAndNothingTicksAtRest() async throws {
        let clock = FakeFrameClock(automatic: true)
        let director = IslandMotionDirector(model: Self.model(), ui: IslandUIState())
        var reports: [MotionReport] = []
        let recorder = MotionRecorder(clock: clock, mode: Self.record, model: { [weak director] in director?.model },
                                      longest: 60, write: { reports.append($0) })
        director.recorder = recorder
        director.send(.open(.click, .list))
        #expect(clock.isRunning && recorder.isRecording)
        try await Self.waitUntil { !recorder.isRecording }
        director.send(.close(.fold))
        try await Self.waitUntil { !recorder.isRecording }
        let ticks = clock.ticks
        try await Task.sleep(for: .milliseconds(300))
        #expect(clock.ticks == ticks && !clock.isRunning && !SurfaceRenderTap.isArmed)
        #expect(clock.starts == 2 && reports.count == 2)
        #expect(reports.map(\.name) == ["open-click-list", "close-fold"])
        #expect(reports[0].jobs.contains { $0.steps.contains("openHeight") } && reports[1].jobs.contains { $0.steps.contains("foldHeight") })
        #expect(reports.allSatisfy { $0.display.linkTicks > 0 })
    }

    static func waitUntil(_ condition: @MainActor () -> Bool, seconds: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            try #require(Date() < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Folder, log and Diagnostics' rows

    /// The folder writes one compact JSON per motion, named by its time and its motion, and keeps the newest 300.
    @Test func theFolderWritesOneJSONPerMotionAndKeepsTheNewest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("motion-reports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for i in 0..<(MotionReportFolder.keep + 2) {
            try Data().write(to: url.appendingPathComponent(String(format: "20000101-000000.%03d-old.json", i)))
        }
        let folder = MotionReportFolder(url: url)
        folder.write(Self.report(events: ["swell", "open-hover-list"], fps: 118))
        folder.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        #expect(names.count == MotionReportFolder.keep)
        let written = try #require(names.last)
        #expect(written.hasSuffix("-open-hover-list.json") && !names.contains("20000101-000000.000-old.json"))
        let decoded = try JSONDecoder().decode(MotionReport.self, from: Data(contentsOf: url.appendingPathComponent(written)))
        #expect(decoded.surface.framesPerSecond == 118)
    }

    /// A motion is named by its first event that moves something of its own: a hover's open, not the swell before it.
    /// Diagnostics keeps the last ten, newest first.
    @Test func theLogKeepsTheLastTenNewestFirstByTheirOwnNames() {
        #expect(Self.report(events: ["swell", "open-hover-list"]).name == "open-hover-list")
        #expect(Self.report(events: ["swell", "unswell"]).name == "swell")
        #expect(Self.report(events: ["content", "close-fold"]).name == "close-fold")
        let log = MotionLog()
        for i in 0..<12 { log.add(Self.report(events: ["close-fold"], fps: Double(i))) }
        #expect(log.entries.count == MotionLog.keep && log.entries.map(\.framesPerSecond) == (2..<12).reversed().map(Double.init))
        #expect(Set(log.entries.map(\.id)).count == MotionLog.keep)
    }

    /// Diagnostics › Motion's row: the name, frames a second, the jobs' median lateness (– with none), the hitches with
    /// Apple's ratio, amber from 5 ms/s and red over 10.
    @Test func aMotionsRowSaysItsRateLatenessAndHitches() {
        func row(hitches: Int, ratio: Double, jobs: Bool = true) -> (cells: [String], tone: DiagnosticsText.Tone) {
            let log = MotionLog()
            log.add(Self.report(events: ["open-hover-list"], fps: 117.6, hitches: hitches, ratio: ratio, late: jobs ? 5.6 : nil))
            return DiagnosticsText.motion(log.entries[0])
        }
        #expect(row(hitches: 0, ratio: 0).cells == ["open-hover-list", "118", "6 ms", "0"] && row(hitches: 0, ratio: 0).tone == .normal)
        #expect(row(hitches: 1, ratio: 4.9).cells[3] == "1 · 4.9 ms/s" && row(hitches: 1, ratio: 4.9).tone == .normal)
        #expect(row(hitches: 2, ratio: 5).tone == .amber && row(hitches: 3, ratio: 10).tone == .amber)
        #expect(row(hitches: 4, ratio: 10.1).tone == .red)
        #expect(row(hitches: 0, ratio: 0, jobs: false).cells[2] == "–")
        // No outline frame was owed (Reduce Motion's snaps, a swap that keeps the island's size): no rate to say.
        let still = MotionLog()
        still.add(Self.report(events: ["close-fold"], fps: 0))
        #expect(DiagnosticsText.motion(still.entries[0]).cells[1] == "–")
    }

    /// The list never mixes motions recorded under two setups it cannot tell apart: with and without the 120 Hz vote,
    /// or under two feels. It starts over when either changes, and keeps its rows while they stay.
    @Test func theLogStartsOverWhenWhatItRecordsUnderChanges() {
        let log = MotionLog()
        let observe = MotionLog.Setup(pace: false, tuning: MotionTuning())
        log.recordUnder(observe)
        log.add(Self.report(events: ["open-hover-list"]))
        log.recordUnder(observe)
        #expect(log.entries.count == 1)
        log.recordUnder(MotionLog.Setup(pace: true, tuning: MotionTuning()))
        #expect(log.entries.isEmpty)
        log.add(Self.report(events: ["close-fold"]))
        log.recordUnder(MotionLog.Setup(pace: true, tuning: MotionTuning(motion: .refined, hover: .calm)))
        #expect(log.entries.isEmpty)
    }

    static func report(events: [String], fps: Double = 120, hitches: Int = 0, ratio: Double = 0, late: Double? = 4) -> MotionReport {
        var recording = MotionRecorder.Recording(start: 0, cpuStart: 0, load: 1)
        recording.events = events.map { .init(name: $0, ms: 0) }
        if let late { recording.jobs = [.init(steps: ["openHeight"], lateMS: late, ms: 30)] }
        var report = MotionReport.make(recording, range: IslandFramePacing.observe, truncated: false, mainCPU: 1, loadEnd: 1)
        report.surface.framesPerSecond = fps
        report.surface.hitches = hitches
        report.surface.hitchRatioMSPerS = ratio
        return report
    }
}
