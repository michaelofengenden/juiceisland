import AppKit
import CoreGraphics
import Foundation
import Metal
import QuartzCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Motion: Liquid's frame strips, every 1/60 s of model time (the build spec §8.3): the model's union drawn by
/// CoreGraphics (the outline alone), the island itself in Black, Smoke and Glass through `CARenderer` (a borrowed layer
/// tree in a borderless window that is never ordered in: the system glass renders for real, nothing is read from the
/// screen), zooms of the neck, and Core Animation's own keyframes against the model's union. Written to `$JI_LIQUID_OUT`;
/// skipped unless it is set.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["JI_LIQUID_OUT"] != nil))
struct LiquidRenders {
    typealias Model = IslandChoreography
    typealias Events = [(TimeInterval, Model.Event)]

    static let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JI_LIQUID_OUT"] ?? NSTemporaryDirectory() + "liquid")
    nonisolated static let liquid = MotionTuning(motion: .liquid, hover: .quick)
    nonisolated static let refined = MotionTuning(motion: .refined, hover: .quick)
    static let dt = 1.0 / 60

    struct Motion {
        var name: String
        var surface: Model.Surface = .closed
        var events: Events
        var from: TimeInterval = 0
        var to: TimeInterval
        var zero: TimeInterval = 0
        var notch: CGSize? = IslandTheme.Metrics.referenceNotch
        var reduceMotion = false
        /// What the island presents at the start, and its content (nil: the reference list).
        var presentation: IslandPresentation = .list
        var layout: ContentLayout? = nil
        /// The card it buds (L2): the prototype's card, measured (`cardLayout`), taller frames.
        var cardID: String? = nil
    }

    /// The prototype's card the bud's strips present.
    static let cardID = FixtureSessionFeed.ID.approval

    /// The card's bud (L2): list → card, card → list, the list back 140 ms into the bud, a close with the bud out, an
    /// open to a card.
    static var budMotions: [Motion] {
        let card: Model.Event = .present(.card(sessionID: cardID)), list: Model.Event = .present(.list)
        return [Motion(name: "bud", surface: .island, events: [(0, card)], to: 1.0, cardID: cardID),
                Motion(name: "merge", surface: .island, events: [(0, list)], to: 1.0, presentation: .card(sessionID: cardID), cardID: cardID),
                Motion(name: "budflip", surface: .island, events: [(0, card), (0.14, list)], to: 1.1, cardID: cardID),
                Motion(name: "closebud", surface: .island, events: [(0, .close(.fold))], to: 0.9, presentation: .card(sessionID: cardID),
                       cardID: cardID),
                Motion(name: "opencard", events: [(0, .open(.attention, .card(sessionID: cardID)))], to: 1.1, cardID: cardID)]
    }

    /// The prototype's list with its card measured (the bud's strips).
    static let cardLayout: ContentLayout = DMotionRenders.measure(env: scene().env, notch: IslandTheme.Metrics.referenceNotch, card: cardID)

    static var motions: [Motion] {
        let all = [
            Motion(name: "open", events: [(0, .open(.hover, .list))], to: 0.6),
            Motion(name: "close", surface: .island, events: [(0, .close(.fold))], to: 0.72),
            Motion(name: "hover", events: [(0, .swell(true)), (0.4, .swell(false))], to: 0.75),
            Motion(name: "reverse", surface: .island, events: [(0, .close(.fold)), (0.13, .open(.hover, .list))], to: 0.75),
            Motion(name: "reopen", events: [(0, .open(.hover, .list)), (0.13, .close(.fold))], to: 0.8),
            Motion(name: "topbar-open", events: [(0, .open(.hover, .list))], to: 0.6, notch: nil),
            Motion(name: "topbar-close", surface: .island, events: [(0, .close(.fold))], to: 0.6, notch: nil),
            Motion(name: "reduce-open", events: [(0, .open(.hover, .list))], to: 0.45, reduceMotion: true),
        ]
        guard let only = ProcessInfo.processInfo.environment["JI_LIQUID_ONLY"] else { return all + budMotions }
        return (all + budMotions).filter { only.split(separator: ",").contains(Substring($0.name)) }
    }

    static func pill(notch: CGSize?) -> PillContent {
        notch == nil ? CoreAnimationOutlineTests.bar : DIslandMotionTests.referencePill
    }

    static func model(_ motion: Motion, tuning: MotionTuning = liquid, layout: ContentLayout? = nil, until t: TimeInterval) -> Model {
        let start = Model(metrics: .init(targets: SurfaceTargets(notch: motion.notch, pill: pill(notch: motion.notch)),
                                         layout: layout ?? motion.layout ?? (motion.cardID != nil ? cardLayout : DIslandMotionTests.layout()),
                                         reduceMotion: motion.reduceMotion, tuning: tuning),
                          surface: motion.surface, presentation: motion.presentation)
        return Model.replay(start, motion.events, until: t).model
    }

    // MARK: The outline alone

    /// The union at every 1/60 s of each motion, black on grey, the closed pill's outline in red and the panel in blue:
    /// `outline-<motion>.png`.
    @Test func outlines() throws {
        for motion in Self.motions {
            var frames: [(String, CGImage)] = []
            var t = motion.from
            while t <= motion.to + 1e-9 {
                let m = Self.model(motion, until: t)
                frames.append(("\(Int(((t - motion.zero) * 1000).rounded()))", Self.silhouette(m, at: t, crop: motion.cardID != nil ? Self.budCrop : Self.crop)))
                t += Self.dt
            }
            try Self.write(Self.sheet(frames, columns: 8), "outline-\(motion.name)")
        }
    }

    /// Zoomed outlines of a motion's frames (`JI_LIQUID_ZOOM=<motion>:<from ms>:<to ms>[:<top pt>[:<step ms>]]`, 3x around
    /// the centre line from `top`, every `step`; several separated by `,`).
    @Test func zoomedOutlines() throws {
        guard let specs = ProcessInfo.processInfo.environment["JI_LIQUID_ZOOM"] else { return }
        for spec in specs.split(separator: ",") {
            let parts = spec.split(separator: ":")
            guard parts.count >= 3, let motion = Self.motions.first(where: { $0.name == parts[0] }), let a = Double(parts[1]), let b = Double(parts[2])
            else { continue }
            let top = parts.count > 3 ? Double(parts[3]) ?? 0 : 0, step = parts.count > 4 ? (Double(parts[4]) ?? 1000 * Self.dt) / 1000 : Self.dt
            var frames: [(String, CGImage)] = []
            var t = a / 1000
            while t <= b / 1000 + 1e-9 {
                let m = Self.model(motion, until: t)
                frames.append((String(format: "%.1f", t * 1000), Self.silhouette(m, at: t, scale: 3, crop: CGRect(x: -100, y: top, width: 200, height: 110))))
                t += step
            }
            try Self.write(Self.sheet(frames, columns: 6), "zoom-\(motion.name)-\(parts[1])-\(parts[2])")
        }
    }

    static let crop = CGRect(x: -270, y: 0, width: 540, height: 300)
    /// The bud's strips: the card below the list.
    static let budCrop = CGRect(x: -270, y: 0, width: 540, height: 480)

    /// The model's union at `t` on grey, with the closed pill's outline and the panel.
    static func silhouette(_ m: Model, at t: TimeInterval, scale: CGFloat = 1, crop: CGRect = crop) -> CGImage {
        let w = Int(crop.width * scale), h = Int(crop.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.82, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        let body = m.surface(at: t), params = m.liquid(at: t)
        ctx.addPath(LiquidPath.cgPath(body, params, centreX: 0))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.addPath(IslandSurfaceLayers.fixedPath(m.targets.closed, originX: -m.targets.closed.left, top: 0, flipHeight: nil, continuous: true))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 0.8))
        ctx.setLineWidth(0.5 / scale)
        ctx.strokePath()
        let p = m.panel
        ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 1, alpha: 0.7))
        ctx.stroke(CGRect(x: -p.left, y: 0, width: p.width, height: p.height))
        return ctx.makeImage()!
    }

    // MARK: The island itself

    enum Look: String, CaseIterable {
        /// Black on the busy photo; Glass (the system's own glass, rendered for real) on a white window and on the busy
        /// photo; Smoke on the busy photo; Refined's Black for comparison.
        case black, glass, glassBusy, smokeBusy, refinedBlack

        var theme: JuiceTheme {
            switch self {
            case .black, .refinedBlack: .black
            case .glass, .glassBusy: .glass
            case .smokeBusy: .smoke
            }
        }

        var backdrop: GlassBackdrop { self == .glass ? .white : .busy }
        var tuning: MotionTuning { self == .refinedBlack ? LiquidRenders.refined : LiquidRenders.liquid }
    }

    struct Scene {
        var env: AppEnvironment
        var pill: PillContent
        var bar: PillContent
        var layout: ContentLayout
    }

    static let menuBar = IslandTheme.Metrics.referenceMenuBar
    static let canvas = CGSize(width: IslandPanelSizing.canvasWidth, height: 420)
    static let islandCrop = CGRect(x: (IslandPanelSizing.canvasWidth - 540) / 2, y: 0, width: 540, height: 400)
    static let budCanvas = CGSize(width: IslandPanelSizing.canvasWidth, height: 560)
    static let budIslandCrop = CGRect(x: (IslandPanelSizing.canvasWidth - 540) / 2, y: 0, width: 540, height: 540)

    static func scene() -> Scene {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .clean
        settings.glyphStyle = .pixel
        let env = AppEnvironment.demo(settings: settings, sessions: .prototype)
        let notch = IslandTheme.Metrics.referenceNotch
        let pill = PillContent.make(rows: env.sessions.rows, settings: settings, glance: false, recentlyFinished: nil, now: env.sessions.now,
                                    notch: notch, menuBar: menuBar)
        let bar = PillContent.make(rows: env.sessions.rows, settings: settings, glance: false, recentlyFinished: nil, now: env.sessions.now,
                                   notch: nil, menuBar: 24)
        return Scene(env: env, pill: pill, bar: bar, layout: DMotionRenders.measure(env: env, notch: notch, card: nil))
    }

    /// Every 1/60 s of each motion, the island itself in each look (`JI_LIQUID_LOOKS`), hosted and drawn through
    /// `CARenderer` in a borderless window never ordered in: `island-<motion>-<look>.png`, and each frame at 2x under
    /// `frames/` when `JI_LIQUID_FRAMES` is set.
    @Test func island() throws {
        let scene = Self.scene()
        let looks = ProcessInfo.processInfo.environment["JI_LIQUID_LOOKS"].map { $0.split(separator: ",").compactMap { Look(rawValue: String($0)) } }
            ?? Look.allCases
        let frames = ProcessInfo.processInfo.environment["JI_LIQUID_FRAMES"] != nil
        for motion in Self.motions {
            for look in looks {
                var sheet: [(String, CGImage)] = []
                var t = motion.from
                let budding = motion.cardID != nil
                let canvas = budding ? Self.budCanvas : Self.canvas
                while t <= motion.to + 1e-9 {
                    let pill = motion.notch == nil ? scene.bar : scene.pill
                    let start = Model(metrics: .init(targets: SurfaceTargets(notch: motion.notch, pill: pill), layout: budding ? Self.cardLayout : scene.layout,
                                                     reduceMotion: motion.reduceMotion, tuning: look.tuning),
                                      surface: motion.surface, presentation: motion.presentation)
                    let model = Model.replay(start, motion.events, until: t).model
                    let ui = IslandUIState()
                    IslandMotionDirector.snap(ui, to: model, at: t)
                    ui.presentation = model.presentation
                    if budding { ui.card = model.cardMounted.flatMap { scene.env.sessions.card(for: $0) } }
                    ui.islandLive = false
                    ui.pillLive = false
                    let root = ZStack(alignment: .top) {
                        look.backdrop.view
                        Rectangle().fill(Color.black.opacity(0.12)).frame(height: Self.menuBar)
                        IslandRootView(ui: ui, notch: motion.notch, canvas: canvas, actions: IslandViewActions(), pillClicked: {}, measured: { _ in })
                        if let notch = motion.notch { DScene.hardwareNotch(notch) }
                    }
                    .frame(width: canvas.width, height: canvas.height, alignment: .top)
                    .environment(scene.env)
                    .environment(\.juiceTheme, look.theme)
                    .environment(\.glassRendering, .live)
                    .environment(\.sessionGlyphsAnimated, false)
                    let image = try Self.hostedRender(AnyView(root), size: canvas, crop: budding ? Self.budIslandCrop : Self.islandCrop)
                    let ms = Int(((t - motion.zero) * 1000).rounded())
                    if frames { try Self.write(image, "frames/\(motion.name)-\(look.rawValue)-\(String(format: "%04d", ms))") }
                    sheet.append(("\(ms)", Self.half(image)))
                    t += Self.dt
                }
                try Self.write(Self.sheet(sheet, columns: 8), "island-\(motion.name)-\(look.rawValue)")
            }
        }
    }

    /// An image at half its size (the sheets' frames at 1x).
    static func half(_ image: CGImage) -> CGImage {
        let w = image.width / 2, h = image.height / 2
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    static func hostedRender(_ view: AnyView, size: CGSize, crop: CGRect) throws -> CGImage {
        try autoreleasepool {
            _ = NSApplication.shared
            let hosting = NSHostingView(rootView: view)
            let rect = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            hosting.frame = rect
            for _ in 0..<3 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            hosting.displayIfNeeded()
            defer { window.contentView = nil; window.close() }
            guard let layer = hosting.layer else { throw RenderHarness.RenderError.noImage("layer") }
            return try render(layer, size: size, crop: crop, at: CACurrentMediaTime())
        }
    }

    /// `layer` (borrowed from its tree for the frame) through `CARenderer` at 2x at media time `time`, cropped to `crop`
    /// (points, from the top-left). Prototype C's harness: the system glass renders for real, nothing is read from the
    /// screen.
    static func render(_ layer: CALayer, size: CGSize, crop: CGRect, at time: CFTimeInterval) throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderHarness.RenderError.noImage("metal") }
        let w = Int(size.width * 2), h = Int(size.height * 2)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { throw RenderHarness.RenderError.noImage("texture") }
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: w, height: h)
        let holder = CALayer()
        holder.anchorPoint = .zero
        holder.bounds = CGRect(origin: .zero, size: size)
        holder.position = .zero
        holder.transform = CATransform3DMakeScale(2, 2, 1)
        root.addSublayer(holder)
        let parent = layer.superlayer, index = parent?.sublayers?.firstIndex(of: layer)
        let frame = layer.frame
        holder.addSublayer(layer)
        layer.frame = CGRect(origin: .zero, size: size)
        renderer.layer = root
        renderer.bounds = root.frame
        CATransaction.flush()
        renderer.beginFrame(atTime: time, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        // The GPU finishes on its own time: read until two reads agree (and something was drawn).
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        var previous: [UInt8] = []
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.012)
            texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            if bytes == previous, bytes.contains(where: { $0 != 0 }) { break }
            previous = bytes
        }
        layer.removeFromSuperlayer()
        layer.frame = frame
        if let parent { parent.insertSublayer(layer, at: UInt32(index ?? 0)) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let image = ctx.makeImage() else { throw RenderHarness.RenderError.noImage("image") }
        // The texture's first row is the layer tree's bottom (y up): flip, then crop (top-left points).
        let cw = Int(crop.width * 2), ch = Int(crop.height * 2)
        guard let out = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderHarness.RenderError.noImage("crop") }
        out.translateBy(x: 0, y: CGFloat(ch))
        out.scaleBy(x: 1, y: -1)
        out.draw(image, in: CGRect(x: -crop.minX * 2, y: -crop.minY * 2, width: CGFloat(w), height: CGFloat(h)))
        guard let cropped = out.makeImage() else { throw RenderHarness.RenderError.noImage("cropped") }
        return cropped
    }

    // MARK: Output

    static func write(_ image: CGImage, _ name: String) throws {
        let url = out.appendingPathComponent(name + ".png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Labelled frames in rows of `columns`.
    static func sheet(_ frames: [(String, CGImage)], columns: Int, gap: Int = 6, label: Int = 16) -> CGImage {
        let fw = frames.map(\.1.width).max() ?? 1, fh = frames.map(\.1.height).max() ?? 1
        let cols = min(columns, frames.count), rows = (frames.count + cols - 1) / cols
        let w = cols * fw + (cols + 1) * gap, h = rows * (fh + label) + (rows + 1) * gap
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        for (i, (name, image)) in frames.enumerated() {
            let c = i % cols, r = i / cols
            let x = gap + c * (fw + gap), yTop = gap + r * (fh + label + gap)
            let y = h - yTop - label - fh
            NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(x: x, y: y, width: image.width, height: image.height))
            (name as NSString).draw(at: NSPoint(x: x + 2, y: h - yTop - label + 2), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }
}
