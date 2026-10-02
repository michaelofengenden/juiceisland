import AppKit
import Darwin
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// What Theme Glass costs the desktop panel and the batteries (P534), headless: each view in an `NSHostingView`, in a
/// borderless window that is never ordered on screen, in Black and in Glass (the live glass: offscreen the window server
/// composites nothing, so this is the app's side only).
/// - an update: the panel redrawn for a new reading (a battery's percent and the clock move), as every usage change
///   redraws it; each laid out, displayed and committed, its main-thread CPU timed;
/// - at rest: three windows of two seconds of the run loop after the panel settled, its main-thread CPU and how often the
///   run loop woke in each;
/// - batteries in motion: two rows of batteries sliding and fading a step a turn, as the island's usage block does
///   while it unfolds (on glass each battery is a drawing group of its own, for its cuts, P531);
/// - the hover chip's text set (the chip's layout and fitting size).
/// Skipped unless `JI_MEASURE_GLASS=1`:
///   JI_MEASURE_GLASS=1 swift test -c release -Xswiftc -enable-testing --filter PanelGlassMeasurements
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["JI_MEASURE_GLASS"] == "1"))
struct PanelGlassMeasurements {
    @MainActor
    @Observable
    final class Feed {
        var content: DesktopPanelContent
        var step = 0

        init(_ content: DesktopPanelContent) { self.content = content }
    }

    struct Panel: View {
        let feed: Feed
        let theme: JuiceTheme

        var body: some View {
            DesktopPanelBody(content: feed.content, size: feed.content.size ?? Theme.Panel.size)
                .padding(PanelGeometry.margin)
                .environment(\.juiceTheme, theme)
                .environment(\.colorScheme, .dark)
        }
    }

    /// Two rows of batteries (six and five), moved `feed.step` along a 240-step slide and fade.
    struct MovingBatteries: View {
        let feed: Feed
        let theme: JuiceTheme

        var body: some View {
            let phase = Double(feed.step % 240) / 120, t = phase <= 1 ? phase : 2 - phase
            let e = 0.5 - 0.5 * cos(t * .pi)
            VStack(alignment: .leading, spacing: Theme.Panel.rowGap) {
                ForEach(feed.content.rows) { row in PanelProviderRow(row: row, now: feed.content.now, theme: theme) }
            }
            .offset(y: 40 * (1 - e))
            .opacity(0.2 + 0.8 * e)
            .frame(width: 400, height: 140, alignment: .topLeading)
            .environment(\.juiceTheme, theme)
            .environment(\.colorScheme, .dark)
        }
    }

    static func threadNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    static func host<V: View>(_ view: V, size: CGSize) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        return (window, host)
    }

    /// Times `steps` turns of `step` (after 20 unmeasured), each followed by a layout, a display and a commit.
    static func time<V: View>(_ host: NSHostingView<V>, steps: Int, _ step: (Int) -> Void) -> [Double] {
        var ms: [Double] = []
        for i in 0..<(steps + 20) {
            let start = threadNS()
            step(i)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
            if i >= 20 { ms.append(Double(threadNS() - start) / 1e6) }
        }
        return ms
    }

    /// A reading: the first battery's percent and the clock move.
    static func reading(_ content: DesktopPanelContent, _ i: Int) -> DesktopPanelContent {
        var content = content
        if var first = content.rows.first?.batteries.first {
            first.state = .available(percentLeft: 40 + i % 50, isLow: false)
            content.rows[0].batteries[0] = first
        }
        content.now = content.now.addingTimeInterval(5)
        return content
    }

    @Test func thePanelAndItsBatteriesInEachTheme() throws {
        _ = NSApplication.shared
        let env = AppEnvironment.demo()
        let base = PanelGlassRenders.statesContent(env)
        var rows = ["| what | theme | median ms | p95 ms | max ms | turns over 8.3 ms |", "|---|---|---|---|---|---|"]
        func add(_ name: String, _ theme: JuiceTheme, _ ms: [Double]) {
            let sorted = ms.sorted()
            func q(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            rows.append("| \(name) | \(theme) | \(String(format: "%.3f", q(0.5))) | \(String(format: "%.3f", q(0.95))) | "
                + "\(String(format: "%.3f", sorted.last ?? 0)) | \(ms.filter { $0 > 1000.0 / 120 }.count) |")
        }
        var rest: [String] = []
        for theme in JuiceTheme.allCases {
            // An update.
            let feed = Feed(base)
            let (window, host) = Self.host(Panel(feed: feed, theme: theme), size: PanelGlassRenders.window)
            add("panel update", theme, Self.time(host, steps: 240) { feed.content = Self.reading(base, $0) })

            // At rest: nothing asks for a frame.
            var wakes = 0
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in wakes += 1 }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            // Three windows of two seconds each: whatever ticks shows in every one.
            for window in 1...3 {
                wakes = 0
                let start = Self.threadNS()
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                let cpu = Double(Self.threadNS() - start) / 1e6
                rest.append("| \(theme) | \(window) | \(String(format: "%.3f", cpu)) | \(wakes) |")
            }
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            window.contentView = nil

            // Batteries in motion.
            let moving = Feed(base)
            let (motionWindow, motionHost) = Self.host(MovingBatteries(feed: moving, theme: theme), size: CGSize(width: 400, height: 140))
            add("batteries moving", theme, Self.time(motionHost, steps: 480) { moving.step = $0 })
            motionWindow.contentView = nil

            // The chip's text.
            let label = PanelHoverLabelWindow(above: DesktopPanelWindow.panelLevel)
            var ms: [Double] = []
            for i in 0..<120 {
                let start = Self.threadNS()
                label.setText(i.isMultiple(of: 2) ? "Claude · 3 of 6 available · next Main" : "Codex · 12% · resets in 2h 5m", theme: theme)
                label.contentView?.displayIfNeeded()
                CATransaction.flush()
                if i >= 20 { ms.append(Double(Self.threadNS() - start) / 1e6) }
            }
            add("chip text", theme, ms)
            label.close()
        }
        let table = rows.joined(separator: "\n") + "\n\n| at rest | 2 s window | main-thread CPU ms | run-loop wakes |\n|---|---|---|---|\n"
            + rest.joined(separator: "\n")
        print(table)
        if let out = ProcessInfo.processInfo.environment["JI_MEASURE_OUT"] { try table.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}
