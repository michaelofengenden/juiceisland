import AppKit
@testable import IslandEngine
import Testing
@testable import JuiceIslandUI

/// P1050: the window tells the engine which requests' cards it shows the owner, so a Codex request held for its card
/// (Answer Codex on the island) is answered from the window in Window mode. Fixture sessions, a fake workspace center
/// and fake process ids; no window is ordered in.
@MainActor
@Suite(.serialized)
struct WindowAttentionTests {
    static let own: pid_t = 100
    static let terminal: pid_t = 200
    static let browser: pid_t = 300

    /// The Needs you cards' requests, as the fixtures have them.
    static func requests(_ env: AppEnvironment) -> Set<String> {
        Set(env.sessions.needsYou.compactMap { env.sessions.card(for: $0.id)?.request?.id })
    }

    @Test func theRuleIsTheCardsInViewWhileTheWindowShowsAndTheOwnerIsThere() {
        let env = AppEnvironment.demo()
        let cards = env.sessions.needsYou.compactMap { env.sessions.card(for: $0.id) }
        let all = Self.requests(env)
        #expect(!all.isEmpty)
        #expect(WindowAttention.shown(visible: true, ownerAway: false, cards: cards, outOfView: []) == all)
        #expect(WindowAttention.shown(visible: false, ownerAway: false, cards: cards, outOfView: []).isEmpty)
        #expect(WindowAttention.shown(visible: true, ownerAway: true, cards: cards, outOfView: []).isEmpty)
        let first = cards.first { $0.request != nil }!
        let rest = WindowAttention.shown(visible: true, ownerAway: false, cards: cards, outOfView: [first.sessionID])
        #expect(rest == all.subtracting([first.request!.id]))
        // Another app, unless it is this one or the one in front as the cards came.
        #expect(WindowAttention.ownerLeft(activated: Self.terminal, own: Self.own, frontAtShow: Self.browser))
        #expect(!WindowAttention.ownerLeft(activated: Self.own, own: Self.own, frontAtShow: Self.browser))
        #expect(!WindowAttention.ownerLeft(activated: Self.browser, own: Self.own, frontAtShow: Self.browser))
        #expect(WindowAttention.ownerLeft(activated: nil, own: Self.own, frontAtShow: Self.browser))
    }

    /// The watch follows the window's visibility, the cards scrolled away and the owner's app, and tells the engine only
    /// what changed: shown on screen with the browser in front, gone when covered, back, one card scrolled away, gone when
    /// the owner goes to the terminal, back when they come to the window.
    @Test func theWatchTellsTheEngineWhatTheWindowShows() async throws {
        let env = AppEnvironment.demo()
        let engine = try #require((env.sessions as? EngineSessionsModel)?.engine)
        let motion = SurfaceMotion(.hidden)
        let center = NotificationCenter()
        let watch = WindowAttentionWatch(env: env, motion: motion, workspace: center, own: Self.own, frontmost: { Self.browser })
        defer { watch.stop() }
        let all = Self.requests(env)
        #expect(watch.shown.isEmpty && engine.windowShownRequests.isEmpty)

        motion.visibility = .shown
        await settle { watch.shown == all }
        #expect(watch.shown == all && engine.windowShownRequests == all)

        motion.visibility = .hidden
        await settle { watch.shown.isEmpty }
        #expect(engine.windowShownRequests.isEmpty)

        motion.visibility = .shown
        await settle { watch.shown == all }
        let away = try #require(env.sessions.needsYou.first { env.sessions.card(for: $0.id)?.request != nil })
        env.windowCardsOutOfView = [away.id]
        await settle { watch.shown.count == all.count - 1 }
        #expect(!watch.shown.contains(env.sessions.card(for: away.id)!.request!.id))
        env.windowCardsOutOfView = []
        await settle { watch.shown == all }

        // The browser was in front as the cards came: its own late notice is no leaving.
        watch.activated(Self.browser)
        #expect(watch.shown == all)
        watch.activated(Self.terminal)
        #expect(watch.shown.isEmpty && engine.windowShownRequests.isEmpty)
        watch.activated(Self.own)
        #expect(watch.shown == all)

        watch.stop()
        #expect(engine.windowShownRequests.isEmpty)
    }

    /// The real notice reaches the watch through the workspace center it was given.
    @Test func theWorkspacesNoticeReachesTheWatch() async throws {
        let env = AppEnvironment.demo()
        let motion = SurfaceMotion(.shown)
        let center = NotificationCenter()
        let watch = WindowAttentionWatch(env: env, motion: motion, workspace: center, own: Self.own, frontmost: { Self.browser })
        defer { watch.stop() }
        #expect(watch.shown == Self.requests(env))
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil, userInfo: [:])
        await settle { watch.shown.isEmpty }
        #expect(watch.shown.isEmpty)
    }

    private func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }
}
