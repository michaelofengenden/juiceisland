import AppKit
import Foundation
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The desktop widget (spec §4.7, P340 to P347): the snapshot the app writes, the file it goes to, the links, the reload
/// policy, the feed that follows the app's models, and the timeline. Nothing here touches the real App Group container:
/// every store is a temporary folder, and `WidgetFeed.app` is given its own.
@MainActor
@Suite(.serialized)
struct WidgetTests {
    static let now = DemoClock.now

    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("widget-tests-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: The snapshot

    @Test func snapshotLeadsWithWhatNeedsYouThenWhatRunsAndLeavesTheRestOut() {
        let env = AppEnvironment.demo(sessions: .allStates)
        let snapshot = WidgetSnapshot.make(env, at: Self.now)
        let expected = env.sessions.rows.filter { $0.tells && ($0.bucket == .needsYou || $0.bucket == .running) }
        #expect(!expected.isEmpty)
        #expect(snapshot.appRunning)
        #expect(snapshot.rows.map(\.id) == Array(expected.prefix(WidgetSnapshot.rowLimit)).map(\.id))
        #expect(snapshot.more == max(0, expected.count - WidgetSnapshot.rowLimit))
        // Needs you first, in the engine's order.
        let kinds = snapshot.rows.map(\.kind)
        #expect(kinds == kinds.sorted { $0 == .needsYou && $1 == .running })
        #expect(kinds.contains(.needsYou) && kinds.contains(.running))
        // No finished session.
        #expect(!snapshot.rows.contains { id in env.sessions.done.contains { $0.id == id.id } })
    }

    @Test func aRowThatNeedsYouSaysWhatItsCardSaysAndARunningRowSaysNothing() {
        for scenario: FixtureSessionFeed.Scenario in [.allStates, .attention, .agents, .look] {
            let env = AppEnvironment.demo(sessions: scenario)
            let snapshot = WidgetSnapshot.make(env, at: Self.now)
            for row in snapshot.rows {
                let source = env.sessions.row(id: row.id)!
                #expect(row.title == WidgetSnapshot.title(source))
                #expect(row.glyph == source.glyph.rawValue)
                switch row.kind {
                case .needsYou:
                    let status = env.card(for: row.id).map { CardText.status(WidgetSnapshot.withoutSessionText($0), host: source.host) }
                    #expect(row.word != nil)
                    #expect(row.word == (status?.word ?? SessionRowText.cleanStatus(source).word))
                    #expect(row.detail == status?.text)
                case .running:
                    #expect(row.word == nil && row.detail == nil)
                }
            }
        }
        let snapshot = WidgetSnapshot.make(.demo(sessions: .allStates), at: Self.now)
        let approval = snapshot.rows.first { $0.id == FixtureSessionFeed.ID.approval }
        #expect(approval?.word == "Needs approval")
        #expect(approval?.detail == "Bash")
        #expect(snapshot.rows.first { $0.id == FixtureSessionFeed.ID.question }?.word == "Question")
    }

    /// No command, question, message, prompt or path reaches the file: only folder names and the cards' status lines
    /// (P200, P341).
    @Test func theFileCarriesNoCommandPromptOrMessage() throws {
        for scenario: FixtureSessionFeed.Scenario in [.allStates, .attention, .cards, .owner, .codexApproval] {
            let env = AppEnvironment.demo(sessions: scenario)
            let folder = Self.folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = WidgetStore(directory: folder)
            let snapshot = WidgetSnapshot.make(env, at: Self.now)
            try store.write(snapshot)
            let text = try String(contentsOf: store.file, encoding: .utf8)
            // What a row shows may repeat a failure's kind ("Rate limited") or a folder's name.
            let shown = snapshot.rows.flatMap { [$0.title, $0.word, $0.detail].compactMap { $0 } }
            for row in env.sessions.rows {
                for secret in [row.detail, row.lastPrompt].compactMap({ $0 }) where secret.count > 6 {
                    guard !shown.contains(where: { $0.contains(secret) }) else { continue }
                    #expect(!text.contains(secret), "\(scenario): \(secret)")
                }
            }
            // Every approval's command and every question's text stays out.
            for row in env.sessions.rows {
                switch env.card(for: row.id) {
                case let .approval(card):
                    if case let .command(command) = card.body, command.count > 6 { #expect(!text.contains(command), "\(command)") }
                case let .question(card):
                    #expect(!text.contains(card.question), "\(card.question)")
                default: break
                }
            }
            #expect(!text.contains(NSHomeDirectory()))
            #expect(!text.contains("@"))
        }
    }

    /// A title the owner's prompt or the agent's transcript gave never reaches the file (P200): a row there is its
    /// project folder, or with none the agent's name, unless the repo already titles it. A question's topic, the agent's
    /// own words, stays out too; the approval's tool and the step stay.
    @Test func theFileKeepsNoTitleOrTopicFromASession() throws {
        var named = DStub.row("named", .codex, .needsYou, project: "field-notes", task: "Draft the release notes for 3.2")
        named.titleSource = .agent
        var prompted = DStub.row("prompted", .claude, .running, task: "Rotate the staging DB password and fix the deploy script")
        prompted.titleSource = .prompt
        var bare = DStub.row("bare", .claude, .running, project: "", task: "Summarise the outage for the team")
        bare.titleSource = .agent
        var repo = DStub.row("repo", .claude, .running, project: "notes-site", task: "notes-site")
        repo.titleSource = .repo
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: Self.now),
                                 sessions: DStub(rows: [named, prompted, bare, repo]))
        let snapshot = WidgetSnapshot.make(env, at: Self.now)
        let titles = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.id, $0.title) })
        #expect(titles == ["named": "field-notes", "prompted": "juice-island", "bare": "Claude", "repo": "notes-site"])
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetStore(directory: folder)
        try store.write(snapshot)
        let text = try String(contentsOf: store.file, encoding: .utf8)
        for secret in ["Draft the release", "Rotate the staging", "Summarise the outage"] { #expect(!text.contains(secret), "\(secret)") }

        for scenario: FixtureSessionFeed.Scenario in [.allStates, .attention, .cards, .owner, .agents] {
            let env = AppEnvironment.demo(sessions: scenario)
            let snapshot = WidgetSnapshot.make(env, at: Self.now)
            try store.write(snapshot)
            let text = try String(contentsOf: store.file, encoding: .utf8)
            for row in env.sessions.rows where row.titleSource != .repo && row.task.count > 6 && row.task != row.project {
                #expect(!text.contains(row.task), "\(scenario): \(row.task)")
            }
            for row in env.sessions.rows {
                guard case let .question(card) = env.card(for: row.id) else { continue }
                for topic in ([card.topic] + card.shown.map(\.topic)).compactMap({ $0 }) where topic.count > 3 {
                    #expect(!text.contains(topic), "\(scenario): \(topic)")
                }
            }
        }
    }

    /// The small and medium faces draw each battery state as its own shape: used up (quota gone) and unknown (not read)
    /// are never the same empty outline.
    @Test func miniBatteriesDrawUsedUpAndUnknownApart() throws {
        func pixels(_ state: WidgetSnapshot.Battery.State, tinted: Bool) throws -> [UInt8] {
            let renderer = ImageRenderer(content: MiniBattery(battery: .init(state: state, isNext: false), tinted: tinted)
                .background(Color.black).environment(\.colorScheme, .dark))
            renderer.scale = 4
            let image = try #require(renderer.cgImage)
            let rep = NSBitmapImageRep(cgImage: image)
            return (0..<rep.pixelsHigh).flatMap { y in
                (0..<rep.pixelsWide).map { x in UInt8(((rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray)?.whiteComponent ?? 0) * 255).rounded()) }
            }
        }
        for tinted in [false, true] {
            let states: [WidgetSnapshot.Battery.State] = [.usedUp(refill: nil), .unknown, .signIn, .stale(last: nil)]
            let drawn = try states.map { try pixels($0, tinted: tinted) }
            #expect(drawn[0] != drawn[1], "tinted \(tinted): used up and unknown")
            #expect(drawn[1] != drawn[2], "tinted \(tinted): unknown and sign in")
            #expect(drawn[1] != drawn[3], "tinted \(tinted): unknown and stale")
        }
    }

    /// With nothing running or waiting the widget says so, never "No sessions" beside an island that lists the finished.
    @Test func withNothingRunningTheWidgetSaysSo() {
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: Self.now),
                                 sessions: DStub(rows: [DStub.row("d", .claude, .done)]))
        #expect(WidgetSnapshot.make(env, at: Self.now).rows.isEmpty && !env.sessions.rows.isEmpty)
        #expect(IslandWidgetView.idleText == "Nothing running")
    }

    @Test func aQuietRowShowsOnlyWhileItsCardWaits() {
        var scripted = DStub.row("scripted", .codex, .running)
        scripted.isQuiet = true
        var asking = DStub.row("asking", .claude, .needsYou)
        asking.isQuiet = true
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: Self.now),
                                 sessions: DStub(rows: [asking, DStub.row("mine", .claude, .running), scripted]))
        #expect(WidgetSnapshot.make(env, at: Self.now).rows.map(\.id) == ["asking", "mine"])
    }

    @Test func batteriesAreThePanelsWithoutNames() throws {
        let env = AppEnvironment.demo(sessions: .allStates)
        let snapshot = WidgetSnapshot.make(env, at: Self.now)
        let claude = try #require(env.usage.claudeRow).batteries
        let codex = try #require(env.usage.codexRow).batteries
        #expect(snapshot.claude == claude.map(WidgetSnapshot.Battery.init))
        #expect(snapshot.codex == codex.map(WidgetSnapshot.Battery.init))
        for (index, battery) in claude.enumerated() {
            #expect(snapshot.claude[index].model(index, provider: .claude).state == battery.state)
        }
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetStore(directory: folder)
        try store.write(snapshot)
        let text = try String(contentsOf: store.file, encoding: .utf8)
        for battery in claude + codex where battery.alias.count > 2 { #expect(!text.contains("\"\(battery.alias)\"")) }
    }

    @Test func theGlyphSettingsTravel() {
        let settings = AppSettings.ephemeral()
        settings.glyphStyle = .sand
        settings.glyphColour = .byAgent
        let snapshot = WidgetSnapshot.make(.demo(settings: settings, sessions: .allStates), at: Self.now)
        #expect(snapshot.glyphStyle == "sand" && snapshot.glyphColour == "byAgent")
        // Liquid's running look travels too, so a Full owner's widget draws the full body (P385).
        settings.glyphStyle = .liquid
        settings.liquidRunning = .full
        let liquid = WidgetSnapshot.make(.demo(settings: settings, sessions: .allStates), at: Self.now)
        #expect(liquid.liquidRunning == "full" && liquid.runningLook == .full)
    }

    /// A file an older build wrote has no running look: the widget reads it as Slim, the default.
    @Test func aFileWithNoRunningLookReadsAsSlim() throws {
        var snapshot = WidgetSnapshot.make(.demo(sessions: .attention), at: Self.now)
        snapshot.liquidRunning = nil
        let data = try JSONEncoder().encode(snapshot)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("liquidRunning"))
        let read = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(read.liquidRunning == nil && read.runningLook == .slim)
    }

    // MARK: The file

    @Test func theStoreRoundTripsAndRefusesWhatItCannotRead() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetStore(directory: folder)
        #expect(store.read() == nil)
        let snapshot = WidgetSnapshot.make(.demo(sessions: .attention), at: Self.now)
        try store.write(snapshot)
        #expect(store.read() == snapshot)
        try store.write(.closed(at: Self.now))
        #expect(store.read()?.appRunning == false)
        try Data("{".utf8).write(to: store.file)
        #expect(store.read() == nil)
        var future = snapshot
        future.version = WidgetSnapshot.currentVersion + 1
        try store.write(future)
        #expect(store.read() == nil)
    }

    // MARK: Links

    @Test func linksRoundTripInTheBuildsOwnScheme() {
        let scheme = "com.ofengenden.juice.dev"
        for id in ["demo-approval", "019e3c1f-7a2b-7c1d-9a8e-0b1c2d3e4f50", "thread/with slash", "ünï code", "a:b@c?d#e"] {
            let url = WidgetLink.session(id).url(scheme: scheme)
            #expect(url != nil, "\(id)")
            #expect(url.flatMap { WidgetLink(url: $0, scheme: scheme) } == .session(id), "\(id)")
        }
        #expect(WidgetLink.open.url(scheme: scheme)?.absoluteString == "com.ofengenden.juice.dev://open")
        #expect(WidgetLink(url: URL(string: "COM.OFENGENDEN.JUICE.DEV://open")!, scheme: scheme) == .open)
        // The release build never answers a dev build's link, nor standalone Juice's (P345).
        #expect(WidgetLink(url: WidgetLink.open.url(scheme: scheme)!, scheme: "com.ofengenden.juice") == nil)
        #expect(WidgetLink(url: URL(string: "juice://open")!, scheme: "com.ofengenden.juice") == nil)
        for bad in ["com.ofengenden.juice.dev://session", "com.ofengenden.juice.dev://session/", "com.ofengenden.juice.dev://session/a/b",
                    "com.ofengenden.juice.dev://approve/demo-approval", "com.ofengenden.juice.dev://open/extra",
                    "com.ofengenden.juice.dev://session/" + String(repeating: "x", count: WidgetLink.idLimit + 1)] {
            #expect(WidgetLink(url: URL(string: bad)!, scheme: scheme) == nil, "\(bad)")
        }
        #expect(WidgetLink.session("").url(scheme: scheme) == nil)
    }

    // MARK: Identity

    @Test func identityComesFromTheBundleAndOnlyTheGroupsTeamWrites() {
        let identity = WidgetIdentity(info: ["JIAppGroup": "TEAMID0000.com.ofengenden.juice", "JIURLScheme": "com.ofengenden.juice"])
        #expect(identity == WidgetIdentity(appGroup: "TEAMID0000.com.ofengenden.juice", scheme: "com.ofengenden.juice"))
        #expect(identity?.team == "TEAMID0000")
        #expect(WidgetIdentity(info: nil) == nil)
        #expect(WidgetIdentity(info: ["JIAppGroup": "$(JI_APP_GROUP)", "JIURLScheme": "x"]) == nil)
        #expect(WidgetIdentity(info: ["JIAppGroup": "TEAMID0000.x"]) == nil)
        // The test bundle has neither key.
        #expect(WidgetIdentity.main == nil)
        #expect(identity?.allows(signingTeam: "TEAMID0000") == true)
        #expect(identity?.allows(signingTeam: nil) == false)
        #expect(identity?.allows(signingTeam: "ABCDE12345") == false)
    }

    /// An ad hoc build (every dev build) never asks for the container, so macOS never prompts (P342).
    @Test func onlyABuildSignedByTheGroupsTeamFeedsTheWidget() throws {
        let env = AppEnvironment.demo(sessions: .allStates)
        let identity = WidgetIdentity(appGroup: "TEAMID0000.com.ofengenden.juice.dev", scheme: "com.ofengenden.juice.dev")
        var asked: [String] = []
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store: (String) -> WidgetStore? = { group in
            asked.append(group)
            return WidgetStore(directory: folder)
        }
        #expect(WidgetFeed.app(env: env, identity: nil, team: "TEAMID0000", store: store, reload: {}) == nil)
        #expect(WidgetFeed.app(env: env, identity: identity, team: nil, store: store, reload: {}) == nil)
        #expect(WidgetFeed.app(env: env, identity: identity, team: "ABCDE12345", store: store, reload: {}) == nil)
        #expect(asked.isEmpty)
        #expect(WidgetFeed.app(env: env, identity: identity, team: "TEAMID0000", store: store, reload: {}) != nil)
        #expect(asked == ["TEAMID0000.com.ofengenden.juice.dev"])
    }

    // MARK: Reloads

    @Test func theReloadPolicyReloadsAtOnceForWhatNeedsYouAndOtherwiseEveryFiveMinutesAtMost() {
        var policy = WidgetReloadPolicy()
        let base = WidgetSnapshot.make(.demo(sessions: .allStates), at: Self.now)
        #expect(policy.decide(base, at: Self.now) == .now)
        policy.reloaded(base, at: Self.now)
        // A title, a turn, a percent: the floor.
        var soft = base
        soft.rows[soft.rows.count - 1].title = "Renamed"
        #expect(policy.decide(soft, at: Self.now + 60) == .at(Self.now + WidgetReloadPolicy.floor))
        #expect(policy.decide(soft, at: Self.now + WidgetReloadPolicy.floor) == .now)
        var percent = base
        percent.claude[0].state = .available(left: 50, low: false)
        #expect(policy.decide(percent, at: Self.now + 1) == .at(Self.now + WidgetReloadPolicy.floor))
        // A request that comes, goes or changes, a battery's kind, the app quitting: at once.
        var gone = base
        gone.rows.removeAll { $0.kind == .needsYou }
        #expect(policy.decide(gone, at: Self.now + 1) == .now)
        var changedWord = base
        let first = changedWord.rows.firstIndex { $0.kind == .needsYou }!
        changedWord.rows[first].detail = "Edit"
        #expect(policy.decide(changedWord, at: Self.now + 1) == .now)
        var low = base
        low.claude[0].state = .available(left: 9, low: true)
        #expect(policy.decide(low, at: Self.now + 1) == .now)
        var closed = base
        closed.appRunning = false
        #expect(policy.decide(closed, at: Self.now + 1) == .now)
    }

    @Test func theFeedWritesWhatChangedAndReloadsByThePolicy() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetStore(directory: folder)
        let stub = DStub(rows: [DStub.row("ask", .claude, .needsYou), DStub.row("run", .codex, .running)])
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: Self.now), sessions: stub)
        var clock = Self.now
        let reloads = ReloadCounter()
        let feed = WidgetFeed(env: env, store: store, clock: { clock }, reload: { reloads.bump() })

        feed.start()
        feed.drain()
        #expect(reloads.count == 1)
        #expect(store.read()?.rows.map(\.id) == ["ask", "run"])

        // The running row's tool moves on: nothing the widget draws changed, so nothing is written.
        let written = try FileManager.default.attributesOfItem(atPath: store.file.path)[.modificationDate] as? Date
        stub.rows[1].status = .tool(name: "Read", detail: "README.md")
        clock += 10
        feed.changed()
        feed.drain()
        #expect(reloads.count == 1)
        #expect(try FileManager.default.attributesOfItem(atPath: store.file.path)[.modificationDate] as? Date == written)

        // Another session starts a turn: written at once, reloaded after the floor.
        stub.rows.append(DStub.row("run2", .claude, .running))
        clock += 10
        feed.changed()
        feed.drain()
        #expect(store.read()?.rows.map(\.id) == ["ask", "run", "run2"])
        #expect(reloads.count == 1)
        #expect(feed.reloadPending)

        // A request is answered: at once, and the waiting reload is no longer needed.
        stub.rows.removeFirst()
        clock += 10
        feed.changed()
        feed.drain()
        #expect(reloads.count == 2)
        #expect(!feed.reloadPending)
        #expect(store.read()?.rows.map(\.id) == ["run", "run2"])

        // Quit: the closed snapshot is on disk when `stop` returns.
        feed.stop()
        #expect(reloads.count == 3)
        #expect(store.read()?.appRunning == false)
        #expect(store.read()?.rows.isEmpty == true)
    }

    @Test func theFeedFollowsTheModelsByItself() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetStore(directory: folder)
        let stub = DStub(rows: [DStub.row("run", .codex, .running)])
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: Self.now), sessions: stub)
        let feed = WidgetFeed(env: env, store: store, reload: {})
        feed.start()
        stub.rows.insert(DStub.row("ask", .claude, .needsYou, glyph: .ques), at: 0)
        for _ in 0..<100 where feed.last?.rows.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(feed.last?.rows.map(\.id) == ["ask", "run"])
        env.settings.glyphStyle = .liquid
        for _ in 0..<100 where feed.last?.glyphStyle != "liquid" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(feed.last?.glyphStyle == "liquid")
        feed.stop()
    }

    // MARK: The widget's side

    @Test func theTimelineIsNowAndEachRefillAhead() {
        var snapshot = WidgetSnapshot.preview(at: Self.now)
        snapshot.codex[1].state = .usedUp(refill: Self.now + 600)
        snapshot.codex[2].state = .usedUp(refill: Self.now - 600)
        snapshot.claude[4].state = .usedUp(refill: Self.now + 600)
        let timeline = IslandWidgetProvider.timeline(snapshot, scheme: "s", now: Self.now)
        #expect(timeline.entries.map(\.date) == [Self.now, Self.now + 600, Self.now + 4_500])
        #expect(timeline.entries.allSatisfy { $0.snapshot == snapshot && $0.scheme == "s" })
        #expect(IslandWidgetProvider.timeline(nil, scheme: nil, now: Self.now).entries.map(\.date) == [Self.now])
    }

    @Test func theSmallFaceOpensItsFirstRowAndTheOthersTheIsland() {
        let snapshot = WidgetSnapshot.preview(at: Self.now)
        #expect(IslandWidgetEntryView.tapLink(snapshot, face: .small) == .session("preview-approval"))
        #expect(IslandWidgetEntryView.tapLink(snapshot, face: .medium) == .open)
        #expect(IslandWidgetEntryView.tapLink(.closed(at: Self.now), face: .small) == .open)
        #expect(IslandWidgetEntryView.tapLink(nil, face: .small) == .open)
    }

    /// The faces at macOS's desktop sizes less a 14 pt margin: what fits, and that nothing ever runs past the content.
    @Test func eachFaceFitsWhatItCanAndCountsTheRest() {
        let preview = WidgetSnapshot.preview(at: Self.now)
        let small = CGSize(width: 142, height: 142), medium = CGSize(width: 336, height: 142), large = CGSize(width: 336, height: 354)
        #expect(WidgetLayout.make(preview, face: .small, size: small) == WidgetLayout(rows: 3, hidden: 1, batteries: .mini(oneLine: false)))
        #expect(WidgetLayout.make(preview, face: .medium, size: medium) == WidgetLayout(rows: 4, hidden: 0, batteries: .mini(oneLine: true)))
        #expect(WidgetLayout.make(preview, face: .large, size: large) == WidgetLayout(rows: 4, hidden: 0, batteries: .full(scale: 1)))
        // Three requests in the medium face, the rest counted.
        let attention = WidgetSnapshot.make(.demo(sessions: .attention), at: Self.now)
        #expect(WidgetLayout.make(attention, face: .medium, size: medium).rows == 3)
        // A narrower large face shrinks the batteries rather than cutting one.
        if case let .full(scale) = WidgetLayout.make(preview, face: .large, size: CGSize(width: 307, height: 323)).batteries {
            #expect(scale < 1 && scale > 0.9)
        } else {
            Issue.record("the large face draws the panel's batteries")
        }
        // No batteries (no accounts): the rows take the room.
        var bare = preview
        bare.claude = []
        bare.codex = []
        #expect(WidgetLayout.make(bare, face: .small, size: small).batteries == WidgetLayout.Batteries.none)
        #expect(WidgetLayout.make(bare, face: .small, size: small).rows == 4)
        // Any mix of rows: what is shown, the gaps, "N more" and the batteries never pass the content's height.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var snapshot = preview
            snapshot.rows = (0..<Int.random(in: 0...12, using: &generator)).map { index in
                let asks = Bool.random(using: &generator)
                return WidgetSnapshot.Row(id: "r\(index)", agent: "claude", kind: asks ? .needsYou : .running, title: "T",
                                          glyph: asks ? "bang" : "eq", word: asks ? "Question" : nil)
            }
            snapshot.more = Int.random(in: 0...3, using: &generator)
            for face in WidgetFace.allCases {
                let size = [small, medium, large][WidgetFace.allCases.firstIndex(of: face)!]
                let layout = WidgetLayout.make(snapshot, face: face, size: size)
                let rows = snapshot.rows.prefix(layout.rows)
                let rowsHeight = rows.map(WidgetMetrics.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * WidgetMetrics.rowGap
                let batteries: CGFloat = switch layout.batteries {
                case .none: 0
                case let .mini(oneLine): (oneLine ? MiniBatteryRow.height : 2 * MiniBatteryRow.height + WidgetMetrics.miniRowGap) + WidgetMetrics.batteryGap
                case let .full(scale): WidgetBatteryBlock.height(2) * scale + WidgetMetrics.batteryGap
                }
                #expect(rowsHeight + (layout.hidden > 0 ? WidgetMetrics.moreHeight : 0) + batteries <= size.height)
                #expect(layout.rows + layout.hidden == snapshot.rows.count + snapshot.more)
            }
        }
    }

    /// The tap made Juice Island the app in front: its own activation keeps the island it opened, another app's folds it
    /// (P270, P343).
    @Test func theIslandAWidgetOpenedFoldsOnlyWhenTheOwnerGoesElsewhere() {
        let own = ProcessInfo.processInfo.processIdentifier
        #expect(!IslandFocus.ownerLeft(.appActivated(own), frontAtOpen: own))
        #expect(IslandFocus.ownerLeft(.appActivated(own &+ 1), frontAtOpen: own))
        #expect(IslandFocus.ownerLeft(.panelResignedKey, frontAtOpen: own))
    }

    @Test func anAgentThisBuildDoesNotKnowKeepsItsRowWithoutAMark() {
        #expect(WidgetRowView.agent("claude") == .claude)
        #expect(WidgetRowView.agent("codex") == .codex)
        #expect(WidgetRowView.agent("geminiCLI") == .other(.geminiCLI))
        #expect(WidgetRowView.agent("someNewAgent") == nil)
        for agent: GlyphPalette.Agent in [.claude, .codex, .other(.qwenCode)] {
            #expect(WidgetRowView.agent(WidgetSnapshot.agentKey(agent)) == agent)
        }
    }
}

/// Counts reloads from the feed's queue.
final class ReloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}
