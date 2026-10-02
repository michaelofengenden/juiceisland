import Foundation
import Observation
import QuartzCore

/// One island motion as the owner's display showed it (Diagnostics › Motion › Record island motion). Times are ms from
/// the motion's first event and geometry is in points. Events and jobs carry fixed names only, so nothing about a
/// session, a layout or a pill is ever written (P115). A frame's time is its commit on the main thread: a drop in the
/// render server or the GPU is invisible here.
struct MotionReport: Codable, Equatable, Sendable {
    struct Event: Codable, Equatable, Sendable { var name: String; var ms: Double }
    struct Job: Codable, Equatable, Sendable { var steps: [String]; var lateMS: Double; var ms: Double }
    struct ModelSample: Equatable, Sendable { var ms: Double; var geometry: SurfaceGeometry }

    struct Stats: Codable, Equatable, Sendable {
        var p50: Double
        var p95: Double
        var max: Double

        init(_ values: [Double]) {
            let sorted = values.sorted()
            func at(_ q: Double) -> Double {
                sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
            }
            p50 = MotionReport.round(at(0.5))
            p95 = MotionReport.round(at(0.95))
            max = MotionReport.round(sorted.last ?? 0)
        }
    }

    struct Display: Codable, Equatable, Sendable {
        /// The display's frame (the link's `duration`): 8.33 at 120 Hz.
        var frameMS: Double
        /// What the link asked for (minimum, maximum, preferred), and the spacing of the vsyncs it got.
        var linkRange: [Float]
        var linkIntervalMS: Double
        var linkTicks: Int
        /// Vsyncs whose callback never came: the main thread was busy. The observing link ticks at 30 Hz, so there only a
        /// stall over 33 ms counts.
        var missedVsyncs: Int
        var callbackLateMS: Stats
    }

    struct Surface: Codable, Equatable, Sendable {
        /// Frames SwiftUI drew in which the outline moved, and their rate while a frame was owed (`gapMS`: their spacing).
        var frames: Int
        var framesPerSecond: Double
        var gapMS: Stats
        /// The frame the hitches are counted against: with the 120 Hz vote the link's own interval, only observing the
        /// cadence the island drew at, in whole display frames.
        var cadenceMS: Double
        /// Gaps over 1.5 of that frame, the frames they cost, their time beyond one frame, and that time per second of
        /// motion: Apple's hitch-time ratio (under 5 ms/s good, 5 to 10 noticeable, over 10 critical).
        var hitches: Int
        var droppedFrames: Int
        var hitchMS: Double
        var hitchRatioMSPerS: Double
        /// Ticks in which the model moved at least 0.25 pt and no new outline was drawn since the tick before.
        var staleTicks: Int
        /// How far the drawn outline stood from the model's at the same moment (pt), and how long before each frame the
        /// model stood where the frame is (ms, while the model moves at least 200 pt/s).
        var drawnVsModelPt: Stats
        var drawnBehindModelMS: Stats
        var offMainRenders: Int
    }

    /// 2: hitches counted against `Surface.cadenceMS`, no longer the display's frame. 3: `outline`.
    var version = 3
    /// Who drew the outline (Diagnostics › Motion › Outline). With Core Animation's, `surface` and `frames` see none of
    /// it: the render server draws it and a report made on the main thread cannot (judge it on the display, with
    /// Instruments' Animation Hitches); the jobs' lateness still counts.
    var outline = IslandOutline.swiftUI
    var events: [Event]
    var durationMS: Double
    /// Cut short: an interruption (the panel ordered out, the island built again) or the 3 s cap.
    var truncated: Bool
    var display: Display
    var surface: Surface
    var jobsLateMS: Stats
    var jobs: [Job]
    /// The main thread's CPU over the motion, and the recorder's own share of it.
    var mainCPUMS: Double
    var recorderCPUMS: Double
    /// The load average at the start and the end, the thermal state, Low Power Mode.
    var load: [Double]
    var thermal: Int
    var lowPower: Bool
    /// The drawn outline, frame by frame: [ms, width, height].
    var frames: [[Double]]
    /// The model's outline at each vsync: [ms, width, height].
    var model: [[Double]]

    static func round(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// What the motion was: its first event that moves something of its own (a hover's open starts with the swell).
    var name: String {
        let minor: Set<String> = ["swell", "unswell", "content", "tuning", "reduce-motion", "outline"]
        return (events.first { !minor.contains($0.name) } ?? events.first)?.name ?? "motion"
    }

    static func make(_ r: MotionRecorder.Recording, range: CAFrameRateRange, truncated: Bool, mainCPU: Double,
                     loadEnd: Double) -> MotionReport {
        func ms(_ t: CFTimeInterval) -> Double { (t - r.start) * 1000 }
        let frame = median(r.ticks.map { $0.duration * 1000 }) ?? 1000.0 / 120
        let interval = median(r.ticks.map { ($0.targetTimestamp - $0.timestamp) * 1000 }) ?? frame
        var missed = 0
        for (a, b) in zip(r.ticks, r.ticks.dropFirst()) {
            missed += max(0, Int((((b.timestamp - a.timestamp) * 1000) / interval).rounded()) - 1)
        }
        // The frames in which the outline moved.
        var moving: [SurfaceRenderTap.Render] = []
        var movingModel: [SurfaceGeometry?] = [], movingNext: [SurfaceGeometry?] = []
        for (i, render) in r.renders.enumerated() where moving.last.map({ moved($0.geometry, render.geometry, by: 0.01) }) ?? true {
            moving.append(render)
            movingModel.append(i < r.renderModel.count ? r.renderModel[i] : nil)
            movingNext.append(i < r.renderModelNext.count ? r.renderModelNext[i] : nil)
        }
        // A gap between two drawn frames counts only when a frame was owed: the model moved 0.25 pt in the display frame
        // after the first. A designed pause (the close's 50 ms before the height folds) is not a hitch.
        var gaps: [Double] = []
        for i in moving.indices.dropFirst() {
            if let model = movingModel[i - 1], let next = movingNext[i - 1], !moved(model, next, by: 0.25) { continue }
            gaps.append((moving[i].time - moving[i - 1].time) * 1000)
        }
        let span = gaps.reduce(0, +) / 1000
        // What a gap is a hitch against: with the 120 Hz vote, the link's own interval, so a frame it asked for and did
        // not get is one; only observing (the link at 30, never asking the display for more), the cadence the island
        // drew at, its median gap in whole display frames, so a steady 60 reads as steady and its rate (60) says so for
        // the vote's run to answer. Gaps alone cannot tell a cadence SwiftUI chose from a main thread that misses every
        // other vsync evenly: the vote's run can.
        let voted = range == IslandFramePacing.motion
        let cadence = voted ? interval : max(1, ((median(gaps) ?? frame) / frame).rounded()) * frame
        let hitchGaps = gaps.filter { $0 > 1.5 * cadence }
        let hitchMS = hitchGaps.map { $0 - cadence }.reduce(0, +)
        // A tick whose model moved and no outline was drawn since the tick before.
        var stale = 0
        var renderIndex = 0
        for i in r.ticks.indices.dropFirst() where i < r.model.count {
            let (a, b) = (r.ticks[i - 1], r.ticks[i])
            var drew = false
            while renderIndex < moving.count, moving[renderIndex].time <= b.callback {
                if moving[renderIndex].time > a.callback { drew = true }
                renderIndex += 1
            }
            if !drew, moved(r.model[i - 1].geometry, r.model[i].geometry, by: 0.25) { stale += 1 }
        }
        // Drawn against the model at the moment each frame was drawn: how far (pt), and how late (ms): how long before the
        // frame the model stood where the frame is, along the dimension that travels furthest (the model's samples at each
        // tick, interpolated; positive when the drawing trails the model).
        var offsets: [Double] = [], lags: [Double] = []
        let widths = r.model.map { Double($0.geometry.width) }, heights = r.model.map { Double($0.geometry.height) }
        let useHeight = (heights.max() ?? 0) - (heights.min() ?? 0) > (widths.max() ?? 0) - (widths.min() ?? 0)
        let track = useHeight ? heights : widths
        for i in moving.indices {
            if let model = movingModel[i] {
                let drawn = moving[i].geometry
                offsets.append(max(abs(Double(model.width - drawn.width)), abs(Double(model.height - drawn.height))))
            }
            // Only while the model moves at least 200 pt/s: near its rest, a drawn value a hair short of the target reads as
            // "the model was there long ago".
            if let model = movingModel[i], let next = movingNext[i] {
                let step = Double(useHeight ? abs(next.height - model.height) : abs(next.width - model.width))
                guard step / frame * 1000 >= 200 else { continue }
            }
            let t = ms(moving[i].time)
            let value = Double(useHeight ? moving[i].geometry.height : moving[i].geometry.width)
            // The latest moment, up to one frame after this one, at which the model passed `value`.
            var j = track.count - 2
            while j >= 0, r.model[j].ms > t + frame { j -= 1 }
            while j >= 0 {
                let (a, b) = (track[j], track[j + 1])
                if a != b, (value - a) * (value - b) <= 0 {
                    let s = r.model[j].ms + (value - a) / (b - a) * (r.model[j + 1].ms - r.model[j].ms)
                    lags.append(t - s)
                    break
                }
                j -= 1
            }
        }
        let duration = ms(r.ticks.last?.callback ?? r.start)
        let info = ProcessInfo.processInfo
        return MotionReport(
            events: r.events, durationMS: round(duration), truncated: truncated,
            display: Display(frameMS: round(frame), linkRange: [range.minimum, range.maximum, range.preferred ?? 0],
                             linkIntervalMS: round(interval), linkTicks: r.ticks.count, missedVsyncs: missed,
                             callbackLateMS: Stats(r.ticks.map { ($0.callback - $0.timestamp) * 1000 })),
            surface: Surface(frames: moving.count, framesPerSecond: span > 0 ? round(Double(gaps.count) / span) : 0,
                             gapMS: Stats(gaps), cadenceMS: round(cadence), hitches: hitchGaps.count,
                             droppedFrames: hitchGaps.map { max(0, Int(($0 / cadence).rounded()) - 1) }.reduce(0, +),
                             hitchMS: round(hitchMS), hitchRatioMSPerS: span > 0 ? round(hitchMS / span) : 0,
                             staleTicks: stale, drawnVsModelPt: Stats(offsets), drawnBehindModelMS: Stats(lags),
                             offMainRenders: moving.filter { !$0.onMain }.count),
            jobsLateMS: Stats(r.jobs.map(\.lateMS)), jobs: r.jobs, mainCPUMS: round(mainCPU),
            recorderCPUMS: round(Double(r.ownCPU) / 1e6), load: [round(r.load), round(loadEnd)],
            thermal: info.thermalState.rawValue, lowPower: info.isLowPowerModeEnabled,
            frames: moving.prefix(600).map { [round(ms($0.time)), round($0.geometry.width), round($0.geometry.height)] },
            model: r.model.prefix(600).map { [round($0.ms), round($0.geometry.width), round($0.geometry.height)] })
    }

    static func moved(_ a: SurfaceGeometry, _ b: SurfaceGeometry, by threshold: CGFloat) -> Bool {
        abs(a.left - b.left) > threshold || abs(a.right - b.right) > threshold || abs(a.height - b.height) > threshold
            || abs(a.ear - b.ear) > threshold || abs(a.radius - b.radius) > threshold
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }
}

/// Where the reports go: `~/Library/Logs/Juice Island/motion/`, one compact JSON per motion named by its time and its
/// motion, the newest 300 kept, written off the main thread. Timings, geometry and fixed names only.
final class MotionReportFolder: Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.ofengenden.juice.motion-reports", qos: .utility)
    static let keep = 300

    init(url: URL = MotionReportFolder.standard) {
        self.url = url
    }

    static var standard: URL {
        Product.logsFolder().appendingPathComponent("motion", isDirectory: true)
    }

    func write(_ report: MotionReport) {
        let url = url
        queue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(report) else { return }
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let name = report.name.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            try? data.write(to: url.appendingPathComponent("\(Self.stamp(Date()))-\(name).json"), options: .atomic)
            Self.prune(url)
        }
    }

    /// Waits until every write so far is done (tests).
    func flush() { queue.sync {} }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss.SSS"
        return formatter.string(from: date)
    }

    private static func prune(_ url: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        for name in names.dropLast(keep) { try? FileManager.default.removeItem(at: url.appendingPathComponent(name)) }
    }
}

/// The last motions recorded, newest first, for Diagnostics › Motion: one line each (its JSON holds the rest). Kept in
/// memory only, so the pane never reads the folder, and only for the setup they were recorded under: a line cannot say
/// whether it was recorded with the 120 Hz vote or under which feel, so the list starts over when either changes.
@MainActor
@Observable
final class MotionLog {
    struct Entry: Equatable, Identifiable, Sendable {
        let id: Int
        let name: String
        let framesPerSecond: Double
        /// The median lateness of its choreography jobs; nil when it had none (a swell).
        let jobsLateMS: Double?
        let hitches: Int
        let hitchRatio: Double
        /// Core Animation drew the outline: no frame rate or hitch of its own can be read here.
        var coreAnimation = false
    }

    /// What the motions were recorded under: Ask for 120 Hz while moving, Settings › Island › Motion and Hover, and
    /// Diagnostics › Motion › Outline.
    struct Setup: Equatable, Sendable {
        var pace: Bool
        var tuning: MotionTuning
        var outline = IslandOutline.swiftUI
    }

    @ObservationIgnored private var setup: Setup?

    /// The motions from now on are recorded under `setup`: a list recorded under another starts over.
    func recordUnder(_ setup: Setup) {
        defer { self.setup = setup }
        guard let old = self.setup, old != setup, !entries.isEmpty else { return }
        entries = []
    }

    static let keep = 10
    private(set) var entries: [Entry] = []
    @ObservationIgnored private var count = 0

    func add(_ report: MotionReport) {
        count += 1
        let entry = Entry(id: count, name: report.name, framesPerSecond: report.surface.framesPerSecond,
                          jobsLateMS: report.jobs.isEmpty ? nil : report.jobsLateMS.p50, hitches: report.surface.hitches,
                          hitchRatio: report.surface.hitchRatioMSPerS, coreAnimation: report.outline == .coreAnimation)
        entries = Array(([entry] + entries).prefix(Self.keep))
    }
}
