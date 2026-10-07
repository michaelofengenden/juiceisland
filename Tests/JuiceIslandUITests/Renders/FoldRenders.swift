import AppKit
@testable import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// A session sent to the island (P1300 to P1324), headless: the opened island's list with the folded session's
/// conversation card over the rows, in each of its states (idle, working, a held reply, sending, sent, not sent, a held
/// reply given back to the field because its tab was in front or closed, its tab gone with the resume's note, with its
/// resumed run failed and with nowhere to reply, a long answer, one that waits on an approval; working in a window in
/// the Dock, stopped when its window closed with Continue (Claude, Codex) or with Open in terminal alone, and carried
/// on; Codex's background service's turn, at idle, the island's own turn there, and Continue that met its turn) and a
/// stack of three, on Black and on Glass in light (over a white window) and dark (over a black desktop):
/// `fold-<state>-black`, `fold-<state>-glass-light`, `fold-<state>-glass-dark`. Drawn hosted: the card holds AppKit's
/// field. Glass is the stand-in offscreen.
@MainActor
@Suite(.serialized)
struct FoldRenders {
    typealias ID = FoldFixtures.ID

    struct Scene {
        var name: String
        var folded: [String]
        var resume: FoldFixtures.Resume? = nil
        /// The resume's problem after this fold's resumed reply (P1352).
        var problem: String? = nil
        /// A held reply given back to the field (P1356, P1359).
        var returned: ReturnedReply? = nil
        /// The held reply's text, when not the fixture's (P1358: two joined, cut to the line).
        var held: String? = nil
        /// Anything else the scene needs of the engine or the resume (P1415 to P1419).
        var setUp: (@MainActor (SessionEngine, FoldFixtures.Resume?) -> Void)? = nil
    }

    static let scenes: [Scene] = [
        Scene(name: "idle", folded: [ID.idle]),
        Scene(name: "working", folded: [ID.working]),
        Scene(name: "held", folded: [ID.held]),
        Scene(name: "held-joined", folded: [ID.held], held: "then push the branch and open the PR against main with the release notes in its body"),
        Scene(name: "sending", folded: [ID.sending]),
        Scene(name: "sent", folded: [ID.sent]),
        Scene(name: "notsent", folded: [ID.notSent]),
        Scene(name: "returned", folded: [ID.idle], returned: ReturnedReply(text: "open the PR", why: .tabInFront)),
        Scene(name: "gone-returned", folded: [ID.gone], resume: FoldFixtures.Resume(offer: .resume(note: "Codex runs this without asking, within its sandbox.")),
              returned: ReturnedReply(text: "also delete the build folder", why: .wayChanged)),
        Scene(name: "gone-resume", folded: [ID.gone], resume: FoldFixtures.Resume(offer: .resume(note: "Codex runs this without asking, within its sandbox."))),
        Scene(name: "gone-failed", folded: [ID.gone], resume: FoldFixtures.Resume(offer: .resume(note: "Codex runs this without asking, within its sandbox.")),
              problem: "Failed · usage limit reached"),
        Scene(name: "gone-open", folded: [ID.gone]),
        Scene(name: "long", folded: [ID.long]),
        Scene(name: "stack", folded: [ID.held, ID.idle, ID.working]),
        // Its window in the Dock still holds the run (P1417).
        Scene(name: "working-terminal", folded: [ID.working], setUp: { engine, _ in engine.folds[ID.working]?.tucked = true }),
        // Its window closed mid-turn: Continue and what it sends (P1415, P1419).
        Scene(name: "stopped", folded: [ID.stopped], resume: FoldFixtures.Resume(offer: .resume(note: nil))),
        Scene(name: "stopped-codex", folded: [ID.gone], resume: FoldFixtures.Resume(offer: .resume(note: SessionResumer.codexNote)),
              setUp: { engine, _ in FoldFixtures.stop(engine, ID.gone) }),
        // Another agent, or none to resume: Open in terminal to continue.
        Scene(name: "stopped-open", folded: [ID.stopped]),
        // Codex's background service runs it (P1486 to P1488): Working, its window closed or not; at idle its note; the
        // island's own turn there, with Stop; Continue that met a turn still running there.
        Scene(name: "daemon-working", folded: [ID.daemon], resume: FoldFixtures.daemonResume(.active(waitsOnYou: false))),
        Scene(name: "daemon-idle", folded: [ID.daemon], resume: FoldFixtures.daemonResume(.idle),
              setUp: { engine, _ in FoldFixtures.endTurn(engine, ID.daemon) }),
        Scene(name: "daemon-island", folded: [ID.daemon], resume: FoldFixtures.daemonResume(.active(waitsOnYou: false)),
              setUp: { _, resume in resume?.running = [ID.daemon] }),
        Scene(name: "daemon-finishing", folded: [ID.daemon], resume: FoldFixtures.daemonResume(.active(waitsOnYou: false)),
              setUp: { _, resume in resume?.problems[ID.daemon] = SessionResumer.finishingWords }),
        // After Continue: the island's run of it, Working with Stop.
        Scene(name: "continuing", folded: [ID.stopped], resume: FoldFixtures.Resume(offer: .resume(note: nil)), setUp: { engine, resume in
            engine.folds[ID.stopped]?.stopped = nil
            resume?.running = [ID.stopped]
        }),
    ]

    /// The island open on its list, at rest, and the render's size (the island and a margin under it).
    static func state(_ env: AppEnvironment) -> (ui: IslandUIState, size: CGSize) {
        let layout = DMotionRenders.measure(env: env, notch: IslandGlassRenders.notch, card: nil)
        let ui = IslandGlassRenders.state(env, surface: .island, layout: layout)
        return (ui, CGSize(width: 540, height: (ui.live.surface.value.height + 24).rounded(.up)))
    }

    static func render(_ scene: Scene) throws {
        let feed = FoldFixtures.feed(folded: scene.folded, resume: scene.resume)
        if let problem = scene.problem, let id = scene.folded.last {
            scene.resume?.problems[id] = problem
            feed.engine.folds[id]?.resumed = true
        }
        if let returned = scene.returned, let id = scene.folded.last { feed.engine.folds[id]?.returned = returned }
        if let held = scene.held, let id = scene.folded.last { feed.engine.folds[id]?.held = held }
        scene.setUp?(feed.engine, scene.resume)
        let env = FoldFixtures.env(feed)
        #expect(env.sessions.folded.count == scene.folded.count, "\(scene.name)")
        let (ui, size) = state(env)
        let looks: [(String, JuiceTheme, GlassBackdrop, ColorScheme)] = [
            ("black", .black, .black, .dark), ("glass-light", .glass, .white, .light), ("glass-dark", .glass, .black, .dark),
        ]
        for (look, theme, backdrop, scheme) in looks {
            env.settings.appearance = scheme == .light ? .light : .dark
            let view = AppearanceRenders.islandScene(ui, size: size, backdrop: backdrop, theme: theme, scheme: scheme)
                .environment(\.sessionGlyphsAnimated, false)
            try RenderHarness.renderHosted(view, "fold-\(scene.name)-\(look)", size: size, env: env, scheme: scheme)
        }
    }

    @Test func everyStateOnBlackAndGlass() throws {
        for scene in Self.scenes { try Self.render(scene) }
    }

    /// The row's Send to island under the pointer, and the menu's item, as the island lists them (Black).
    @Test func theRowsSendToIsland() throws {
        let feed = FoldFixtures.feed(folded: [])
        let env = FoldFixtures.env(feed)
        let row = try #require(env.sessions.row(id: ID.idle))
        #expect(row.canFold && !row.isFolded && env.offersSendToIsland(row))
        let view = CleanSessionRow(row: row, animated: false)
            .padding(.vertical, IslandTheme.Metrics.rowVerticalPadding).padding(.horizontal, 8)
            .frame(width: IslandSize.standard.contentWidth)
            .background(Color.black)
            .environment(\.juiceTheme, .black)
            .environment(\.previewRowHovered, true)
        try RenderHarness.renderHosted(view, "fold-row-black", size: CGSize(width: IslandSize.standard.contentWidth, height: 48), env: env)
    }
}
