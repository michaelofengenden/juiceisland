import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Motion round C under Motion: Refined, each held against Original: the soft 8 pt edge the opened island's content
/// fades into (F6), the pill's glyph and count riding the wings (F7) and the continuous bottom corners (F9), drawn
/// headless (`ImageRenderer`) from the island's own root, and Show all and the usage strip played through the
/// choreography (E6).
@MainActor
@Suite(.serialized)
struct MotionRoundCTests {
    typealias Model = IslandChoreography

    static let refined = MotionTuning(motion: .refined, hover: .quick)

    /// The prototype's sessions in Clean, Section placement, Pixel, the island's own layout measured.
    static func environment() -> (AppEnvironment, ContentLayout, PillContent) {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .clean
        settings.islandUsagePlacement = .section
        settings.glyphStyle = .pixel
        let env = AppEnvironment.demo(settings: settings, sessions: .prototype)
        let notch = IslandTheme.Metrics.referenceNotch
        let pill = PillContent.make(rows: env.sessions.rows, settings: settings, glance: false, recentlyFinished: nil,
                                    now: env.sessions.now, notch: notch, menuBar: IslandTheme.Metrics.referenceMenuBar)
        return (env, DMotionRenders.measure(env: env, notch: notch, card: nil), pill)
    }

    /// The island's root drawn at rest in `surface` under `tuning`, with the outline then set to `geometry` (the content
    /// where the rest has it), on a mid grey, as RGBA at 2×.
    static func draw(_ tuning: MotionTuning, surface: Model.Surface, geometry: ((SurfaceGeometry) -> SurfaceGeometry)? = nil,
                     env: AppEnvironment, layout: ContentLayout, pill: PillContent) throws -> Bitmap {
        let notch = IslandTheme.Metrics.referenceNotch
        let model = Model(metrics: .init(targets: SurfaceTargets(notch: notch, pill: pill), layout: layout, tuning: tuning), surface: surface)
        let ui = IslandUIState()
        IslandMotionDirector.snap(ui, to: model, at: 0)
        ui.presentation = model.presentation
        ui.islandLive = false
        ui.pillLive = false
        if let geometry {
            let g = geometry(model.restGeometry)
            ui.apply([.left: g.left, .right: g.right, .height: g.height, .ear: g.ear, .radius: g.radius])
        }
        let size = Bitmap.size
        let view = IslandRootView(ui: ui, notch: notch, canvas: size, actions: IslandViewActions(), pillClicked: {}, measured: { _ in })
            .frame(width: size.width, height: size.height)
            .background(Color(white: 0.5))
            .environment(env)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        if let dir = ProcessInfo.processInfo.environment["JI_DEBUG_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("rc-\(tuning.motion)-\(surface)-\(Int(Date().timeIntervalSince1970 * 1000) % 100000).png")
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
        return try Bitmap(image)
    }

    /// RGBA pixels at 2×, read by point.
    struct Bitmap {
        static let size = CGSize(width: IslandPanelSizing.canvasWidth, height: 380)
        let width: Int, height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            self.bytes = bytes
        }

        /// The brightness (the three channels summed) of the device pixel at `(x, y)`, in pixels from the top-left.
        func value(_ x: Int, _ y: Int) -> Int {
            let i = (y * width + x) * 4
            return Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])
        }

        /// The device pixels of the points `xs` × `ys`, cut to the bitmap.
        func pixels(_ xs: ClosedRange<CGFloat>, _ ys: ClosedRange<CGFloat>) -> (x: Range<Int>, y: Range<Int>) {
            let x0 = max(0, Int(xs.lowerBound * 2)), x1 = min(width, max(x0, Int(xs.upperBound * 2)))
            let y0 = max(0, Int(ys.lowerBound * 2)), y1 = min(height, max(y0, Int(ys.upperBound * 2)))
            return (x0..<x1, y0..<y1)
        }

        /// The summed brightness of the pixels in the points `xs` × `ys`.
        func sum(x xs: ClosedRange<CGFloat>, y ys: ClosedRange<CGFloat>) -> Int {
            let (px, py) = pixels(xs, ys)
            var total = 0
            for y in py { for x in px { total += value(x, y) } }
            return total
        }

        /// Whether the points `xs` × `ys` are the same in `other`.
        func same(_ other: Bitmap, x xs: ClosedRange<CGFloat>, y ys: ClosedRange<CGFloat>, within: Int = 3) -> Bool {
            let (px, py) = pixels(xs, ys)
            for y in py {
                for x in px where abs(value(x, y) - other.value(x, y)) > within { return false }
            }
            return true
        }
    }

    // MARK: F6: the soft edge

    /// The bottom edge through the middle of a row: Refined's content fades into the edge, over 8 pt, where Original's is
    /// cut at full brightness; 8 pt and more above the edge the two are the same pixels, and so is everything outside the
    /// black (the black is exactly the outline in both: never faded, never grown). The top never fades.
    @Test func theContentFadesIntoTheBottomEdgeAndTheBlackStaysHard() throws {
        let (env, layout, pill) = Self.environment()
        let row = try #require(layout.listParts.compactMap { part -> CGRect? in
            if case .row = part { layout.parts[part] } else { nil }
        }.first)
        // Through the row's title line.
        let cut = (row.minY + 14).rounded()
        func draw(_ tuning: MotionTuning) throws -> Bitmap {
            try Self.draw(tuning, surface: .island, geometry: { var g = $0; g.height = cut; return g }, env: env, layout: layout, pill: pill)
        }
        let original = try draw(MotionTuning()), refined = try draw(Self.refined)
        let middle = IslandPanelSizing.canvasWidth / 2
        // The content's columns, well inside the walls and clear of the corners.
        let columns = (middle - 200)...(middle + 200)
        let edge = original.sum(x: columns, y: (cut - 1.5)...cut), soft = refined.sum(x: columns, y: (cut - 1.5)...cut)
        let above = original.sum(x: columns, y: (cut - 16)...(cut - 8)), aboveRefined = refined.sum(x: columns, y: (cut - 16)...(cut - 8))
        print("the row's last 1.5 pt at the edge: Original \(edge), Refined \(soft); 8 to 16 pt above it \(above) and \(aboveRefined)")
        #expect(edge > 2000 && Double(soft) < 0.15 * Double(edge), "the row under the edge: \(soft) against \(edge)")
        #expect(original.same(refined, x: columns, y: 0...(cut - 8)), "above the fade")
        // Below the edge: the grey, the same in both (the black never reaches past the outline).
        #expect(original.same(refined, x: columns, y: (cut + 1)...(cut + 20), within: 0))
        #expect(refined.value(Int(middle * 2), Int((cut + 2) * 2)) == original.value(Int(middle * 2), Int((cut + 2) * 2)))
    }

    /// The live island's list sits in its scroll view (E6), an AppKit view: the soft edge fades it there too. The bottom
    /// edge through the second row's title, drawn by AppKit (`cacheDisplay`): Refined's last 1.5 pt are nearly dark where
    /// Original's show the row, and the row above, 10 pt and more above the edge, is the same in both.
    @Test func theSoftEdgeFadesTheListInItsScrollView() throws {
        var edge: [Double] = [], above: [Double] = []
        for tuning in [MotionTuning(), Self.refined] {
            let island = LiveIslandHarness(presenting: nil, tuning: tuning, maxHeight: 900)
            defer { island.close() }
            let layout = island.director.model.layout
            let row = try #require(layout.listParts.compactMap { part -> CGRect? in
                if case .row = part { layout.parts[part] } else { nil }
            }.dropFirst().first)
            let cut = (row.minY + 14).rounded()
            withTransaction(Transaction()) { island.ui.apply([.height: Double(cut)]) }
            for _ in 0..<3 {
                island.hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            edge.append(try island.brightness(from: cut - 1.5, to: cut))
            above.append(try island.brightness(from: cut - 44, to: cut - 10))
        }
        print("the list in its scroll view, its last 1.5 pt at the edge: Original \(edge[0]), Refined \(edge[1]); the row above \(above)")
        #expect(edge[0] > 2000 && edge[1] < 0.15 * edge[0], "\(edge)")
        #expect(above[0] > 2000 && abs(above[0] - above[1]) <= 0.02 * above[0], "\(above)")
    }

    /// The walls through the rows: Refined's content fades into each side over 8 pt where Original's is cut; the black's
    /// wall is the same hard line in both.
    @Test func theContentFadesIntoTheWalls() throws {
        let (env, layout, pill) = Self.environment()
        func draw(_ tuning: MotionTuning) throws -> Bitmap {
            try Self.draw(tuning, surface: .island, geometry: { var g = $0; g.left = 150; g.right = 150; return g },
                          env: env, layout: layout, pill: pill)
        }
        let original = try draw(MotionTuning()), refined = try draw(Self.refined)
        let middle = IslandPanelSizing.canvasWidth / 2, ear = IslandTheme.Metrics.shoulder
        let rows = (layout.header + 4)...(layout.islandHeight(card: nil) - 30)
        for (wall, inward) in [(middle - 150 + ear, CGFloat(1)), (middle + 150 - ear, -1)] {
            let band = inward > 0 ? wall...(wall + 1.5) : (wall - 1.5)...wall
            let edge = original.sum(x: band, y: rows), soft = refined.sum(x: band, y: rows)
            print("the rows' 1.5 pt at the \(inward > 0 ? "left" : "right") wall: Original \(edge), Refined \(soft)")
            #expect(edge > 500 && Double(soft) < 0.15 * Double(edge), "\(soft) against \(edge)")
            // Outside the wall, the grey in both.
            let outside = inward > 0 ? (wall - 12)...(wall - 9) : (wall + 9)...(wall + 12)
            #expect(original.same(refined, x: outside, y: rows, within: 0))
        }
        // Between the fades the content is the same.
        #expect(original.same(refined, x: (middle - 150 + ear + 8)...(middle + 150 - ear - 8), y: rows))
    }

    /// The closed pill keeps its hard edge (its glyph and edge line live in its lowest points) and the island at rest
    /// shows every pixel Original shows but for the corners: the fade lies in the padding.
    @Test func atRestTheSoftEdgeTouchesNothing() throws {
        let (env, layout, pill) = Self.environment()
        for surface in [Model.Surface.closed, .island] {
            let original = try Self.draw(MotionTuning(), surface: surface, env: env, layout: layout, pill: pill)
            let refined = try Self.draw(Self.refined, surface: surface, env: env, layout: layout, pill: pill)
            let g = Model(metrics: .init(targets: SurfaceTargets(notch: IslandTheme.Metrics.referenceNotch, pill: pill), layout: layout),
                          surface: surface).restGeometry
            let middle = IslandPanelSizing.canvasWidth / 2
            // Clear of the bottom corners, which F9 rounds another way.
            let reach = ContinuousCorner.reach * g.radius + 2
            #expect(original.same(refined, x: (middle - g.left + g.ear + reach)...(middle + g.right - g.ear - reach), y: 0...(g.height + 10)),
                    "\(surface)")
            #expect(original.same(refined, x: (middle - g.left - 10)...(middle + g.right + 10), y: 0...(g.height - reach)), "\(surface)")
        }
    }

    /// The fade's own curve: nothing at the edge, half 4 pt in, all 8 pt in, and it never goes back.
    @Test func theFadeIsEasedOverEightPoints() {
        let depth = IslandMotion.softEdge
        #expect(SoftEdgeMask.alpha(inside: 0, depth: depth) == 0 && SoftEdgeMask.alpha(inside: 4, depth: depth) == 0.5)
        #expect(SoftEdgeMask.alpha(inside: 8, depth: depth) == 1 && SoftEdgeMask.alpha(inside: 20, depth: depth) == 1)
        let samples = stride(from: -2.0, through: 10, by: 0.25).map { SoftEdgeMask.alpha(inside: CGFloat($0), depth: depth) }
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(SoftEdgeMask.alpha(inside: 3, depth: 0) == 1 && MotionTuning().softEdge == 0 && Self.refined.softEdge == 8)
    }

    // MARK: F7: the pill rides the wings

    /// The outline 30 pt wider than the pill on the left and 20 on the right: Refined's glyph and count move out by as
    /// much, each keeping its place against its own side; Original's stay where the pill has them. At rest, and with
    /// the outline narrower than the pill, both stay.
    @Test func thePillsGlyphAndCountRideTheWings() throws {
        let (env, layout, pill) = Self.environment()
        func extent(_ bitmap: Bitmap) -> (glyph: CGFloat, count: CGFloat) {
            // The lead's needs-you pink, the default (red high, green low), leftmost, and the count's white rightmost, in the
            // pill's band.
            var glyph = CGFloat.infinity, count = -CGFloat.infinity
            for y in 4..<60 {
                for x in 0..<bitmap.width {
                    let i = (y * bitmap.width + x) * 4
                    let (r, g, b) = (Int(bitmap.bytes[i]), Int(bitmap.bytes[i + 1]), Int(bitmap.bytes[i + 2]))
                    if r > 160, g < 130, r - g > 80 { glyph = min(glyph, CGFloat(x) / 2) }
                    if r > 200, g > 200, b > 200 { count = max(count, CGFloat(x) / 2) }
                }
            }
            return (glyph, count)
        }
        func draw(_ tuning: MotionTuning, _ dl: CGFloat, _ dr: CGFloat) throws -> (glyph: CGFloat, count: CGFloat) {
            extent(try Self.draw(tuning, surface: .closed, geometry: { var g = $0; g.left += dl; g.right += dr; return g },
                                 env: env, layout: layout, pill: pill))
        }
        let rest = try draw(MotionTuning(), 0, 0)
        let original = try draw(MotionTuning(), 30, 20), refined = try draw(Self.refined, 30, 20)
        let narrower = try draw(Self.refined, -4, -4), refinedRest = try draw(Self.refined, 0, 0)
        print("glyph and count: at rest \(rest); wider, Original \(original), Refined \(refined); narrower \(narrower)")
        #expect(rest.glyph.isFinite && rest.count.isFinite)
        #expect(original == rest && refinedRest == rest && narrower == rest)
        #expect(abs(refined.glyph - (rest.glyph - 30)) <= 0.5 && abs(refined.count - (rest.count + 20)) <= 0.5, "\(refined)")
    }

    /// The ride is a geometry effect: nothing past the pill's own reach, the reach's excess beyond it, each way.
    @Test func theRideIsTheReachPastThePill() {
        func dx(_ effect: RideOffset) -> CGFloat { effect.effectValue(size: .zero).m31 }
        #expect(dx(RideOffset(reach: 150, rest: 120, side: -1)) == -30 && dx(RideOffset(reach: 150, rest: 120, side: 1)) == 30)
        #expect(dx(RideOffset(reach: 100, rest: 120, side: -1)) == 0 && dx(RideOffset(reach: 120, rest: 120, side: 1)) == 0)
    }

    // MARK: F9: continuous corners

    /// Refined's bottom corners are of continuous curvature in both outlines: SwiftUI's shape and Core Animation's path
    /// cover the same points, each corner leaves its wall along the wall (no jump in curvature: its first two controls on
    /// the wall's line) and passes within 0.01 r of the circle of the same radius at the diagonal. Core Animation's path
    /// has the same elements for every geometry (it interpolates only between those), zero ears and radii included.
    @Test func refinedsCornersAreContinuousInBothOutlines() throws {
        let geometries = [SurfaceGeometry(width: 480, height: 228, ear: 8, radius: 20), SurfaceGeometry(left: 120, right: 90, height: 33, ear: 3, radius: 12.5),
                          SurfaceGeometry(width: 200, height: 32, ear: 0, radius: 12), SurfaceGeometry(width: 300, height: 24, ear: 0, radius: 12),
                          SurfaceGeometry(width: 340, height: 120, ear: 5.5, radius: 16), SurfaceGeometry(width: 40, height: 10, ear: 2, radius: 12),
                          SurfaceGeometry(width: 300, height: 0, ear: 0, radius: 0)]
        var counts: Set<Int> = []
        for g in geometries {
            let ca = IslandSurfaceLayers.fixedPath(g, originX: 0, top: 0, flipHeight: nil, continuous: true)
            var elements = 0
            ca.applyWithBlock { _ in elements += 1 }
            counts.insert(elements)
            guard g.height > 0 else { continue }
            let swiftUI = NotchSurfaceShape.path(g, originX: 0, top: 0, continuous: true).cgPath
            // The same shape: every point of a quarter-point grid is in both or in neither, but on the very edge.
            var differ = 0
            for y in stride(from: 0.125, to: g.height, by: 0.25) {
                for x in stride(from: 0.125, to: g.width, by: 0.25) {
                    let p = CGPoint(x: x, y: y)
                    guard swiftUI.contains(p) != ca.contains(p) else { continue }
                    let near = [CGPoint(x: 0.05, y: 0), CGPoint(x: -0.05, y: 0), CGPoint(x: 0, y: 0.05), CGPoint(x: 0, y: -0.05)]
                        .contains { swiftUI.contains(CGPoint(x: x + $0.x, y: y + $0.y)) != swiftUI.contains(p) }
                    if !near { differ += 1 }
                }
            }
            #expect(differ == 0, "\(g): \(differ) points differ")
        }
        #expect(counts.count == 1, "\(counts)")
        // The corner at its diagonal, and along its wall.
        let r: CGFloat = 20
        let curves = ContinuousCorner.curves(corner: CGPoint(x: 100, y: 100), into: CGVector(dx: 0, dy: 1), out: CGVector(dx: -1, dy: 0), radius: r)
        #expect(curves[0].c1.x == 100 && curves[0].c2.x == 100, "the first cubic's controls on the wall")
        let a = curves[1]
        let start = curves[0].to
        let mid = CGPoint(x: (start.x + 3 * a.c1.x + 3 * a.c2.x + a.to.x) / 8, y: (start.y + 3 * a.c1.y + 3 * a.c2.y + a.to.y) / 8)
        let circle = CGPoint(x: 100 - r + r / 2.squareRoot(), y: 100 - r + r / 2.squareRoot())
        #expect(abs(mid.x - circle.x) < 0.01 * r && abs(mid.y - circle.y) < 0.01 * r, "\(mid) against \(circle)")
        // Original keeps its arcs.
        #expect(!MotionTuning().continuousCorners && Self.refined.continuousCorners)
    }

    // MARK: E6: Show all and the usage strip through the choreography

    /// `rows` rows of 40 pt under the header, the usage block of `usage` points above them, the footer under them.
    static func list(rows: Int, footer: Bool, usage: CGFloat? = nil) -> ContentLayout {
        var layout = ContentLayout()
        var y = layout.header
        if let usage {
            layout.parts[.usage] = CGRect(x: 0, y: y, width: 460, height: usage)
            y += usage
        }
        for i in 0..<rows {
            layout.parts[.row("r\(i)")] = CGRect(x: 0, y: y, width: 460, height: 40)
            y += 40
        }
        if footer {
            layout.parts[.footer] = CGRect(x: 0, y: y, width: 460, height: 24)
            y += 24
        }
        layout.list = y - layout.header
        return layout
    }

    /// Open and at rest on `layout`.
    static func open(_ layout: ContentLayout, tuning: MotionTuning = refined, reduceMotion: Bool = false) -> Model {
        Model(metrics: .init(targets: SurfaceTargets(notch: IslandTheme.Metrics.referenceNotch, pill: .empty), layout: layout,
                             reduceMotion: reduceMotion, tuning: tuning), surface: .island)
    }

    /// Whether `commands` snap `part`'s focus (a forget or a snap: cut in one frame).
    static func snaps(_ part: PartID, _ commands: [Model.Command]) -> Bool {
        commands.contains { if case let .animate(nil, values) = $0 { values[.part(part)] != nil } else { false } }
    }

    /// When a part fading out from 1 at `start` on `curve` is down to `focus` (out of sight: `shown`), in the model's
    /// 1 ms steps.
    static func fadedOut(from start: TimeInterval, to focus: Double = IslandMotion.shown,
                         curve: IslandMotion.Curve = IslandMotion.focusOut) -> TimeInterval {
        let fade = ShadowValue(from: 1, velocity: 0, target: 0, start: start, curve: curve)
        var s = start
        while fade.value(at: s) > focus { s += 0.001 }
        return s
    }

    /// Show all (D3): the footer fades out first, never cut; the change is written once it is down to a tenth, on the
    /// curve the edge then unfolds on, from the moment its rows are measured; the new rows come in once the footer is
    /// out of sight.
    @Test func showAllFadesTheFooterThenGrowsOnTheEdgesCurve() {
        for tuning in [MotionTuning(), Self.refined] {
            var model = Self.open(Self.list(rows: 4, footer: true), tuning: tuning)
            let t0 = 1.0
            #expect(model.handle(.list(.showAll), at: t0) == [.animate(IslandMotion.focusOut, [.part(.footer): 0])])
            let swap = Self.fadedOut(from: t0, to: IslandMotion.swapFocus)
            #expect(abs(swap - t0 - 0.099) < 0.002)
            #expect(model.advance(to: swap - 0.0005).isEmpty)
            #expect(model.advance(to: swap) == [.effect(.list(.showAll, IslandMotion.unfold))])
            let t1 = swap + 0.004
            let content = model.handle(.content(Self.list(rows: 6, footer: false)), at: t1)
            #expect(!Self.snaps(.footer, content), "the footer, already fading, is never cut")
            let height = model.values[.height]
            #expect(height?.curve == IslandMotion.unfold && height?.start == t1 && height?.target == Double(model.restGeometry.height))
            let reveals = model.jobs.compactMap { job -> TimeInterval? in
                if case let .reveal(.row(id)) = job.step, id == "r4" || id == "r5" { job.time } else { nil }
            }
            #expect(reveals.count == 2 && reveals.allSatisfy { $0 >= Self.fadedOut(from: t0) - 1e-9 }, "\(reveals)")
        }
    }

    /// The strip clicked open (D2): written at once on the unfold, the edge following on the same curve; the block
    /// comes in once the rows it pushes down have cleared all but the edge's depth of it, not under them.
    @Test func theStripOpensWithTheRowsAndTheEdgeOnOneCurve() {
        var model = Self.open(Self.list(rows: 4, footer: true))
        let t0 = 1.0
        #expect(model.handle(.list(.strip(true)), at: t0) == [.effect(.list(.strip(true), IslandMotion.unfold))])
        let t1 = t0 + 0.004
        _ = model.handle(.content(Self.list(rows: 4, footer: true, usage: 90)), at: t1)
        #expect(model.values[.height]?.curve == IslandMotion.unfold && model.values[.height]?.start == t1)
        let rows = ShadowValue(from: 0, velocity: 0, target: 1, start: t0, curve: IslandMotion.unfold)
        var cleared = t0
        while rows.value(at: cleared) < Double(1 - IslandMotion.edgeDepth) { cleared += 0.001 }
        let reveal = model.jobs.first { $0.step == .reveal(.usage) }?.time
        #expect(reveal.map { abs($0 - cleared) <= 0.0015 } == true, "\(String(describing: reveal)) against \(cleared)")
    }

    /// The strip folded (D2): the block fades out first (it used to vanish in one frame), then the rows move up on the
    /// fold and the edge folds with them at once, not `shrinkLag` after its measurement.
    @Test func theStripFoldsTheBlockOutThenTheRowsAndTheEdgeTogether() {
        var model = Self.open(Self.list(rows: 4, footer: true, usage: 90))
        let t0 = 1.0
        #expect(model.handle(.list(.strip(false)), at: t0) == [.animate(IslandMotion.focusOut, [.part(.usage): 0])])
        #expect(model.stripAfterSwap == false)
        let swap = Self.fadedOut(from: t0, to: IslandMotion.swapFocus)
        #expect(model.advance(to: swap) == [.effect(.list(.strip(false), IslandMotion.fold))])
        let t1 = swap + 0.004
        let content = model.handle(.content(Self.list(rows: 4, footer: true)), at: t1)
        #expect(!Self.snaps(.usage, content))
        let height = model.values[.height]
        #expect(height?.curve == IslandMotion.fold && height?.start == t1 && height?.target == Double(model.restGeometry.height))
        #expect(!model.jobs.contains { $0.step == .contentHeight })
    }

    /// Clicked back before the fold is written: the block comes back into focus where it is, and nothing changes.
    @Test func aStripClickedBackBeforeItFoldsBringsTheBlockBack() {
        var model = Self.open(Self.list(rows: 4, footer: true, usage: 90))
        _ = model.handle(.list(.strip(false)), at: 1)
        #expect(model.handle(.list(.strip(false)), at: 1.01).isEmpty, "the same change twice is one")
        #expect(model.handle(.list(.strip(true)), at: 1.03) == [.animate(Self.refined.focusIn, [.part(.usage): 1])])
        #expect(model.stripAfterSwap == nil)
        #expect(!model.advance(to: 2).contains { if case .effect(.list) = $0 { true } else { false } })
    }

    /// A row the feed lets go while the island is open fades out as its view leaves, and is forgotten once out of sight
    /// (it used to be cut in one frame, P101's forget); closed, it is forgotten at once.
    @Test func aPartThatGoesWhileItShowsFadesInsteadOfBeingCut() {
        var model = Self.open(Self.list(rows: 4, footer: true))
        let out = model.handle(.content(Self.list(rows: 3, footer: true)), at: 1)
        #expect(out.contains(.animate(IslandMotion.focusOut, [.part(.row("r3")): 0])) && !Self.snaps(.row("r3"), out))
        let later = model.handle(.content(Self.list(rows: 3, footer: false)), at: 2)
        #expect(later.contains(.animate(nil, [.part(.row("r3")): 0])) && model.values[.part(.row("r3"))] == nil)
        #expect(later.contains(.animate(IslandMotion.focusOut, [.part(.footer): 0])))
        var closed = Model(metrics: .init(targets: SurfaceTargets(notch: IslandTheme.Metrics.referenceNotch, pill: .empty),
                                          layout: Self.list(rows: 4, footer: true), tuning: Self.refined), surface: .closed)
        _ = closed.handle(.content(Self.list(rows: 3, footer: true)), at: 1)
        #expect(closed.values[.part(.row("r3"))] == nil)
    }

    /// Under Reduce Motion the footer fades on the reduced curve, the change is written with no curve once it has, and
    /// the height snaps with it.
    @Test func underReduceMotionAListChangeFadesThenSnaps() {
        var model = Self.open(Self.list(rows: 4, footer: true), reduceMotion: true)
        #expect(model.handle(.list(.showAll), at: 1) == [.animate(IslandMotion.reduced, [.part(.footer): 0])])
        let swap = Self.fadedOut(from: 1, to: IslandMotion.swapFocus, curve: IslandMotion.reduced)
        #expect(model.advance(to: swap) == [.effect(.list(.showAll, nil))])
        _ = model.handle(.content(Self.list(rows: 6, footer: false)), at: swap + 0.004)
        #expect(model.jobs.contains { $0.step == .reducedHeight && abs($0.time - swap - 0.004) < 1e-9 })
    }

    /// The director writes a list change in its own transaction, on its curve, between the batch's others.
    @Test func theDirectorWritesAListChangeOnItsOwnCurve() {
        let before = Model.Command.animate(IslandMotion.focusOut, [.part(.footer): 0])
        let after = Model.Command.animate(nil, [.part(.row("r9")): 0])
        let change = Model.Command.effect(.list(.strip(true), IslandMotion.unfold))
        #expect(IslandMotionDirector.transactions([before, change, after])
            == [.writes([before]), .list(.strip(true), IslandMotion.unfold), .writes([after])])
        let ui = IslandUIState()
        IslandMotionDirector.write(change, to: ui)
        IslandMotionDirector.write(.effect(.list(.showAll, nil)), to: ui)
        #expect(ui.stripOpen && ui.showAll)
    }

    /// Show all in the live island (the list in its scroll view, as the panel has it) adds its rows to the views already
    /// there: no row that showed reports from a new view (the list used to move into a scroll view, every row built
    /// again), the footer goes and the new rows arrive.
    @Test func showAllRebuildsNoRow() {
        var seen: [PartID: Set<Int>] = [:], rebuilt: Set<PartID> = []
        var watching = false
        let island = LiveIslandHarness(presenting: nil, tuning: Self.refined, maxHeight: 900) { measure in
            guard case let .part(part, _?, owner) = measure else { return }
            if watching, let known = seen[part], !known.contains(owner) { rebuilt.insert(part) }
            seen[part, default: []].insert(owner)
        }
        let rows: (ContentLayout) -> [PartID] = { $0.parts.keys.filter { if case .row = $0 { true } else { false } } }
        let before = rows(island.director.model.layout)
        #expect(before.count == IslandTheme.Metrics.visibleRows && island.director.model.layout.parts[.footer] != nil)
        watching = true
        island.director.send(.list(.showAll))
        island.settle(0.8)
        let after = island.director.model.layout
        #expect(island.ui.showAll && after.parts[.footer] == nil && Set(before).isSubset(of: Set(rows(after))))
        #expect(rows(after).count > before.count)
        #expect(rebuilt.isEmpty, "rebuilt: \(rebuilt)")
    }

    /// Live, in real time, under both feels: the footer Show all takes and the usage block the strip folds fade out,
    /// never cut in one frame (D3: the footer popped; D2: the block vanished in one frame). A band over each, read at
    /// every turn: no reading while it still shows (over a third of its brightest) is followed a frame or two later
    /// (50 ms) by one under a tenth of it, and something of each fade's middle is read on its way out. A turn the main
    /// actor made late (every suite shares it) can pass over a fade's middle: that run is played again, up to three
    /// times, so load only makes the test longer (P293); a cut never shows a middle, so it fails every time.
    @Test func nothingPopsOutInShowAllOrTheStripsFold() throws {
        for tuning in [MotionTuning(), Self.refined] {
            for attempt in 1...3 {
                let settings = AppSettings.ephemeral()
                settings.islandUsagePlacement = .headerStrip
                let island = LiveIslandHarness(env: .demo(settings: settings), presenting: nil, tuning: tuning, maxHeight: 900)
                defer { island.close() }
                func fade(_ part: PartID, _ change: Model.ListChange) throws -> LiveFade {
                    let rect = try #require(island.director.model.layout.parts[part])
                    var fade = LiveFade()
                    island.director.send(.list(change))
                    try island.play(for: 0.4) { t in
                        fade.readings.append((t, try island.brightness(from: rect.minY - 8, to: rect.maxY + 2)))
                    }
                    return fade
                }
                let footer = try fade(.footer, .showAll)
                island.director.send(.list(.strip(true)))
                try island.play(for: 0.8)
                let block = try fade(.usage, .strip(false))
                print("\(tuning.motion), run \(attempt): the footer \(footer), the block \(block)")
                guard (footer.middleRead && block.middleRead) || attempt == 3 else { continue }
                for part in [footer, block] {
                    #expect((part.readings.first?.value ?? 0) > 1000 && part.middleRead && !part.cut, "\(tuning.motion)")
                }
                #expect(island.ui.showAll && !island.ui.stripOpen)
                break
            }
        }
    }

    /// A band's brightness at each turn of a live fade, with the time it was read.
    struct LiveFade: CustomStringConvertible {
        var readings: [(t: TimeInterval, value: Double)] = []
        var peak: Double { readings.map(\.value).max() ?? 0 }
        /// A reading over a third of the brightest followed, a frame or two later, by one under a tenth of it.
        var cut: Bool {
            zip(readings, readings.dropFirst()).contains { $0.value > peak / 3 && $1.value < $0.value / 10 && $1.t - $0.t <= 0.05 }
        }
        /// On its way out (before it first reads under a tenth of where it started), something between that and 90 %.
        var middleRead: Bool {
            guard let first = readings.first?.value else { return false }
            return readings.dropFirst().prefix { $0.value >= first / 10 }.contains { $0.value < first * 0.9 }
        }
        var description: String { "\(readings.map { Int($0.value / 1000) })" }
    }

    /// A part two views hold for an update (the opened island rebuilt when Motion changes) goes only when both have
    /// gone, whichever order they report in: the old view's frame after the new one's, then its going (P307: the
    /// island once lost every part this way, and its rows never came in again).
    @Test func aPartGoesOnlyWhenTheLastViewHoldingItGoes() {
        let model = Self.open(Self.list(rows: 1, footer: false))
        let director = IslandMotionDirector(model: model, ui: IslandUIState(), clock: FakeJobClock(now: 10))
        let old = CGRect(x: 0, y: 34, width: 460, height: 40), new = CGRect(x: 0, y: 34, width: 460, height: 41)
        for measure in [IslandMeasure.part(.row("a"), new, owner: 2), .part(.row("a"), old, owner: 1), .part(.row("a"), nil, owner: 1)] {
            director.measured(measure)
        }
        director.flushMeasurements()
        #expect(director.model.layout.parts[.row("a")] == new)
        director.measured(.part(.row("a"), nil, owner: 2))
        director.flushMeasurements()
        #expect(director.model.layout.parts[.row("a")] == nil)
    }
}
