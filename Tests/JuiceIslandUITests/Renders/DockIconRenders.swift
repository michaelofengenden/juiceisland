import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The app icon in each Glyph style (`AppIconArt`): `icon-<style>-1024`, the art at 1024 px; `icon-<style>-dock`, the
/// Dock tile exactly as `DockIcon.draw` hands it over (512 px); `icon-sheet`, the three tiles scaled down as the Dock
/// shows them (256, 128, 64 and 32 px) on a dark and a light Dock, under the bundle's icon; `icon-pixel-vs-bundle`,
/// the Pixel art beside the bundle's 1024 px icon it redraws; `icon-about-<style>`, Settings › About in each style.
/// `zsh scripts/render-all.sh DockIconRenders`. Nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct DockIconRenders {
    static let bundleIcon = RenderHarness.root.appendingPathComponent("App/Main/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")

    @Test(arguments: GlyphStyle.allCases)
    func art(_ style: GlyphStyle) throws {
        try RenderHarness.renderPixels(AppIconArt(style: style, side: DockIcon.points), "icon-\(style.rawValue)-1024",
                                       scale: 1024 / DockIcon.points)
        let tile = try #require(DockIcon.draw(style)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        try RenderHarness.renderPixels(Image(decorative: tile, scale: 1), "icon-\(style.rawValue)-dock", scale: 1)
    }

    @Test func sheet() throws {
        let bundle = try #require(NSImage(contentsOf: Self.bundleIcon)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var rows: [(String, CGImage)] = [("bundle", bundle)]
        for style in GlyphStyle.allCases {
            rows.append((style.rawValue, try #require(DockIcon.draw(style)?.cgImage(forProposedRect: nil, context: nil, hints: nil))))
        }
        let sizes: [CGFloat] = [256, 128, 64, 32]
        let sheet = VStack(alignment: .leading, spacing: 0) {
            ForEach([Color(hex: 0x1E1E20), Color(hex: 0xE8E8EC)], id: \.self) { ground in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows, id: \.0) { name, image in
                        HStack(alignment: .center, spacing: 12) {
                            Text(verbatim: name).font(.system(size: 11, weight: .medium)).foregroundStyle(.gray).frame(width: 50, alignment: .leading)
                            ForEach(sizes, id: \.self) { pixels in
                                // Points at 2×: a tile `pixels` wide on the display.
                                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                                    .frame(width: pixels / 2, height: pixels / 2)
                            }
                        }
                    }
                }
                .padding(12)
                .background(ground)
            }
        }
        try RenderHarness.renderPixels(sheet, "icon-sheet", scale: 2)
    }

    @Test func pixelBesideTheBundle() throws {
        let bundle = try #require(NSImage(contentsOf: Self.bundleIcon)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pair = HStack(spacing: 0) {
            Image(decorative: bundle, scale: 1).resizable().frame(width: 512, height: 512)
            AppIconArt(style: .pixel, side: 512)
        }
        .background(Color(hex: 0x808084))
        try RenderHarness.renderPixels(pair, "icon-pixel-vs-bundle", scale: 1)
    }

    @Test(arguments: GlyphStyle.allCases)
    func about(_ style: GlyphStyle) throws {
        let settings = AppSettings.ephemeral()
        settings.glyphStyle = style
        let env = AppEnvironment.demo(settings: settings)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .about), drawsTrafficLights: true, scrolls: false)
        let hosting = NSHostingView(rootView: view.frame(width: SettingsTheme.Metrics.width).fixedSize(horizontal: false, vertical: true)
            .environment(env).environment(\.colorScheme, .dark))
        let height = max(SettingsTheme.Metrics.minHeight, ceil(hosting.fittingSize.height))
        try RenderHarness.renderHosted(view, "icon-about-\(style.rawValue)", size: CGSize(width: SettingsTheme.Metrics.width, height: height),
                                       env: env)
    }
}
