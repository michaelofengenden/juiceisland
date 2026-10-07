import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Settings › Desktop Panel › Widget background (P1401): Glass (the system's own, nothing of ours) until the owner picks
/// Black; it travels to both widgets in the App Group's snapshot, never through the environment, and a new choice
/// reloads both at once. Every store is a temporary folder or a temporary defaults suite.
@MainActor
@Suite(.serialized)
struct WidgetBackgroundTests {
    static let now = DemoClock.now

    /// Glass until set, with a store or without; a choice is kept; one this build does not know reads as Glass.
    @Test func theChoiceIsGlassUntilSetAndKept() throws {
        let suite = "widget-background-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppSettings.ephemeral().widgetBackground == .glass)
        let settings = AppSettings(defaults: defaults, identity: .development)
        #expect(settings.widgetBackground == .glass)
        settings.widgetBackground = .black
        #expect(AppSettings(defaults: defaults, identity: .development).widgetBackground == .black)
        defaults.set("frosted", forKey: "ji.widget.background")
        #expect(AppSettings(defaults: defaults, identity: .development).widgetBackground == .glass)
        #expect(WidgetBackgroundChoice.allCases == [.glass, .black] && WidgetBackgroundChoice.allCases.map(\.title) == ["Glass", "Black"])
    }

    /// The snapshot carries the choice, the closed one too; a file an older build wrote has none and reads as Glass.
    @Test func theSnapshotCarriesTheChoice() throws {
        let env = AppEnvironment.demo()
        #expect(WidgetSnapshot.make(env, at: Self.now).backgroundChoice == .glass)
        env.settings.widgetBackground = .black
        let snapshot = WidgetSnapshot.make(env, at: Self.now)
        #expect(snapshot.widgetBackground == "black" && snapshot.backgroundChoice == .black)
        #expect(WidgetSnapshot.closed(at: Self.now, background: .black).backgroundChoice == .black)
        #expect(WidgetSnapshot.closed(at: Self.now).backgroundChoice == .glass)
        var old = snapshot
        old.widgetBackground = nil
        let data = try JSONEncoder().encode(old)
        #expect(String(data: data, encoding: .utf8)?.contains("widgetBackground") == false)
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: data).backgroundChoice == .glass)
    }

    /// A new choice is what both widgets draw on: the feed writes it and reloads both kinds at once, inside their floors,
    /// as the owner looks for it; the snapshot it writes at quit keeps it.
    @Test func aNewChoiceReloadsBothWidgetsAtOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("widget-background-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetStore(directory: folder)
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: Self.now),
                                 sessions: DStub(rows: [DStub.row("run", .codex, .running)]))
        var clock = Self.now
        let reloads = ReloadCounter()
        let feed = WidgetFeed(env: env, store: store, clock: { clock }, reload: { reloads.bump($0) })
        feed.start()
        feed.drain()
        #expect(reloads.of(.usage) == 1 && reloads.of(.sessions) == 1)
        #expect(store.read()?.backgroundChoice == .glass)

        env.settings.widgetBackground = .black
        clock += 30
        feed.changed()
        feed.drain()
        #expect(reloads.of(.usage) == 2 && reloads.of(.sessions) == 2, "at once, well inside both floors")
        #expect(store.read()?.backgroundChoice == .black && !feed.reloadPending(.usage) && !feed.reloadPending(.sessions))
        #expect(!WidgetKind.usage.drawsSame(WidgetSnapshot.make(env, at: clock), {
            var glass = WidgetSnapshot.make(env, at: clock)
            glass.widgetBackground = "glass"
            return glass
        }()))
        feed.stop()
        #expect(store.read()?.appRunning == false && store.read()?.backgroundChoice == .black)
    }
}
