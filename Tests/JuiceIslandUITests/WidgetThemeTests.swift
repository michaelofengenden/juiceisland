import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The widgets on the desktop since wave A5 (P1224; the themes' widget backgrounds of P540 to P545, P566 and P777 are
/// gone): the owner's Widget background (P1401) whatever the island's theme, what they never draw, and the system's own
/// looks, where every theme draws the same.
@MainActor
@Suite(.serialized)
struct WidgetThemeTests {
    static let now = DemoClock.now
    static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    /// The widgets' background is the owner's choice and nothing else (P1401): Glass is the system's thinnest material in
    /// its dark look and not one pixel more (no veil, no rim, no floor), Black is pure opaque black to its edges; the same
    /// whatever the environment says, its look included (WidgetKit hands the container background none of the entry
    /// view's, which is how the theme's background drew Black's black on the owner's desktop, P1224). The entries read the
    /// choice from the snapshot, Glass with none.
    @Test func theBackgroundIsTheChoiceWhateverTheEnvironment() throws {
        let size = CGSize(width: 160, height: 160)
        // Over a ground of pure red: what shows of it is what the background leaves (an empty render is not read).
        func pixels(_ choice: WidgetBackgroundChoice, _ theme: JuiceTheme, _ scheme: ColorScheme) throws -> ThemeTests.Pixels {
            try ThemeTests.pixels(ZStack { Color(red: 1, green: 0, blue: 0); WidgetBackdrop(choice: choice) }
                .environment(\.glassRendering, .live)
                .frame(width: size.width, height: size.height).containerShape(Self.shape)
                .environment(\.juiceTheme, theme).environment(\.colorScheme, scheme), size: size)
        }
        let material = try ThemeTests.pixels(ZStack { Color(red: 1, green: 0, blue: 0); Rectangle().fill(.ultraThinMaterial) }
            .environment(\.colorScheme, .dark).frame(width: size.width, height: size.height), size: size)
        let tint = material.rgba(160, 160)
        #expect(tint.a == 1 && tint.r < 0.97 && tint.r > 0.5 && tint.g > 0.05, "the material shows the ground through, tinted: \(tint)")
        for theme in JuiceTheme.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let glass = try pixels(.glass, theme, scheme), black = try pixels(.black, theme, scheme)
                #expect(glass.width == 320 && black.width == 320 && black.height == 320)
                let other = stride(from: 0, to: glass.data.count, by: 4).filter { i in
                    (0..<4).contains { abs(Int(glass.data[i + $0]) - Int(material.data[i + $0])) > 1 }
                }.count
                #expect(other == 0, "glass is the dark material alone: \(other) pixels not, \(theme) \(scheme)")
                let notBlack = stride(from: 0, to: black.data.count, by: 4).filter { i in
                    black.data[i] != 0 || black.data[i + 1] != 0 || black.data[i + 2] != 0 || black.data[i + 3] != 255
                }.count
                #expect(notBlack == 0, "black is pure black to its edges: \(notBlack) pixels not, \(theme) \(scheme)")
            }
        }
        var snapshot = WidgetSnapshot.make(.demo(), at: Self.now)
        #expect(UsageWidgetEntry(date: Self.now, snapshot: nil).background == .glass)
        #expect(IslandWidgetEntry(date: Self.now, snapshot: nil, scheme: nil).background == .glass)
        #expect(UsageWidgetEntry(date: Self.now, snapshot: snapshot).background == .glass)
        snapshot.widgetBackground = WidgetBackgroundChoice.black.rawValue
        #expect(UsageWidgetEntry(date: Self.now, snapshot: snapshot).background == .black)
        #expect(IslandWidgetEntry(date: Self.now, snapshot: snapshot, scheme: nil).background == .black)
        snapshot.widgetBackground = "frosted"
        #expect(UsageWidgetEntry(date: Self.now, snapshot: snapshot).background == .glass, "one this build does not know")
    }

    /// No glass of ours in a widget: nothing under `App/Widget` asks for the island's glass surface, whose live path is
    /// `glassEffect` (P540), paints the island's black, or asks for a menu or a hover. The one material is Glass's
    /// container background, the system's thinnest (P1401), in `WidgetBackground.swift` alone.
    @Test func theWidgetNeverAsksForGlassWidgetKitCannotDraw() throws {
        let folder = RenderHarness.root.appendingPathComponent("App/Widget")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count >= 5)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for call in ["glassEffect(", "GlassEffectContainer", "NSGlassEffectView", "NSVisualEffectView", "GlassSurface(", "GlassSurfaceBody(",
                         "themedSurface(", "glassSurface(", "widgetTexture(", "IslandTheme.bg", "contextMenu", "hoverTarget"] {
                #expect(!source.contains(call), "\(file.lastPathComponent): \(call)")
            }
            let glass = "Material.ultraThinMaterial", uses = source.components(separatedBy: glass).count - 1
            #expect(!source.replacingOccurrences(of: glass, with: "").contains("Material"), "\(file.lastPathComponent): Material")
            #expect(uses == (file.lastPathComponent == "WidgetBackground.swift" ? 1 : 0), "Glass's one material: \(file.lastPathComponent)")
        }
    }

    // MARK: The system's looks (P542)

    /// In the desktop's tinted, clear and vibrant looks the system takes the background away and draws the content in one
    /// colour, so every theme draws exactly what Black draws there: none of its greys or veils.
    @Test func inTheSystemsLooksEveryThemeDrawsTheSame() throws {
        let snapshots: [WidgetSnapshot?] = [.preview(at: Self.now), .closed(at: Self.now, theme: .smoke), nil]
        for snapshot in snapshots {
            for face in WidgetFace.allCases {
                let size = WidgetRenders.Size.of(face)
                func pixels(_ theme: JuiceTheme) throws -> [UInt8] {
                    try ThemeTests.pixels(IslandWidgetView(snapshot: snapshot, face: face, size: size, date: Self.now, tinted: true)
                        .modifier(SessionsWidgetInk(fullColour: false))
                        .environment(\.juiceTheme, theme), size: size).data
                }
                let black = try pixels(.black)
                for theme in JuiceTheme.allCases {
                    #expect(WidgetGlassRenders.alike(try pixels(theme), black), "\(face) \(theme) \(snapshot?.appRunning.description ?? "none")")
                }
            }
        }
    }

    /// In full colour the sessions widget draws the same whatever the island's theme: Glass look Widget's ink.
    @Test func inFullColourTheThemeChangesNothing() throws {
        let size = WidgetRenders.Size.medium
        func pixels(_ theme: JuiceTheme) throws -> [UInt8] {
            try ThemeTests.pixels(IslandWidgetView(snapshot: .preview(at: Self.now), face: .medium, size: size, date: Self.now)
                .modifier(SessionsWidgetInk(fullColour: true))
                .environment(\.juiceTheme, theme), size: size).data
        }
        let glass = try pixels(.glass)
        for theme in JuiceTheme.allCases { #expect(WidgetGlassRenders.alike(try pixels(theme), glass), "\(theme)") }
    }
}
