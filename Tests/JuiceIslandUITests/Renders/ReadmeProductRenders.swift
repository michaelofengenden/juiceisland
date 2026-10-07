import AppKit
import OpenIslandCore
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// The public README's product page (wave 10, P1587 to P1599), headless, beside `ReadmeShotRenders`' shots: the app's own
/// icon for the hero (`readme-icon`), the Download for Mac button for GitHub's light and dark themes (`readme-download`,
/// `readme-download-dark`), and a Claude Code session sent to the island and kept running in Claude Code's background
/// (`readme-keep-running`), from the Demo sessions scenario's made-up folders only. `JI_RENDER_DIR=<folder>` writes them
/// there (the README's images are `docs/public/images` here, `docs/images` in the public repository). Nothing is shown on
/// screen: `JI_RENDER_DIR="$PWD/docs/public/images" swift test --filter ReadmeProductRenders`.
@MainActor
@Suite(.serialized)
struct ReadmeProductRenders {
    typealias ID = FixtureSessionFeed.DemoSessionsID

    // MARK: The icon

    /// The bundle's own icon (`scripts/make-icon.swift`'s art in the asset catalog), at 128 points: 256 pixels, one for one.
    static let iconFile = RenderHarness.root.appendingPathComponent("App/Main/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png")

    @Test func icon() throws {
        let image = try #require(NSImage(contentsOf: Self.iconFile), "no app icon at \(Self.iconFile.path)")
        let url = try RenderHarness.render(Image(nsImage: image).resizable().interpolation(.high), "readme-icon",
                                           size: CGSize(width: 128, height: 128))
        // The icon's own pixels: the same size, and its corners as clear as the art's (no ground behind the squircle).
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
        #expect(rep.pixelsWide == 256 && rep.pixelsHigh == 256)
        #expect((rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.01)
    }

    // MARK: The download button

    /// "Download for Mac" with a pixel arrow pointing down (the DMG art's arrow, turned): a black pill for GitHub's light
    /// theme, a white one for its dark theme, so the button stands out on either ground.
    struct DownloadButton: View {
        var forDarkTheme: Bool

        static let title = "Download for Mac"

        var body: some View {
            HStack(spacing: 11) {
                PixelArrow(colour: forDarkTheme ? Color(hex: 0xD9731A) : IslandTheme.brand)
                Text(Self.title).font(.system(size: 17, weight: .semibold)).tracking(-0.1)
            }
            .foregroundStyle(forDarkTheme ? Color.black : Color.white)
            .padding(.leading, 22).padding(.trailing, 26)
            .frame(height: 50)
            .background(Capsule().fill(forDarkTheme ? Color.white : Color.black))
            .padding(1)
        }
    }

    /// A shaft three cells wide and three tall over a head seven wide, as `scripts/make-dmg-art.swift` draws its arrow.
    struct PixelArrow: View {
        var colour: Color
        static let cell: CGFloat = 2.4
        static let gap: CGFloat = 0.7
        static let cells: [(Int, Int)] = {
            var cells: [(Int, Int)] = []
            for y in 0..<3 { for x in 2...4 { cells.append((x, y)) } }
            for (row, reach) in [(3, 3), (4, 2), (5, 1), (6, 0)] {
                for x in (3 - reach)...(3 + reach) { cells.append((x, row)) }
            }
            return cells
        }()

        var body: some View {
            let step = Self.cell + Self.gap, side = 7 * step - Self.gap
            Canvas { context, _ in
                for (x, y) in Self.cells {
                    let rect = CGRect(x: CGFloat(x) * step, y: CGFloat(y) * step, width: Self.cell, height: Self.cell)
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.6), with: .color(colour))
                }
            }
            .frame(width: side, height: side)
        }
    }

    @Test func downloadButtons() throws {
        for (dark, name) in [(false, "readme-download"), (true, "readme-download-dark")] {
            let url = try RenderHarness.render(DownloadButton(forDarkTheme: dark), name, scheme: dark ? .dark : .light)
            let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
            // The README shows it at half its pixels: a button about 220 points wide and 52 high.
            #expect((400...480).contains(rep.pixelsWide) && rep.pixelsHigh == 104, "\(name): \(rep.pixelsWide)x\(rep.pixelsHigh)")
            // Clear around the pill, the pill's own colour at its middle left.
            #expect((rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.01)
            let ground = try #require(rep.colorAt(x: 30, y: 52)?.usingColorSpace(.sRGB))
            #expect(dark ? ground.brightnessComponent > 0.95 : ground.brightnessComponent < 0.05, "\(name)")
        }
    }

    // MARK: Keep sessions running

    /// The Demo sessions with Claude's edit in `field-notes` sent to the island and moved into Claude Code's background,
    /// working on: its card over the island's rows reads "Background · Working · Edit" with the answer it gave last.
    static let keptAnswer = "Tightened the cards to 12 points and checked both themes. Now the list view."

    static func keepRunningEnvironment() throws -> AppEnvironment {
        let now = DemoClock.now, m: TimeInterval = 60
        let feed = FixtureSessionFeed(scenario: .demoSessions, now: now)
        let engine = feed.engine
        engine.loadPreviewEvents([
            .claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: ID.edit, claudeMetadata: ClaudeSessionMetadata(
                lastUserPrompt: "now the list view", lastAssistantMessage: keptAnswer, currentTool: "Edit",
                currentToolInputPreview: "Sources/Cards/ListView.swift"), timestamp: now - 1 * m)),
            .activityUpdated(SessionActivityUpdated(sessionID: ID.edit, summary: "Running Edit", phase: .running, timestamp: now - 1 * m)),
        ])
        engine.loadPreviewAgents([ID.edit: 4402])
        engine.loadPreviewFolds([ID.edit])
        engine.folds[ID.edit]?.background = FoldBackground(stage: .moved, shortID: "4f2a9c1e", profile: "/tmp/ji-render-home/.claude",
                                                          folder: "/tmp/ji-render-home/field-notes")
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = .black
        settings.islandStyle = .clean
        // The sessions alone: the batteries have their own shots, and this one is about the card.
        settings.islandShowsUsage = false
        settings.glyphStyle = .pixel
        settings.showAs = .island
        return AppEnvironment(settings: settings, usage: DemoUsageModel(now: now, variant: .showcase), sessions: feed.makeModel())
    }

    /// Only the scenario's made-up folders, and the card is the background one, working.
    @Test func theKeptSessionIsADemoSessionInTheBackground() throws {
        let env = try Self.keepRunningEnvironment()
        let card = try #require(env.sessions.foldedCard(ID.edit))
        #expect(card.background != nil)
        #expect(Set(env.sessions.rows.compactMap(\.project)).isSubset(of: ReadmeShotRenders.folders))
        #expect(env.sessions.folded.count == 1)
    }

    @Test func keepRunning() throws {
        let env = try Self.keepRunningEnvironment()
        let (ui, measured) = FoldRenders.state(env)
        let size = CGSize(width: 540, height: measured.height)
        let scene = AppearanceRenders.islandScene(ui, size: size, backdrop: .preview, theme: .black, scheme: .dark)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(scene, "readme-keep-running", size: size, env: env)
    }
}
