import Foundation
import IslandEngine
import Testing
@testable import JuiceIslandUI

/// Stream C: the window's focus-local keys (P39, P40): characters, not key codes; ⌃ only, never ⌘ or ⌥.
@MainActor
struct CWindowKeyRouterTests {
    typealias Key = WindowKeyRouter.KeyPress
    typealias ID = FixtureSessionFeed.ID

    @Test
    func keysMapToCommands() {
        #expect(WindowKeyRouter.command(for: Key(character: "g", control: true)) == .jumpToNeedsYou)
        #expect(WindowKeyRouter.command(for: Key(character: "a", control: true)) == .decide(.allowOnce))
        #expect(WindowKeyRouter.command(for: Key(character: "A", control: true, shift: true)) == .decide(.alwaysAllow))
        #expect(WindowKeyRouter.command(for: Key(character: "d", control: true)) == .decide(.deny))
        #expect(WindowKeyRouter.command(for: Key(character: "1", control: true)) == .option(0))
        #expect(WindowKeyRouter.command(for: Key(character: "4", control: true)) == .option(3))
        #expect(WindowKeyRouter.command(for: Key(character: "\u{1B}")) == .escape)
        // Left alone: plain letters, ⌘ or ⌥ chords (⌘Q among them), ⌃5, ⌃⇧G.
        #expect(WindowKeyRouter.command(for: Key(character: "g")) == nil)
        #expect(WindowKeyRouter.command(for: Key(character: "q", command: true)) == nil)
        #expect(WindowKeyRouter.command(for: Key(character: "g", control: true, command: true)) == nil)
        #expect(WindowKeyRouter.command(for: Key(character: "a", control: true, option: true)) == nil)
        #expect(WindowKeyRouter.command(for: Key(character: "5", control: true)) == nil)
        #expect(WindowKeyRouter.command(for: Key(character: "G", control: true, shift: true)) == nil)
    }

    @Test
    func aFocusedFieldKeepsItsEditingKeys() {
        // ⌃G and ⌃1-⌃4 reach the router past a focused answer field; ⌃A, ⌃D and Esc stay the field's.
        #expect(WindowKeyRouter.takesWhileEditing(.jumpToNeedsYou))
        #expect(WindowKeyRouter.takesWhileEditing(.option(0)))
        #expect(!WindowKeyRouter.takesWhileEditing(.decide(.allowOnce)))
        #expect(!WindowKeyRouter.takesWhileEditing(.decide(.deny)))
        #expect(!WindowKeyRouter.takesWhileEditing(.escape))
    }

    /// Until `count` commands went and the card they answered went with them (sent first, resolved once sent: P129).
    private func settle(_ feed: FixtureSessionFeed, count: Int, gone id: String, in env: AppEnvironment) async {
        for _ in 0..<100 where feed.sentCommands.count < count || env.sessions.card(for: id) != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test
    func controlGJumpsToWhatNeedsYou() throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        #expect(WindowKeyRouter.perform(.jumpToNeedsYou, env: env))
        let model = try #require(env.sessions as? EngineSessionsModel)
        #expect(model.requestedJumps == [model.needsYou.first!.id])
        let empty = AppEnvironment.demo(sessions: .empty)
        #expect(!WindowKeyRouter.perform(.jumpToNeedsYou, env: empty))
    }

    @Test
    func controlAApprovesTheFirstApproval() async throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        let feed = try #require(env.fixtureFeed)
        #expect(WindowKeyRouter.perform(.decide(.alwaysAllow), env: env))
        await settle(feed, count: 1, gone: ID.approval, in: env)
        #expect(feed.sentCommands.count == 1)
        #expect(env.sessions.card(for: ID.approval) == nil)
        // Nothing left to approve: the key is not taken.
        #expect(!WindowKeyRouter.perform(.decide(.allowOnce), env: env))
    }

    /// ⌃1-⌃4 answer the question the keys rest on; with none selected, the first card of Needs you, which here is the
    /// approval: an option key takes nothing from it, and never passes it for the question below (P351).
    @Test
    func controlNumberAnswersTheSelectedQuestion() async throws {
        let env = AppEnvironment.demo(sessions: .prototype)
        let feed = try #require(env.fixtureFeed)
        #expect(!WindowKeyRouter.perform(.option(1), env: env) && feed.sentCommands.isEmpty)
        env.windowSelection = ID.question
        #expect(!WindowKeyRouter.perform(.option(4), env: env))   // four options only
        #expect(WindowKeyRouter.perform(.option(1), env: env))
        await settle(feed, count: 1, gone: ID.question, in: env)
        #expect(feed.sentCommands.count == 1)
        #expect(env.sessions.card(for: ID.question) == nil)
    }

    @Test
    func escapeLeavesNeedsYou() {
        let env = AppEnvironment.demo(sessions: .prototype)
        #expect(!WindowKeyRouter.perform(.escape, env: env))
        env.windowFilter = .needsYou
        #expect(WindowKeyRouter.perform(.escape, env: env))
        #expect(env.windowFilter == .all)
    }
}
