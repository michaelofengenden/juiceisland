import AppKit
import IslandEngine
import JuiceCore
import OpenIslandCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The island and window polish of 2026-09-25 (P133): battery digits never cut at the fill edge, a host said once in
/// Detailed, Show all scrolling inside the display, the window's list with nothing that needs you, a Running card with
/// only idle Codex sessions, and no sessions at all. Renders: `W-*.png`.
@MainActor
@Suite(.serialized)
struct PolishRenders {
    // MARK: Batteries

    /// Every percent the fill edge can cut a digit at, on the window's battery and Juice's (island, panel, Settings),
    /// normal and low, at 2x and enlarged 4 times.
    @Test func batteries() throws {
        let percents = [3, 9, 12, 18, 25, 33, 37, 45, 50, 55, 63, 71, 82, 90, 100]
        func battery(_ percent: Int, low: Bool) -> BatteryModel {
            BatteryModel(id: "b\(percent)", alias: "b", state: .available(percentLeft: percent, isLow: low), isNext: false, hoverLabel: "")
        }
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach([false, true], id: \.self) { low in
                HStack(spacing: 8) {
                    ForEach(percents, id: \.self) { UsageBatteryView(battery: battery($0, low: low), now: DemoClock.now) }
                }
                HStack(spacing: 11) {
                    ForEach(percents, id: \.self) { BatteryView(battery: battery($0, low: low), now: DemoClock.now) }
                }
            }
        }
        .padding(12)
        .background(Color.black)
        try RenderHarness.render(sheet, "W-batteries")
        try RenderHarness.renderPixels(sheet.environment(AppEnvironment.demo()), "W-batteries-zoom", scale: 2, zoom: 2)
    }

    // MARK: Detailed hosts

    /// Detailed rows where most run in Terminal: Terminal is said by leaving it off, Ghostty and Codex.app keep theirs.
    @Test func detailedHosts() throws {
        var rows = [
            DStub.row("h0", .claude, .needsYou, project: "juice-island", task: "Push the window mode", minutesAgo: 3),
            DStub.row("h1", .claude, .running, project: "WeatherStation", task: "Island section for Juice", minutesAgo: 12),
            DStub.row("h2", .codex, .running, project: "notes-site", task: "Draft release notes", minutesAgo: 5),
            DStub.row("h3", .codex, .done, project: "Desktop", task: "mcp images", minutesAgo: 20),
        ]
        rows[2].host = "Ghostty"
        rows[3].host = "Codex.app"
        rows[3].isCodexApp = true
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .detailed
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: rows))
        let view = OpenedIslandView(presentation: .list, notch: IslandTheme.Metrics.referenceNotch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: IslandTheme.Metrics.referenceNotch), "W-island-detailed-hosts", env: env)
    }

    // MARK: Show all

    /// Thirty sessions and Show all on a 14-inch display (982 pt): the island stops 24 pt above the bottom and its list
    /// scrolls inside, with no scroll bars; at the top the bottom edge fades (more below), 304 pt down both edges do.
    @Test func showAllScrolls() async throws {
        _ = NSApplication.shared
        typealias Rig = FramePerf.IslandRig
        typealias Waits = ShowAllScrollTests
        let rig = Rig(style: .clean, scenario: .empty, events: ShowAllScrollTests.sessions(30), glyphsMove: false)
        await rig.start()
        rig.open()
        await Waits.until(rig) { Waits.openAtRest(rig) }
        withAnimation(IslandMotion.glide.animation) { rig.ui.showAll = true }
        #expect(await Waits.until(rig) { Waits.openAtRest(rig) && rig.director.model.islandHeight > Rig.maxHeight - 60 })
        await FramePerf.wait(0.4)
        let height = rig.director.model.islandHeight + 24
        try Self.snapshot(rig, height: height, "W-island-showall-30-top")
        if let scroll = Self.scrollView(in: rig.host) {
            let clip = scroll.contentView
            var bounds = clip.bounds
            bounds.origin.y = 304
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
            await FramePerf.wait(0.4)
            try Self.snapshot(rig, height: height, "W-island-showall-30-middle")
        }
        rig.stop()
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    /// The rig's canvas, cropped to the island and `height` of it, drawn over the board's wallpaper.
    static func snapshot(_ rig: FramePerf.IslandRig, height: CGFloat, _ name: String) throws {
        let host = rig.host
        host.layoutSubtreeIfNeeded()
        let size = CGSize(width: host.bounds.width, height: min(host.bounds.height, height))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let full = rep.cgImage,
              let cropped = full.cropping(to: CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2)) else { return }
        let image = NSImage(cgImage: cropped, size: size)
        let board = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: 0x161E1D), Color(hex: 0x2A3932)], startPoint: .top, endPoint: .bottom)
            Image(nsImage: image)
        }
        .frame(width: size.width, height: size.height)
        try RenderHarness.render(board, name)
    }

    // MARK: Window

    private func list(_ name: String, rows: [SessionRow], height: CGFloat = 320) throws {
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: rows))
        let view = SessionListView()
            .frame(width: 1200, height: height)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, name, size: CGSize(width: 1216, height: height + 16), env: env)
    }

    /// Nothing needs you: Running and Done start the list, with no "Nothing needs you" line over them.
    @Test func windowNothingNeedsYou() throws {
        try list("W-window-nothing-needs-you-1200", rows: [
            DStub.row("w0", .claude, .running, project: "WeatherStation", task: "Island section for Juice", minutesAgo: 12),
            DStub.row("w1", .codex, .running, project: "Desktop", task: "mcp images", minutesAgo: 4),
            DStub.row("w2", .claude, .done, project: "MarathonTrainingLog", task: "Continue", minutesAgo: 40),
        ])
    }

    /// Only Codex sessions idle at the prompt: the card is the group itself, "Codex 2", never "Running".
    @Test func windowIdleCodexOnly() throws {
        func idle(_ id: String, _ project: String, _ task: String, _ minutes: Double) -> SessionRow {
            var row = DStub.row(id, .codex, .done, status: .done, project: project, task: task, minutesAgo: minutes)
            row.detail = nil
            return row
        }
        try list("W-window-idle-codex-1200", rows: [idle("i0", "notes-site", "Draft release notes", 18),
                                                     idle("i1", "Desktop", "mcp images", 30)], height: 200)
    }
}
