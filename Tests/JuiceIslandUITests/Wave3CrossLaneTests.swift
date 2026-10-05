import Foundation
@testable import IslandEngine
import JuiceCore
import OpenIslandCore
import Testing
@testable import JuiceIslandUI

/// Wave 3's settings where two lanes meet (P1076, P1077, P1079, P1080): Allow all over sessions a mute rule matches,
/// Juice's sounds and a chosen file under every quiet rule, and the two flavors' Diagnostics and Island panes. Fixture
/// engines and ephemeral settings only; nothing plays, nothing opens.
@MainActor
@Suite(.serialized)
struct Wave3CrossLaneTests {
    typealias ID = FixtureSessionFeed.ID

    /// A mute rule quiets a session; it never takes an answer away (P421). Allow all covers a muted session's approval as
    /// that card's own Yes does, a Tool rule's included, so its count is the Needs you line's (P1031, P1010, P1077).
    @Test func allowAllCoversMutedApprovalsAsTheirOwnYesDoes() async throws {
        let plain = AppEnvironment.demo(sessions: .cards)
        let env = AppEnvironment.demo(sessions: .cards)
        env.settings.muteRules = [MuteRule(field: .tool, text: "bash"), MuteRule(field: .title, text: "Write")]
        let muted = Set(env.sessions.waiting.filter { env.settings.muteRules.mutes($0) }.map(\.id))
        #expect(muted.contains(ID.longBash) && muted.contains(ID.unreadBash))

        let targets = BatchAnswer.targets(env)
        #expect(targets.map(\.sessionID) == BatchAnswer.targets(plain).map(\.sessionID))
        #expect(!muted.isDisjoint(with: targets.map(\.sessionID)))
        // The island's row on a muted card's own card counts the same five.
        let mutedCard = try #require(env.sessions.card(for: ID.longBash))
        #expect(BatchAnswer.islandTargets(drawn: mutedCard, env: env).count == targets.count)

        let feed = try #require(env.fixtureFeed)
        #expect(BatchAnswer.answer(.allowOnce, targets, env: env).text == "Allowed \(targets.count) approvals.")
        for _ in 0..<200 where feed.sentCommands.count < targets.count { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(feed.sentCommands.count == targets.count)
    }

    /// Juice's own sounds and a chosen file are silent under exactly the rules a macOS sound is: Mute, a mute rule, a lock
    /// with Quiet while locked, a mirrored screen with Quiet while presenting, a Focus that quiets, Quiet hours and a
    /// snooze (P1000, P1001, P1005, P1006, P1076). With none of them, each plays itself.
    @Test func everyQuietRuleSilencesJuiceSoundsAndChosenFilesAlike() throws {
        let folder = try AlertsLaneTests.Folder()
        let mine = try SoundFiles.adopt(try folder.wav("Mine.wav"), for: .needsYou, support: folder.support).get()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let night = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 23)))
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12)))

        for choice in [SoundChoice.system("Hero"), .juice(.tap), mine] {
            func sound(_ settings: AppSettings, muted: Bool = false, away: Bool = false, scene: QuietScene = .none,
                       now: Date = noon) -> String? {
                SignalSounds.sound(for: .needsYou(sessionID: "s"), isCodexAppThread: false, muted: muted, away: away, scene: scene,
                                   settings: settings, now: now, calendar: calendar, support: folder.support)
            }
            func settings(_ change: (AppSettings) -> Void = { _ in }) -> AppSettings {
                let settings = AppSettings.ephemeral()
                settings.needsYouSound = choice
                change(settings)
                return settings
            }
            #expect(sound(settings()) == choice.storageValue)
            #expect(sound(settings { $0.soundsMuted = true }) == nil)
            #expect(sound(settings(), muted: true) == nil)
            #expect(sound(settings { $0.quietWhileLocked = true }, away: true) == nil)
            #expect(sound(settings { $0.quietWhilePresenting = true }, scene: QuietScene(mirrored: true)) == nil)
            #expect(sound(settings(), scene: QuietScene(focus: true)) == nil)
            #expect(sound(settings { $0.quietHours = true }, now: night) == nil)
            #expect(sound(settings { $0.quietHours = true }, now: noon) == choice.storageValue)
            #expect(sound(settings { $0.snoozedUntil = noon.addingTimeInterval(600) }) == nil)
            // Each switch alone, without its scene, quiets nothing.
            #expect(sound(settings { $0.quietWhileLocked = true }) == choice.storageValue)
            #expect(sound(settings { $0.quietWhilePresenting = true }) == choice.storageValue)
        }
    }

    /// The public flavor shows Report a Bug and hides the motion A/B knobs (Island › Motion, Diagnostics › Motion), keeping
    /// Hover; the private flavor the opposite (P1060, P1065, P1080). The Focus line names each flavor's app (P1079).
    @Test func eachFlavorShowsTheOtherHalf() {
        let juice = PublicFlavorTests.publicFlavor
        #expect(DiagnosticsText.reportBugRepo(juice) != nil)
        #expect(!DiagnosticsText.showsMotionTools(juice) && !IslandPaneText.showsMotionRow(reduceMotion: false, flavor: juice))
        #expect(DiagnosticsText.reportBugRepo(.private) == nil)
        #expect(DiagnosticsText.showsMotionTools(.private) && IslandPaneText.showsMotionRow(reduceMotion: false, flavor: .private))
        // The Focus line names the app as each flavor is listed in System Settings.
        #expect(IslandPaneText.focus(quietNow: false, product: juice.productName) == "Add Juice as a filter in System Settings › Focus.")
        #expect(IslandPaneText.focus(quietNow: false, product: AppFlavor.private.productName)
            == "Add Juice Island as a filter in System Settings › Focus.")
    }
}
