// Draws the background of Juice's disk image (P976): a warm orange ground and a pixel arrow from the app to the
// Applications link, in the island's pixel style. Original art, made here; no text, so it needs no translation.
//   scripts/dmg/background.png      660 x 400, the Finder window's size (scripts/dmg-layout.swift)
//   scripts/dmg/background@2x.png   1320 x 800, for Retina screens
// release.sh joins the two into one TIFF (tiffutil -cathidpicheck). Run again after changing the art:
//   swift scripts/make-dmg-art.swift
//
// The ground's luminance stays near 0.2, so the icons' names read in Finder's black (Light) and white (Dark) alike, at
// about 4.5 : 1 either way. The arrow sits between the two icons at the layout's height; the window's bottom 40 points
// carry nothing, as Finder may cut a title bar's height off a window's content.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = CGSize(width: 660, height: 400)
/// The icons' centres, from the window's top left (scripts/dmg-layout.swift places them there).
let appCentre = CGPoint(x: 170, y: 190)
let linkCentre = CGPoint(x: 490, y: 190)

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let folder = root.appendingPathComponent("scripts/dmg", isDirectory: true)

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
}

/// The arrow as pixel cells: a shaft three cells tall and a head seven tall, pointing right.
func arrowCells() -> [(Int, Int)] {
    var cells: [(Int, Int)] = []
    for x in 0..<7 { for y in -1...1 { cells.append((x, y)) } }
    for (column, reach) in [(7, 3), (8, 2), (9, 1), (10, 0)] {
        for y in -reach...reach { cells.append((column, y)) }
    }
    return cells
}

func draw(scale: CGFloat) -> CGImage {
    let width = Int(size.width * scale), height = Int(size.height * scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)
    // Top-left origin, as Finder places the icons.
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)

    let ground = CGGradient(colorsSpace: space, colors: [colour(0xD0622A), colour(0xB8471D)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(ground, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
    // A soft light behind each icon, so the two read as a pair.
    for centre in [appCentre, linkCentre] {
        let glow = CGGradient(colorsSpace: space, colors: [colour(0xFFFFFF, 0.16), colour(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 112, options: [])
    }

    let cell: CGFloat = 11, gap: CGFloat = 2.5
    let cells = arrowCells()
    let columns = (cells.map(\.0).max() ?? 0) + 1
    let span = CGFloat(columns) * cell + CGFloat(columns - 1) * gap
    let origin = CGPoint(x: (appCentre.x + linkCentre.x) / 2 - span / 2, y: appCentre.y - cell / 2)
    context.setShadow(offset: .zero, blur: 10, color: colour(0xFFE2B8, 0.55))
    context.setFillColor(colour(0xFFF6EA, 0.95))
    for (x, y) in cells {
        let rect = CGRect(x: origin.x + CGFloat(x) * (cell + gap), y: origin.y + CGFloat(y) * (cell + gap), width: cell, height: cell)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
    }
    context.fillPath()
    return context.makeImage()!
}

func write(_ image: CGImage, _ name: String, scale: CGFloat) throws {
    let url = folder.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    // 72 dpi times the scale, so tiffutil -cathidpicheck pairs the two as one image of 660 x 400 points.
    let dpi = 72 * scale
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    print(url.path)
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try write(draw(scale: 1), "background.png", scale: 1)
try write(draw(scale: 2), "background@2x.png", scale: 2)
