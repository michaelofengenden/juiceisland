import AppKit
import SwiftUI
@testable import JuiceIslandUI

/// Headless renders into `renders/<name>.png` at 2x. Nothing is ever shown on screen.
/// - `render` uses `ImageRenderer` (pure SwiftUI: shapes, text, Canvas, images).
/// - `renderHosted` draws an `NSHostingView` offscreen with `cacheDisplay` (a borderless window that is never ordered
///   in), for views with AppKit-backed controls (TextField, Toggle, Picker, ScrollView, Menu) that `ImageRenderer`
///   leaves blank.
/// Name renders like the reference shots in `refs/` (`A-…`, `B-…`, `C-…`, `D-…`) so `scripts/render-all.sh` pairs
/// them in `renders/compare/`.
/// Offscreen, the window server composites no glass, so every render draws the glass themes' stand-ins
/// (`GlassRendering.standIn`: a `GlassStage`'s backdrop blurred in the surface's shape, Smoke's under its floor, Glass's
/// shifted into its look's bounds); Black reads none of it.
@MainActor
enum RenderHarness {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// `renders/`, or `$JI_RENDER_DIR` when `scripts/render-all.sh` is given another output folder.
    static let directory = ProcessInfo.processInfo.environment["JI_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? root.appendingPathComponent("renders", isDirectory: true)

    /// Renders `view` with `env` injected (a fresh demo environment when nil) at `size` (its ideal size when nil).
    @discardableResult
    static func render<V: View>(_ view: V, _ name: String, size: CGSize? = nil, env: AppEnvironment? = nil,
                                background: Color = .clear, scheme: ColorScheme = .dark) throws -> URL {
        let environment = env ?? .demo()
        let content = view
            .frame(width: size?.width, height: size?.height)
            .background(background)
            .environment(environment)
            .environment(\.colorScheme, scheme)
            .environment(\.glassRendering, .standIn)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let size { renderer.proposedSize = ProposedViewSize(size) }
        guard let image = renderer.cgImage else { throw RenderError.noImage(name) }
        return try write(NSBitmapImageRep(cgImage: image), name)
    }

    /// `scheme` is the look the window and the view are drawn in: Settings › General › Appearance's (dark unless asked).
    @discardableResult
    static func renderHosted<V: View>(_ view: V, _ name: String, size: CGSize, env: AppEnvironment? = nil,
                                      scheme: ColorScheme = .dark) throws -> URL {
        try write(hostedBitmap(view, name, size: size, env: env, scheme: scheme), name)
    }

    /// `renderHosted`'s bitmap, at 2x, written nowhere (a pixel check).
    static func hostedBitmap<V: View>(_ view: V, _ name: String, size: CGSize, env: AppEnvironment? = nil,
                                      scheme: ColorScheme = .dark) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let environment = env ?? .demo()
        let hosting = NSHostingView(rootView: AnyView(view.environment(environment).environment(\.colorScheme, scheme)
            .environment(\.glassRendering, .standIn)))
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = rect
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw RenderError.noImage(name) }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        return rep
    }

    /// Draws a whole window, title bar and traffic lights included, without ever ordering it on screen: the window is
    /// sized, laid out and its frame view (the content view's superview) cached into a bitmap at 2x.
    @discardableResult
    static func renderWindow(_ window: NSWindow, _ name: String, contentSize: CGSize) throws -> URL {
        _ = NSApplication.shared
        window.setContentSize(contentSize)
        guard let frameView = window.contentView?.superview else { throw RenderError.noImage(name) }
        for _ in 0..<3 {
            frameView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        frameView.displayIfNeeded()
        let size = frameView.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw RenderError.noImage(name) }
        rep.size = size
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return try write(rep, name)
    }

    /// Renders `view` alone (no environment, dark) at `scale` device pixels a point, then enlarges every pixel to
    /// `zoom` × `zoom` with no smoothing, so a glyph's fine detail can be inspected pixel by pixel.
    @discardableResult
    static func renderPixels<V: View>(_ view: V, _ name: String, scale: CGFloat = 2, zoom: Int = 1) throws -> URL {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark).environment(\.glassRendering, .standIn))
        renderer.scale = scale
        guard let image = renderer.cgImage else { throw RenderError.noImage(name) }
        guard zoom > 1 else { return try write(NSBitmapImageRep(cgImage: image), name) }
        let width = image.width * zoom, height = image.height * zoom
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.noImage(name) }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let enlarged = context.makeImage() else { throw RenderError.noImage(name) }
        return try write(NSBitmapImageRep(cgImage: enlarged), name)
    }

    private static func write(_ rep: NSBitmapImageRep, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw RenderError.noImage(name) }
        let url = directory.appendingPathComponent(name + ".png")
        try data.write(to: url)
        return url
    }

    enum RenderError: Error { case noImage(String) }
}
