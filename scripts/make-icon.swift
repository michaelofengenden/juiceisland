// Draws Juice Island's temporary app icon (original art: the app's own pixel glyphs and colours) and writes
//   App/Main/Resources/Assets.xcassets/AppIcon.appiconset/   the chosen variant, every macOS size (16 to 1024 px)
//   renders/icon/<variant>-{1024,128,32}.png, renders/icon/sheet.png   previews of all three variants (git-ignored)
// Usage: swift scripts/make-icon.swift [glyph|island|glass]   (default: glyph; run from anywhere)
//        swift scripts/make-icon.swift --built <app>   renders a built app's icon as macOS shows it (NSWorkspace) to
//        renders/icon/built-{512,128,32}.png, to check it is full size and not on a grey plate; never opens the app
//
// The artwork is a pre-drawn macOS squircle on Apple's 1024 grid (an 824 px body, 100 px margins, continuous
// corners). macOS 26 recognises that shape and shows the art full size in its own squircle (so it does a full-bleed
// square, which it masks); art of a free shape, such as a circle, is shrunk onto a grey plate instead. Sizes of 64 px and below redraw the pixel art
// on whole device pixels, without gaps or glow, so the Dock's and Finder's small icons stay crisp.
//
// App/Shared/AppIconArt.swift redraws the `glyph` variant's squircle, ground and pill at runtime, with the Liquid or Sand
// engine's art under the pill, for the Dock and About in those Glyph styles: keep the two in step.
import AppKit

let variants = ["glyph", "island", "glass"]
let chosen = CommandLine.arguments.dropFirst().first ?? "glyph"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let previews = root.appendingPathComponent("renders/icon")

if chosen == "--built" {
    guard CommandLine.arguments.count == 3 else {
        FileHandle.standardError.write("usage: make-icon.swift --built <app>\n".data(using: .utf8)!)
        exit(2)
    }
    // The icon comes from LaunchServices, which knows only registered bundles: register the app for the render, and
    // unregister it after, as build-app.sh does, so Spotlight and Open With never offer the dev build.
    let app = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
    func lsregister(_ flag: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
            + "LaunchServices.framework/Support/lsregister")
        process.arguments = [flag, app]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
    lsregister("-f")
    let icon = NSWorkspace.shared.icon(forFile: app)
    try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
    for size in [512, 128, 32] {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        try! rep.representation(using: .png, properties: [:])!.write(to: previews.appendingPathComponent("built-\(size).png"))
    }
    lsregister("-u")
    print("make-icon: built icon -> \(previews.path)/built-{512,128,32}.png")
    exit(0)
}
guard variants.contains(chosen) else {
    FileHandle.standardError.write("make-icon: variant must be one of \(variants.joined(separator: ", "))\n".data(using: .utf8)!)
    exit(2)
}

// The app's colours (App/Theme/IslandTheme.swift): brand orange, running blue, done green, ink.
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let brand = rgb(0xFFB45C), run = rgb(0x4E80ED), done = rgb(0x6FB982), ink = rgb(0xF4F4F0)

// The brand glyph (App/Shared/PixelGlyph.swift): a juice box with a straw.
let brandRows = [".....#.", "....#..", ".#####.", ".#...#.", ".#####.", ".#####.", "..###.."]
// Equalizer frame 0 (PixelGlyph.equalizerFrames[0]): bar heights for columns 0, 2, 4, 6.
let eqHeights = [3, 5, 2, 6]
// A bigger pixel juice glass: o juice, O juice surface, g glass, s straw, b ice.
let glassRows = [
    ".........s.",
    "........s..",
    ".ggggggsgg.",
    ".g....s..g.",
    ".gOOOOsOOg.",
    ".goooosoog.",
    ".gbboosoog.",
    ".gbbooooog.",
    "..gooooog..",
    "..gooooog..",
    "...ggggg...",
]

/// Apple's continuous-corner rounded rectangle (the squircle macOS icons use): each corner is three cubic curves
/// that reach 1.528 × `radius` along both edges.
func squirclePath(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    // Corner, the edge direction into it, and the edge direction out of it, clockwise from the top right (y down).
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    for (index, (corner, into, out)) in corners.enumerated() {
        // (distance before the corner along `into`, distance past the edge along `out`), in radii.
        func p(_ t: CGFloat, _ n: CGFloat) -> CGPoint {
            CGPoint(x: corner.x - t * r * into.dx + n * r * out.dx, y: corner.y - t * r * into.dy + n * r * out.dy)
        }
        if index == 0 { path.move(to: p(1.52866483, 0)) } else { path.addLine(to: p(1.52866483, 0)) }
        path.addCurve(to: p(0.66993427, 0.06549600), control1: p(1.08849323, 0), control2: p(0.86840689, 0))
        path.addCurve(to: p(0.06549569, 0.66993493), control1: p(0.37260046, 0.17941168), control2: p(0.17941097, 0.37260121))
        path.addCurve(to: p(0, 1.52866483), control1: p(0, 0.86840689), control2: p(0, 1.08849323))
    }
    path.closeSubpath()
    return path
}

/// Fills one pixel-art pattern. `palette` maps a character to its colour and opacity; `px` is one art pixel in
/// device pixels; gaps are an eighth of a pixel (the app draws `px − 0.5` at 4 pt), dropped on small sizes.
func drawPixels(_ ctx: CGContext, rows: [String], origin: CGPoint, px: CGFloat, gaps: Bool,
                palette: (Character, _ topOfColumn: Bool) -> CGColor?) {
    let side = gaps ? px * 0.875 : px
    let width = rows.map(\.count).max() ?? 0
    for x in 0..<width {
        var top = true
        for (y, row) in rows.enumerated() {
            let chars = Array(row)
            guard x < chars.count, chars[x] != "." else { continue }
            if let colour = palette(chars[x], top) {
                ctx.setFillColor(colour)
                ctx.fill(CGRect(x: origin.x + CGFloat(x) * px, y: origin.y + CGFloat(y) * px, width: side, height: side))
            }
            top = false
        }
    }
}

/// Draws `body` once, under the app's two stacked glows (2.5 then 6 at 55 % per 4 pt pixel), as SwiftUI stacks them.
func withGlow(_ ctx: CGContext, colour: CGColor, px: CGFloat, enabled: Bool, _ body: () -> Void) {
    guard enabled else { body(); return }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 6 * px / 4 * 1.6, color: colour.copy(alpha: 0.55))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setShadow(offset: .zero, blur: 2.5 * px / 4 * 1.6, color: colour)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    ctx.endTransparencyLayer()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

/// The island pill hanging from the squircle's top edge: pure black, a hairline, a done dot and an equalizer.
func drawPill(_ ctx: CGContext, body: CGRect, unit u: CGFloat, small: Bool, width: CGFloat, height: CGFloat,
              content: Bool) {
    let pill = CGRect(x: body.midX - width * u / 2, y: body.minY + 34 * u, width: width * u, height: height * u)
    let path = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)
    ctx.addPath(path); ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
    if !small {
        ctx.addPath(path); ctx.setStrokeColor(rgb(0xFFFFFF, 0.14)); ctx.setLineWidth(3 * u); ctx.strokePath()
    }
    guard content else { return }
    // Done dot on the left, a running equalizer on the right, as the island shows a finished and a working session.
    let dot = pill.height * 0.30
    let dotRect = CGRect(x: pill.minX + pill.height * 0.42, y: pill.midY - dot / 2, width: dot, height: dot)
    withGlow(ctx, colour: done, px: dot / 2, enabled: !small) {
        ctx.setFillColor(done); ctx.fillEllipse(in: dotRect)
    }
    let epx = small ? max(1, (pill.height * 0.5 / 7).rounded(.down)) : pill.height * 0.52 / 7
    let eqRows = (0..<7).map { y in
        String((0..<7).map { x -> Character in
            guard x % 2 == 0 else { return "." }
            return 6 - y < eqHeights[x / 2] ? "#" : "."
        })
    }
    let eqOrigin = CGPoint(x: (pill.maxX - pill.height * 0.42 - 7 * epx).rounded(), y: (pill.midY - 3.5 * epx).rounded())
    withGlow(ctx, colour: run, px: epx, enabled: !small) {
        drawPixels(ctx, rows: eqRows, origin: eqOrigin, px: epx, gaps: !small) { _, top in run.copy(alpha: top ? 1 : 0.85) }
    }
}

/// One icon at `size` device pixels, in a top-left-origin context.
func drawIcon(_ variant: String, size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: 1, y: -1)
    let u = s / 1024
    let small = size <= 64
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let squircle = squirclePath(body, radius: 185.4 * u)

    // Apple's grid shadow under the body.
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 12 * u), blur: 28 * u, color: rgb(0x000000, 0.45))
        ctx.addPath(squircle); ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
        ctx.restoreGState()
    }
    // Body: the About icon's gradient (#1A1A1C to black at 60 %), lifted a touch so the black pill reads.
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [rgb(0x2A2A2E), rgb(0x0C0C0D), rgb(0x000000)] as CFArray,
                              locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX + body.width * 0.3, y: body.minY),
                           end: CGPoint(x: body.minX + body.width * 0.7, y: body.maxY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    switch variant {
    case "glyph":
        // The brand glyph big and glowing under a small island pill: the About icon, made for the Dock.
        drawPill(ctx, body: body, unit: u, small: small, width: 330, height: 92, content: !small)
        let px = small ? max(1, (s * 0.44 / 7).rounded(.down)) : 58 * u
        let origin = CGPoint(x: ((s - 7 * px) / 2).rounded(), y: (body.midY - 3.5 * px + 48 * u).rounded())
        withGlow(ctx, colour: brand, px: px, enabled: !small) {
            drawPixels(ctx, rows: brandRows, origin: origin, px: px, gaps: !small) { _, top in brand.copy(alpha: top ? 1 : 0.85) }
        }
    case "island":
        // The island itself as the hero: a wide pill with the juice glyph and a running equalizer.
        let pill = CGRect(x: body.midX - 330 * u, y: body.midY - 115 * u, width: 660 * u, height: 230 * u)
        let path = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)
        ctx.saveGState()
        if !small { ctx.setShadow(offset: .zero, blur: 90 * u, color: brand.copy(alpha: 0.35)) }
        ctx.addPath(path); ctx.setFillColor(rgb(0x000000)); ctx.fillPath()
        ctx.restoreGState()
        if !small { ctx.addPath(path); ctx.setStrokeColor(rgb(0xFFFFFF, 0.16)); ctx.setLineWidth(4 * u); ctx.strokePath() }
        let px = small ? max(1, (pill.height * 0.62 / 7).rounded(.down)) : 20 * u
        let glyphOrigin = CGPoint(x: (pill.minX + pill.height * 0.42).rounded(), y: (pill.midY - 3.5 * px).rounded())
        withGlow(ctx, colour: brand, px: px, enabled: !small) {
            drawPixels(ctx, rows: brandRows, origin: glyphOrigin, px: px, gaps: !small) { _, top in brand.copy(alpha: top ? 1 : 0.85) }
        }
        let eqRows = (0..<7).map { y in
            String((0..<7).map { x -> Character in
                guard x % 2 == 0 else { return "." }
                return 6 - y < eqHeights[x / 2] ? "#" : "."
            })
        }
        let eqOrigin = CGPoint(x: (pill.maxX - pill.height * 0.42 - 7 * px).rounded(), y: glyphOrigin.y)
        withGlow(ctx, colour: run, px: px, enabled: !small) {
            drawPixels(ctx, rows: eqRows, origin: eqOrigin, px: px, gaps: !small) { _, top in run.copy(alpha: top ? 1 : 0.85) }
        }
    default:
        // A bigger pixel glass of juice with a green straw and blue ice, under the island pill.
        drawPill(ctx, body: body, unit: u, small: small, width: 300, height: 84, content: false)
        let cols = 11, rowsCount = glassRows.count
        let px = small ? max(1, (s * 0.62 / CGFloat(cols)).rounded(.down)) : 50 * u
        let origin = CGPoint(x: ((s - CGFloat(cols) * px) / 2).rounded(),
                             y: (body.midY - CGFloat(rowsCount) * px / 2 + 60 * u).rounded())
        let juice: (Character, Bool) -> CGColor? = { c, _ in
            switch c {
            case "O": return brand
            case "o": return brand.copy(alpha: 0.82)
            case "b": return run.copy(alpha: 0.9)
            case "s": return done
            case "g": return ink.copy(alpha: 0.55)
            default: return nil
            }
        }
        withGlow(ctx, colour: brand, px: px * 0.7, enabled: !small) {
            drawPixels(ctx, rows: glassRows, origin: origin, px: px, gaps: !small, palette: juice)
        }
    }
    ctx.restoreGState()

    // A hairline around the body, like the About icon's 20 % border.
    if !small {
        let inset = squirclePath(body.insetBy(dx: 2 * u, dy: 2 * u), radius: 183.4 * u)
        ctx.addPath(inset); ctx.setStrokeColor(rgb(0xFFFFFF, 0.16)); ctx.setLineWidth(3 * u); ctx.strokePath()
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// The asset catalog: macOS's ten slots (16, 32, 128, 256, 512 at 1x and 2x).
let catalog = root.appendingPathComponent("App/Main/Resources/Assets.xcassets")
let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.removeItem(at: iconSet)
var entries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        writePNG(drawIcon(chosen, size: points * scale), iconSet.appendingPathComponent(name))
        entries.append("""
            {\n      "filename" : "\(name)",\n      "idiom" : "mac",\n      "scale" : "\(scale)x",\n      "size" : "\(points)x\(points)"\n    }
            """)
    }
}
let info = "\"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }"
try! "{\n  \"images\" : [\n    \(entries.joined(separator: ",\n    "))\n  ],\n  \(info)\n}\n"
    .write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try! "{\n  \(info)\n}\n".write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// Previews of every variant, and a sheet: each variant at 256, 128, 64, 32 and 16 px, on dark and on light.
for variant in variants {
    for size in [1024, 128, 32] { writePNG(drawIcon(variant, size: size), previews.appendingPathComponent("\(variant)-\(size).png")) }
}
let sizes = [256, 128, 64, 32, 16], pad = 24
let rowHeight = 256 + 2 * pad
let sheetWidth = sizes.reduce(pad) { $0 + $1 + pad }
let sheet = CGContext(data: nil, width: sheetWidth, height: rowHeight * variants.count * 2, bitsPerComponent: 8,
                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for (index, variant) in variants.enumerated() {
    for (shade, background) in [rgb(0x1E1E20), rgb(0xE8E8EC)].enumerated() {
        let y = (variants.count * 2 - 1 - (index * 2 + shade)) * rowHeight
        sheet.setFillColor(background)
        sheet.fill(CGRect(x: 0, y: y, width: sheetWidth, height: rowHeight))
        var x = pad
        for size in sizes {
            sheet.draw(drawIcon(variant, size: size), in: CGRect(x: x, y: y + pad + (256 - size) / 2, width: size, height: size))
            x += size + pad
        }
    }
}
writePNG(sheet.makeImage()!, previews.appendingPathComponent("sheet.png"))
print("make-icon: \(chosen) -> \(iconSet.path)")
print("make-icon: previews -> \(previews.path)")
