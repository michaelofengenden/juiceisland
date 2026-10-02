import AppKit
import Darwin
import Foundation
import IslandEngine
import OpenIslandCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// What the UI layer costs, measured headless: the real closed pill, opened island and Window-mode dashboard, each in
/// an `NSHostingView` in a borderless window that is never ordered on screen, on fixture sessions, for every Glyph
/// style. Each surface runs `JI_MEASURE_SECONDS` (20 by default) after a 1 s warm-up, and reports the process's CPU
/// time over the wall time, its wakeups a second, the glyph frames drawn, its footprint and how much that grew.
///
/// A window that is not on a display has no display link, and there a running `TimelineView` redraws as fast as the
/// run loop turns (a whole core; P89). So a surface someone can see is measured on a `GlyphClock` a timer ticks at the
/// surface's own frame rate (the pill's 20 a second, the rows' 30), the frames a display link would ask for; the
/// numbers are this process's work for them (the window server's compositing is not in them). A hidden surface is
/// measured on its real, paused timelines, whose frames only a debug build counts (`GlyphFrames`); in a release build
/// its CPU is the measure. Skipped unless `JI_MEASURE_UI=1`; `JI_MEASURE_OUT` names a Markdown file for the table.
///   JI_MEASURE_UI=1 swift test --filter UIPerfMeasurements
@MainActor
@Suite(.serialized, .enabled(if: UIPerf.enabled))
struct UIPerfMeasurements {
    @Test func everySurfaceInEveryStyle() throws {
        _ = NSApplication.shared
        typealias S = UIPerf.Scenario
        var scenarios = [S(name: "nothing hosted", surface: .none, sessions: .idle, style: .pixel)]
        for surface in [UIPerf.Surface.pill, .island, .window] {
            scenarios.append(S(name: "\(surface.label) · idle", surface: surface, sessions: .idle, style: .pixel))
        }
        for style in GlyphStyle.allCases {
            scenarios += [
                S(name: "pill · 1 running", surface: .pill, sessions: .oneRunning, style: style),
                S(name: "pill · 1 running · at 30 a second", surface: .pill, sessions: .oneRunning, style: style, frameInterval: 1.0 / 30),
                S(name: "pill · mixed", surface: .pill, sessions: .mixed, style: style),
                S(name: "island · mixed", surface: .island, sessions: .mixed, style: style),
                S(name: "window · mixed", surface: .window, sessions: .mixed, style: style),
            ]
            if style != .pixel {
                scenarios.append(S(name: "pill · 1 running · edge line off", surface: .pill, sessions: .oneRunning, style: style, edgeLine: false))
            }
        }
        for style in GlyphStyle.allCases {
            scenarios += [
                S(name: "pill · 1 running · hidden", surface: .pill, sessions: .oneRunning, style: style, visible: false),
                S(name: "window · mixed · hidden", surface: .window, sessions: .mixed, style: style, visible: false),
            ]
        }
        // `JI_MEASURE_ONLY` keeps the scenarios whose "name · style" contains it.
        let only = ProcessInfo.processInfo.environment["JI_MEASURE_ONLY"]
        let results = scenarios.filter { only == nil || "\($0.name) · \($0.style)".contains(only!) }.map(UIPerf.measure)
        let table = UIPerf.table(results)
        print(table)
        if let out = ProcessInfo.processInfo.environment["JI_MEASURE_OUT"] {
            try table.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}

@MainActor
enum UIPerf {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["JI_MEASURE_UI"] == "1" }
    static var seconds: TimeInterval { ProcessInfo.processInfo.environment["JI_MEASURE_SECONDS"].flatMap(Double.init) ?? 20 }

    enum Surface {
        case none, pill, island, window

        var label: String {
            switch self {
            case .none: "nothing"
            case .pill: "pill"
            case .island: "island"
            case .window: "window"
            }
        }

        var size: CGSize {
            switch self {
            case .none, .pill: CGSize(width: 420, height: 40)
            case .island: CGSize(width: 700, height: 620)
            case .window: CGSize(width: 1200, height: 760)
            }
        }
    }

    enum Sessions { case idle, oneRunning, mixed }

    struct Scenario {
        var name: String
        var surface: Surface
        var sessions: Sessions
        var style: GlyphStyle
        /// false: the surface is hidden (the pill ordered out, the window closed, minimised or covered), measured on its
        /// real timelines, which should not move.
        var visible = true
        /// The clock's tick for a visible surface; nil is the surface's own rate.
        var frameInterval: TimeInterval?
        /// Island › Pill edge line (Liquid and Sand).
        var edgeLine = true

        var tick: TimeInterval { frameInterval ?? (surface == .pill ? ClosedPillView.frameInterval : PixelGlyph.motionInterval) }
    }

    struct Result {
        var scenario: Scenario
        var cpuPercent: Double
        var wakeupsPerSecond: Double
        var footprintMB: Double
        /// What hosting the surface added, from before it was built to the end of the warm-up.
        var hostedMB: Double
        var growthMB: Double
        var framesPerSecond: Double
    }

    // MARK: Measuring

    static func measure(_ scenario: Scenario) -> Result {
        var window: NSWindow?
        var keep: AnyObject?
        let clock = GlyphClock()
        var timer: Timer?
        let bare = Sample.now()
        if scenario.surface != .none {
            let (host, owner) = hosted(scenario, clock: scenario.visible ? clock : nil)
            let frame = NSRect(origin: .zero, size: scenario.surface.size)
            let offscreen = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            offscreen.appearance = NSAppearance(named: .darkAqua)
            offscreen.isReleasedWhenClosed = false
            offscreen.contentView = host
            host.frame = frame
            host.layoutSubtreeIfNeeded()
            window = offscreen
            keep = owner
            if scenario.visible {
                timer = Timer.scheduledTimer(withTimeInterval: scenario.tick, repeats: true) { _ in
                    MainActor.assumeIsolated { clock.date = Date() }
                }
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let before = Sample.now()
        let framesBefore = GlyphFrames.count
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        let after = Sample.now()
        let frames = GlyphFrames.count - framesBefore
        timer?.invalidate()
        window?.contentView = nil
        window?.close()
        _ = keep
        let wall = after.uptime - before.uptime
        func megabytes(_ bytes: Double) -> Double { bytes / 1_048_576 }
        return Result(scenario: scenario, cpuPercent: (after.cpu - before.cpu) / wall * 100,
                      wakeupsPerSecond: Double(after.wakeups &- before.wakeups) / wall,
                      footprintMB: megabytes(Double(after.footprint)),
                      hostedMB: megabytes(Double(before.footprint) - Double(bare.footprint)),
                      growthMB: megabytes(Double(after.footprint) - Double(before.footprint)),
                      framesPerSecond: Double(frames) / wall)
    }

    /// The surface's real root view, on `scenario`'s sessions and style, with its glyphs told whether they are seen,
    /// and on `clock` when given.
    private static func hosted(_ scenario: Scenario, clock: GlyphClock?) -> (NSView, AnyObject) {
        let settings = AppSettings.ephemeral()
        settings.glyphStyle = scenario.style
        settings.glyphEdgeLine = scenario.edgeLine
        let engine = SessionEngine.preview(clock: { Date() })
        engine.loadPreviewEvents(events(scenario.sessions))
        let sessions = EngineSessionsModel(engine: engine, clock: { Date() })
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: Date()), sessions: sessions)
        let motion = SurfaceMotion(scenario.visible ? .shown : .hidden)
        let ui = IslandUIState()
        let notch = IslandTheme.Metrics.referenceNotch
        let pill = PillContent.make(rows: sessions.rows, settings: settings, glance: false, recentlyFinished: nil, now: sessions.now,
                                    notch: notch, menuBar: 33)
        let model = IslandChoreography(metrics: .init(targets: SurfaceTargets(notch: notch, pill: pill)),
                                       surface: scenario.surface == .island ? .island : .closed, at: IslandMotionDirector.now)
        let director = IslandMotionDirector(model: model, ui: ui)
        director.reset(model)
        let root: AnyView
        switch scenario.surface {
        case .none:
            root = AnyView(EmptyView())
        case .pill, .island:
            root = AnyView(IslandRootView(ui: ui, notch: notch, canvas: CGSize(width: IslandPanelSizing.canvasWidth, height: 420),
                                          actions: IslandViewActions(), pillClicked: {}, measured: { [weak director] in director?.measured($0) })
                .environment(env).glyphMotion(motion).environment(\.glyphClock, clock))
        case .window:
            root = AnyView(WindowRootView().environment(env).glyphMotion(motion).environment(\.glyphClock, clock))
        }
        return (NSHostingView(rootView: root), Owner(env: env, ui: ui, motion: motion, director: director))
    }

    private final class Owner {
        let env: AppEnvironment
        let ui: IslandUIState
        let motion: SurfaceMotion
        let director: IslandMotionDirector
        init(env: AppEnvironment, ui: IslandUIState, motion: SurfaceMotion, director: IslandMotionDirector) {
            self.env = env
            self.ui = ui
            self.motion = motion
            self.director = director
        }
    }

    // MARK: Fixtures

    /// Fictional sessions: one Claude session running a tool; or a board with a running session, an approval, a
    /// question and a finished turn in each agent.
    static func events(_ sessions: Sessions) -> [AgentEvent] {
        let now = Date()
        switch sessions {
        case .idle:
            return []
        case .oneRunning:
            return start("perf-run", title: "Measure the island", at: now - 300) + [running("perf-run", at: now - 60)]
        case .mixed:
            var events = start("perf-run", title: "Measure the island", at: now - 300) + [running("perf-run", at: now - 60)]
            events += start("perf-codex", title: "Resize the images", tool: .codex, at: now - 400) + [running("perf-codex", at: now - 90)]
            events += start("perf-approval", title: "Push the branch", at: now - 200)
            events.append(.permissionRequested(PermissionRequested(sessionID: "perf-approval", request: PermissionRequest(
                title: "Bash", summary: "git push -u origin perf", affectedPath: "/tmp/perf", toolName: "Bash", toolUseID: "toolu_perf"),
                timestamp: now - 30)))
            events += start("perf-question", title: "Name the metric", at: now - 250)
            events.append(.questionAsked(QuestionAsked(sessionID: "perf-question", prompt: QuestionPrompt(title: "Which metric?", questions: [
                QuestionPromptItem(question: "Which metric should lead?", header: "Metric", options: [
                    QuestionOption(label: "CPU", description: "Process time over wall time."),
                    QuestionOption(label: "Memory", description: "Physical footprint."),
                ]),
            ]), timestamp: now - 20)))
            events += start("perf-done", title: "Write the report", at: now - 500)
            events.append(.sessionCompleted(SessionCompleted(sessionID: "perf-done", summary: "Wrote the report.", timestamp: now - 100)))
            events += start("perf-codex-done", title: "Tidy the notes", tool: .codex, at: now - 600)
            events.append(.sessionCompleted(SessionCompleted(sessionID: "perf-codex-done", summary: "Tidied.", timestamp: now - 120)))
            return events
        }
    }

    private static func start(_ id: String, title: String, tool: AgentTool = .claudeCode, at date: Date) -> [AgentEvent] {
        let folder = "/tmp/perf-" + id
        return [
            .sessionStarted(SessionStarted(sessionID: id, title: title, tool: tool, origin: .live, initialPhase: .running, summary: "Started.",
                                           timestamp: date,
                                           jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "perf", paneTitle: "perf",
                                                                  workingDirectory: folder, terminalTTY: "/dev/ttys009"),
                                           codexMetadata: tool == .codex ? CodexSessionMetadata(lastUserPrompt: title) : nil,
                                           claudeMetadata: tool == .claudeCode
                                               ? ClaudeSessionMetadata(lastUserPrompt: title, startupSource: .startup) : nil)),
            .activityUpdated(SessionActivityUpdated(sessionID: id, summary: FixtureSessionFeed.promptPrefix + title, phase: .running,
                                                    timestamp: date + 1)),
        ]
    }

    private static func running(_ id: String, at date: Date) -> AgentEvent {
        .activityUpdated(SessionActivityUpdated(sessionID: id, summary: "Running Edit", phase: .running, timestamp: date))
    }

    // MARK: The process

    struct Sample {
        var uptime: TimeInterval
        /// User plus system CPU time of the whole process, in seconds.
        var cpu: TimeInterval
        /// Interrupt and idle wakeups (`TASK_POWER_INFO`).
        var wakeups: UInt64
        /// Physical footprint (Activity Monitor's Memory column), in bytes.
        var footprint: UInt64

        static func now() -> Sample {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
            var power = task_power_info_data_t()
            var powerCount = mach_msg_type_number_t(MemoryLayout<task_power_info_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &power) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(powerCount)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &powerCount)
                }
            }
            var vm = task_vm_info_data_t()
            var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &vm) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
                }
            }
            return Sample(uptime: ProcessInfo.processInfo.systemUptime, cpu: seconds(usage.ru_utime) + seconds(usage.ru_stime),
                          wakeups: power.task_interrupt_wakeups &+ power.task_platform_idle_wakeups, footprint: vm.phys_footprint)
        }
    }

    // MARK: Report

    static func table(_ results: [Result]) -> String {
        var lines = ["Headless UI measurements, \(Int(seconds)) s each after a 1 s warm-up (`JI_MEASURE_UI=1`).", "",
                     "| Surface | Style | CPU % | Wakeups/s | Glyph frames/s | Footprint MB | Hosted MB | Growth MB |",
                     "|---|---|---:|---:|---:|---:|---:|---:|"]
        for result in results {
            let style = result.scenario.surface == .none || result.scenario.sessions == .idle ? "any" : "\(result.scenario.style)"
            lines.append("| \(result.scenario.name) | \(style) | \(String(format: "%.2f", result.cpuPercent)) | "
                         + "\(String(format: "%.0f", result.wakeupsPerSecond)) | \(String(format: "%.1f", result.framesPerSecond)) | "
                         + "\(String(format: "%.1f", result.footprintMB)) | \(String(format: "%+.1f", result.hostedMB)) | "
                         + "\(String(format: "%+.2f", result.growthMB)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
