import Foundation
import ServiceManagement
import Testing
@testable import IslandEngine
import IslandHookNotes
import JuiceCore
@testable import JuiceIslandUI

/// The first run (P950 to P974): when the welcome shows by itself, that nothing is written before Connect and Connect
/// writes only the ticked lines, Launch at Login registered only as Pick a look is left, Vibe Island's and Open Island's
/// cards, Start and the first real session, the "new agents" line, Hello's demo and Demo sessions. Fixture Macs, fake
/// services and temporary homes only: no file of this Mac's is read or written, no app is asked to quit, no terminal
/// opens.
@MainActor
struct WelcomeTests {
    private func settle(_ done: () -> Bool) async {
        for _ in 0..<400 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func fixture(_ step: WelcomeModel.Step = .hello, mac: WelcomeModel.FixtureMac = .fresh, openIsland: Bool = false,
                         notch: Bool = true) -> (WelcomeModel, WelcomeFixtureHooks, WelcomeFixtureAgents, FixtureWelcomeServices) {
        let env = AppEnvironment.demo(sessions: .empty)
        let model = WelcomeModel.fixture(step: step, env: env, mac: mac, openIslandRunning: openIsland, hasNotch: notch)
        // swiftlint:disable:next force_cast
        return (model, env.hooks as! WelcomeFixtureHooks, env.agentsPane.sources[0] as! WelcomeFixtureAgents,
                model.services as! FixtureWelcomeServices)
    }

    private static func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ji-welcome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    // MARK: When it shows (P950, P951)

    @Test
    func theWelcomeShowsByItselfOnlyOnAStrangersMac() {
        #expect(WelcomeGate.showsByItself(earlierLaunch: false, juiceHooks: false))
        #expect(!WelcomeGate.showsByItself(earlierLaunch: true, juiceHooks: false))
        #expect(!WelcomeGate.showsByItself(earlierLaunch: false, juiceHooks: true))
        #expect(!WelcomeGate.showsByItself(earlierLaunch: true, juiceHooks: true))
    }

    /// The owner's Mac: either flavor's helper in its home, or a Claude or Codex hook file naming `JuiceHooks`. Vibe
    /// Island's or Open Island's hooks alone are a stranger's.
    @Test
    func juiceHooksAreSeenFromEitherFlavorsHelperOrAHookFile() throws {
        let fileManager = FileManager.default
        let home = try Self.temporaryHome()
        defer { try? fileManager.removeItem(at: home) }
        #expect(!WelcomeGate.juiceHooksPresent(home: home.path, publicFolder: "org.example.juice"))
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        try fileManager.createDirectory(at: claude, withIntermediateDirectories: true)
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/sh -c '$HOME/.vibe-island/bin/vibe-island-bridge --source claude'"}]}]}}"#.utf8)
            .write(to: claude.appendingPathComponent("settings.json"))
        #expect(!WelcomeGate.juiceHooksPresent(home: home.path, publicFolder: "org.example.juice"))
        let codex = home.appendingPathComponent(".codex-side", isDirectory: true)
        try fileManager.createDirectory(at: codex, withIntermediateDirectories: true)
        try Data().write(to: codex.appendingPathComponent("config.toml"))
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"'/x/Library/Application Support/Juice Island/bin/JuiceHooks'"}]}]}}"#.utf8)
            .write(to: codex.appendingPathComponent("hooks.json"))
        #expect(WelcomeGate.juiceHooksPresent(home: home.path, publicFolder: "org.example.juice"))
        try fileManager.removeItem(at: codex)
        // The public flavor's helper, from a Mac that ran the public Juice.
        let helper = HookHome(supportFolderNamed: "org.example.juice", home: home.path).helperURL
        try fileManager.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        #expect(WelcomeGate.juiceHooksPresent(home: home.path, publicFolder: "org.example.juice"))
    }

    /// An earlier launch is the welcome's mark or any setting of ours; a new Mac has neither.
    @Test
    func anEarlierLaunchIsAnySettingOfOurs() throws {
        let name = "ji-welcome-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!AppSettings.hasEarlierLaunch(defaults, domain: name))
        defaults.setPersistentDomain(["other.key": true], forName: name)
        #expect(!AppSettings.hasEarlierLaunch(defaults, domain: name))
        defaults.setPersistentDomain(["ji.island.theme": "glass"], forName: name)
        #expect(AppSettings.hasEarlierLaunch(defaults, domain: name))
        defaults.removePersistentDomain(forName: name)
        defaults.set(true, forKey: AppSettings.Key.welcomeSeen)
        #expect(AppSettings.hasEarlierLaunch(defaults, domain: name))
        #expect(!AppSettings.hasEarlierLaunch(nil))
    }

    // MARK: Connect (P952 to P954)

    /// Walking Hello and Agents writes nothing; Connect writes every ticked folder in one run (one after another) and
    /// each ticked agent, and the button says Next from then on.
    @Test
    func nothingIsWrittenBeforeConnectAndConnectWritesTheTickedLines() async {
        let (model, hooks, agents, _) = fixture()
        model.advance()
        #expect(model.step == .agents)
        #expect(hooks.runs.isEmpty && agents.performed.isEmpty && hooks.openCodeClicks == 0)
        #expect(WelcomeText.agentsButton(model).hasPrefix(WelcomeText.connect))
        model.primary()
        #expect(model.step == .agents)
        #expect(hooks.runs.count == 1)
        #expect(hooks.runs.first?.0 == .install)
        #expect(hooks.runs.first?.1 == ["claude:~/.claude", "claude:~/.claude-work", "codex:~/.codex"])
        #expect(hooks.openCodeClicks == 1)
        #expect(agents.performed.map(\.1) == ["copilot", "cursor"] && agents.performed.allSatisfy { $0.0 == .connect })
        #expect(WelcomeText.agentsButton(model) == "Next")
        model.primary()
        #expect(model.step == .look)
        #expect(hooks.runs.count == 1)
    }

    @Test
    func anUntickedLineIsLeftOutAndAParentTicksItsFolders() {
        let (model, hooks, agents, _) = fixture(.agents)
        model.toggle("claude")
        #expect(model.lines.first { $0.id == "claude" }?.state == .tick(false))
        #expect(model.lines.first { $0.id == "claude:~/.claude-work" }?.state == .tick(false))
        model.toggle("claude:~/.claude")
        #expect(model.lines.first { $0.id == "claude" }?.state == .tick(false))
        model.toggle("cursor")
        model.connect()
        #expect(hooks.runs.first?.1 == ["claude:~/.claude", "codex:~/.codex"])
        #expect(agents.performed.map(\.1) == ["copilot"])
        // Every line off: the button moves on and writes nothing.
        let (empty, emptyHooks, _, _) = fixture(.agents, mac: .connected)
        #expect(WelcomeText.agentsButton(empty) == "Next")
        empty.primary()
        #expect(empty.step == .look && emptyHooks.runs.isEmpty)
    }

    /// The "i": the files Connect writes for the ticked lines, and the helper; nothing for an unticked line.
    @Test
    func theFilesAreWhatConnectWrites() {
        let (model, _, _, _) = fixture(.agents)
        model.toggle("cursor")
        #expect(model.files.prefix(5) == ["~/.claude/settings.json", "~/.claude-work/settings.json", "~/.codex/hooks.json", "~/.codex/config.toml",
                                          "~/.config/opencode/plugins/" + OpenCodePlugin.fileName])
        #expect(model.files.contains("~/.copilot/hooks/juice-island.json") && !model.files.contains("~/.cursor/hooks.json"))
        #expect(model.files.last?.hasSuffix("/bin/JuiceHooks") == true)
    }

    /// After Connect: Codex asks once (Copy /hooks), a file Juice will not edit is Add by hand with the exact lines.
    @Test
    func trustAndAddByHandSayWhatToDo() {
        let (model, _, _, _) = fixture(.agents, mac: .connected)
        #expect(model.lines.first { $0.id == "codex:~/.codex" }?.state == .trust)
        #expect(model.lines.first { $0.id == "claude" }?.state == .connected)
        let env = AppEnvironment.demo(sessions: .empty)
        let row = HookSetupRow(id: "claude:~/.claude-lab", provider: .claude, alias: "Lab", folder: "~/.claude-lab", word: "Has comments",
                               detail: nil, tone: .amber, action: nil, refusal: "Edit settings.json by hand", busy: false, events: "",
                               isMonitored: true, state: .hasComments(file: "settings.json"))
        let lab = WelcomeModel(env: env, services: FixtureWelcomeServices()).state(of: row)
        guard case let .addByHand(file, snippet, _) = lab else { Issue.record("not Add by hand: \(lab)"); return }
        #expect(file == "settings.json" && snippet.contains("JuiceHooks") && snippet.hasPrefix("\"hooks\""))
    }

    // MARK: Other islands (P955 to P958)

    /// Vibe Island's agents wait on its card; Connect leaves them; Switch to Juice takes its entries out, reads again
    /// and connects ours; Keep Vibe Island leaves them for good.
    @Test
    func vibeIslandsAgentsWaitOnItsCard() async {
        let (model, hooks, agents, services) = fixture(.agents, mac: .vibeIsland)
        #expect(model.showsVibeCard)
        #expect(WelcomeText.vibeCard(agents: model.vibeAgents.count) == "Vibe Island is connected to 4 agents.")
        #expect(["claude:~/.claude", "codex:~/.codex", "opencode", "cursor"].allSatisfy { id in model.lines.first { $0.id == id }?.state == .vibe })
        model.connect()
        #expect(hooks.runs.first?.1 == ["claude:~/.claude-work"])
        #expect(agents.performed.map(\.1) == ["copilot"])
        #expect(hooks.openCodeClicks == 0)

        let (switching, switchedHooks, _, switchedServices) = fixture(.agents, mac: .vibeIsland)
        switching.switchToJuice()
        #expect(switching.vibeChoice == .switching)
        await settle { switching.vibeChoice == .switched }
        #expect(switchedServices.calls.first == "switch 4")
        #expect(!switching.showsVibeCard)
        #expect(switchedHooks.runs.last?.0 == .install)
        #expect(services.calls.isEmpty)

        let (keeping, _, _, keptServices) = fixture(.agents, mac: .vibeIsland)
        keeping.keepVibeIsland()
        #expect(!keeping.showsVibeCard)
        #expect(keeping.lines.first { $0.id == "cursor" }?.state == .kept)
        keeping.switchToJuice()
        #expect(keptServices.calls.isEmpty)
    }

    /// Switch to Juice connects the agents it freed, and only those: a ticked line the card never named (Copilot CLI)
    /// waits for Connect (P974).
    @Test
    func switchToJuiceConnectsOnlyTheAgentsItFreed() async {
        let (model, hooks, agents, _) = fixture(.agents, mac: .vibeIsland)
        model.switchToJuice()
        await settle { model.vibeChoice == .switched }
        #expect(hooks.runs.map(\.1) == [["claude:~/.claude-work"]])
        #expect(agents.performed.map(\.1) == ["cursor"])
        #expect(hooks.openCodeClicks == 1)
        #expect(model.lines.first { $0.id == "copilot" }?.state == .tick(true))
        #expect(WelcomeText.agentsButton(model).hasPrefix(WelcomeText.connect))
    }

    /// A file the switch left (a link, comments, a write that failed) says on its line that Vibe Island's lines are
    /// still in it, and the line under the card does not read as done (P974).
    @Test
    func aFileTheSwitchLeftSaysVibeIslandsLinesAreStillThere() async {
        let (model, _, _, services) = fixture(.agents, mac: .vibeIsland)
        let found = WelcomeModel.fixtureVibe
        services.switchOutcomes = [found[0].place.url: .left("Add by hand"), found[1].place.url: .left("Couldn't write it"),
                                   found[2].place.url: .left("Add by hand"),
                                   found[3].place.url: .removed(backup: URL(fileURLWithPath: "/tmp/ji-welcome/.cursor/b"))]
        model.switchToJuice()
        await settle { model.vibeChoice == .switched }
        #expect(model.vibeLeft["claude:~/.claude"] == WelcomeText.vibeLeft("Add by hand"))
        #expect(model.vibeLeft["codex:~/.codex"] == WelcomeText.vibeLeft("Couldn't write it"))
        #expect(model.vibeLeft["opencode"] == WelcomeText.vibeLeft("Add by hand", plugin: true))
        #expect(model.vibeLeft["claude:~/.claude-work"] == nil && model.vibeLeft["cursor"] == nil)
        #expect(WelcomeText.vibeLeft("Add by hand").contains("vibe-island-bridge"))
        #expect(WelcomeText.vibeSwitched(left: 3) != WelcomeText.vibeSwitched(left: 0))
        #expect(WelcomeText.vibeSwitched(left: 3).contains("3 files"))
        let (clean, _, _, _) = fixture(.agents, mac: .vibeIsland)
        clean.switchToJuice()
        await settle { clean.vibeChoice == .switched }
        #expect(clean.vibeLeft.isEmpty)
    }

    @Test
    func openIslandsCardAsksItToQuitOnlyOnItsClick() {
        let (model, _, _, services) = fixture(.agents, openIsland: true)
        #expect(model.showsOpenIslandCard && services.calls.isEmpty)
        model.quitOpenIsland()
        #expect(services.calls == ["quit Open Island"] && !model.showsOpenIslandCard)
        let (kept, _, _, keptServices) = fixture(.agents, openIsland: true)
        kept.keepOpenIsland()
        #expect(!kept.showsOpenIslandCard && keptServices.calls.isEmpty)
    }

    // MARK: Pick a look (P962)

    /// Island on a notch Mac, Window without; the choice is stored as the screen is left, and Launch at Login is
    /// registered then, and not at the launch before it.
    @Test
    func launchAtLoginRegistersOnlyAsPickALookIsLeft() {
        for (notch, on) in [(true, true), (false, false)] {
            let (model, _, _, _) = fixture(.look, notch: notch)
            #expect(model.surface == (notch ? .island : .window))
            let service = FakeLoginItem(status: .notRegistered)
            let settings = model.env.settings
            settings.loginItemAwaitsChoice = true
            let login = LaunchAtLogin(settings: settings, identity: .production, bundlePath: LaunchAtLogin.installedPath, service: service)
            model.env.launchAtLogin = login
            login.applyAtLaunch()
            #expect(service.calls.isEmpty)
            model.launchAtLogin = on
            model.surface = notch ? .island : .window
            model.advance()
            #expect(model.step == .start)
            #expect(settings.showAs == (notch ? .island : .window))
            #expect(!settings.loginItemAwaitsChoice)
            #expect(service.calls == (on ? [.register] : []))
            #expect(settings.launchAtLogin == on && login.note == nil)
        }
    }

    /// A first run from the mounted DMG (not /Applications): Pick a look shows no Launch at Login, so leaving it chooses
    /// nothing, and the next launch from /Applications registers nothing by itself; only Settings' switch can (P973).
    @Test
    func aFirstRunOutsideApplicationsLeavesLaunchAtLoginToSettings() {
        let (model, _, _, _) = fixture(.look)
        let settings = model.env.settings
        settings.loginItemAwaitsChoice = true
        let mounted = FakeLoginItem(status: .notRegistered)
        model.env.launchAtLogin = LaunchAtLogin(settings: settings, identity: .production, bundlePath: "/Volumes/Juice/Juice.app",
                                                service: mounted)
        model.advance()
        #expect(model.step == .start)
        #expect(settings.loginItemAwaitsChoice && mounted.calls.isEmpty)
        let installed = FakeLoginItem(status: .notRegistered)
        let login = LaunchAtLogin(settings: settings, identity: .production, bundlePath: LaunchAtLogin.installedPath, service: installed)
        login.applyAtLaunch()
        #expect(installed.calls.isEmpty)
        login.set(true)
        #expect(installed.calls == [.register] && !settings.loginItemAwaitsChoice)
    }

    /// Show welcome on a Mac where the app ran: Pick a look starts from the owner's Show as and from what macOS says of the
    /// login item, so walking through it changes neither; a first run starts from the notch (P973).
    @Test
    func showWelcomeStartsPickALookFromTheOwnersSettings() {
        let env = AppEnvironment.demo(sessions: .empty)
        let settings = env.settings
        settings.showAs = .window
        settings.launchAtLogin = false
        settings.loginItemRegistered = true
        let removed = FakeLoginItem(status: .notRegistered)
        env.launchAtLogin = LaunchAtLogin(settings: settings, identity: .production, bundlePath: LaunchAtLogin.installedPath, service: removed)
        let model = WelcomeModel.fixture(step: .look, env: env, mac: .connected, hasNotch: true, firstRun: false)
        #expect(model.surface == .window && !model.launchAtLogin)
        model.advance()
        #expect(settings.showAs == .window && !settings.launchAtLogin)
        #expect(removed.calls.isEmpty)
        // Registered: shown on, and left as it is.
        settings.showAs = .island
        let on = FakeLoginItem(status: .enabled)
        env.launchAtLogin = LaunchAtLogin(settings: settings, identity: .production, bundlePath: LaunchAtLogin.installedPath, service: on)
        let again = WelcomeModel.fixture(step: .look, env: env, mac: .connected, hasNotch: false, firstRun: false)
        #expect(again.surface == .island && again.launchAtLogin)
        again.advance()
        #expect(on.calls.isEmpty && settings.launchAtLogin && settings.showAs == .island)
        // A first run on a Mac without a notch starts on Window, whatever the settings hold.
        let first = WelcomeModel.fixture(step: .look, env: env, mac: .fresh, hasNotch: false)
        #expect(first.surface == .window && first.launchAtLogin)
    }

    // MARK: First session (P960, P961)

    @Test
    func startOpensTheFirstConnectedAgentAndTheFirstRealSessionEndsTheWelcome() async {
        let (model, _, _, services) = fixture(.start, mac: .connected)
        var ended: [WelcomeModel.Outcome] = []
        model.onFinish = { ended.append($0) }
        #expect(model.firstAgent?.id == "claude")
        #expect(WelcomeText.start(model.firstAgent) == "Start Claude Code")
        #expect(WelcomeText.automation(terminal: services.terminalName) == "macOS will ask to let \(Product.name) use Terminal first.")
        model.primary()
        await settle { model.startState == .opened }
        #expect(services.calls == ["start claude"])
        model.sessionsChanged([])
        #expect(ended.isEmpty)
        model.sessionsChanged(["claude-first"])
        #expect(ended == [.firstSession] && services.calls.last == "chime")
        #expect(model.env.settings.welcomeSeen)
        model.sessionsChanged(["claude-second"])
        #expect(ended == [.firstSession])
    }

    @Test
    func aTerminalThatDidNotOpenSaysSoAndCopyStillWorks() async {
        let (model, _, _, services) = fixture(.start, mac: .connected)
        services.opens = false
        model.primary()
        await settle { model.startState == .failed }
        model.copyCommand()
        #expect(services.calls == ["start claude", "copy claude"])
        let (none, _, _, _) = fixture(.start, mac: .empty)
        var ended: [WelcomeModel.Outcome] = []
        none.onFinish = { ended.append($0) }
        #expect(none.firstAgent == nil && WelcomeText.start(nil) == "Done")
        none.primary()
        #expect(ended == [.later])
    }

    /// Start opens the agent in the folder of the latest session on this Mac, never an SSH host's; with none, the home
    /// folder. Hello names the notch only on a Mac that has one (P960).
    @Test
    func startOpensInTheLatestSessionsFolder() {
        let env = AppEnvironment.demo(sessions: .demoSessions)
        let model = WelcomeModel.fixture(step: .start, env: env, mac: .connected)
        let local = env.sessions.rows.filter { $0.folder != nil && $0.remoteHost == nil }
        let latest = local.max { $0.updatedAt < $1.updatedAt }
        #expect(latest?.folder != nil)
        #expect(model.startFolder == latest?.folder)
        let (none, _, _, _) = fixture(.start, mac: .connected)
        #expect(none.startFolder == nil)
        #expect(WelcomeText.headline(.hello, notch: true) == "Your agents, in the notch.")
        #expect(!WelcomeText.headline(.hello, notch: false).contains("notch"))
    }

    @Test
    func eachAgentStartsWithItsOwnCommand() {
        let look = AgentLook.of(.claude)
        func row(_ id: String) -> AgentRow { AgentRow(id: id, name: id, look: look, reach: .approve, place: nil, status: .connected, actions: []) }
        #expect(["claude", "codex", "opencode", "copilot", "cursor", "qwen", "devin", "kilo"].map { WelcomeModel.command(for: row($0)) }
            == ["claude", "codex", "opencode", "copilot", "cursor-agent", "qwen", "devin", "kilo"])
    }

    // MARK: New agents (P966)

    @Test
    func newAgentsAreTheOnesThisBuildAdded() {
        let table = AgentHookTable.wave1.map(\.kind.rawValue)
        #expect(NewAgents.atLaunch(waiting: [], known: nil, firstRun: false) == table)
        #expect(NewAgents.atLaunch(waiting: [], known: NewAgents.catalog, firstRun: false).isEmpty)
        #expect(NewAgents.atLaunch(waiting: ["kilo"], known: NewAgents.catalog, firstRun: false) == ["kilo"])
        #expect(NewAgents.atLaunch(waiting: ["kilo"], known: nil, firstRun: true).isEmpty)
        let look = AgentLook.of(.claude)
        let rows = [AgentRow(id: "copilot", name: "Copilot CLI", look: look, reach: .approve, place: nil, status: .notConnected, actions: [.connect]),
                    AgentRow(id: "cursor", name: "Cursor", look: look, reach: .watch, place: nil, status: .connected, actions: [.remove]),
                    AgentRow(id: "qwen", name: "Qwen Code", look: look, reach: .approve, place: nil, status: .notConnected, actions: [.connect],
                             refusal: "Start it once first")]
        #expect(NewAgents.shown(table, rows: rows).map(\.id) == ["copilot"])
        #expect(NewAgents.line(1) == "1 new agent can connect" && NewAgents.line(2) == "2 new agents can connect")
    }

    /// "Start an agent · Connect" while nothing is connected, never before the files are read (P965).
    @Test
    func nothingConnectedWaitsForTheFiles() {
        let look = AgentLook.of(.claude)
        func row(_ status: AgentRowStatus) -> AgentRow {
            AgentRow(id: "copilot", name: "Copilot CLI", look: look, reach: .approve, place: nil, status: status, actions: [])
        }
        #expect(NoSessionsLine.nothingConnected([]))
        #expect(NoSessionsLine.nothingConnected([row(.notConnected)]))
        #expect(!NoSessionsLine.nothingConnected([row(.checking)]))
        #expect(!NoSessionsLine.nothingConnected([row(.connected)]))
        #expect(!NoSessionsLine.nothingConnected([row(.needsCodexTrust)]))
        let (fresh, _, _, _) = fixture(.agents)
        #expect(NoSessionsLine.nothingConnected(fresh.rows))
        let (connected, _, _, _) = fixture(.agents, mac: .connected)
        #expect(!NoSessionsLine.nothingConnected(connected.rows))
    }

    // MARK: Hello and Demo sessions (P963, P967)

    /// The demo asks; once answered it runs, then is done with one chime. Nothing leaves the process.
    @Test
    func helloAsksThenFinishesWithAChime() async throws {
        var chimes = 0
        let demo = HelloDemo(chime: { chimes += 1 }, runs: .milliseconds(20))
        demo.start()
        #expect(demo.phase == .asking)
        #expect(demo.model.waiting.map(\.id) == [HelloDemo.sessionID])
        guard case .approval? = demo.model.card(for: HelloDemo.sessionID) else { Issue.record("no approval card"); return }
        demo.model.approve(HelloDemo.sessionID, .allowOnce, request: nil)
        await settle { demo.phase == .done }
        #expect(demo.phase == .done && chimes == 1)
        #expect(demo.feed.sentCommands.count == 1)
        #expect(demo.model.rows.first?.id == HelloDemo.sessionID && demo.model.waiting.isEmpty)
    }

    @Test
    func demoSessionsShowItsSessionsInMadeUpFolders() throws {
        let env = AppEnvironment.demo(sessions: .demoSessions)
        typealias ID = FixtureSessionFeed.DemoSessionsID
        #expect(Set(env.sessions.rows.map(\.id)) == Set(ID.all))
        #expect(Set(env.sessions.rows.compactMap(\.project)).isSubset(of: FixtureSessionFeed.demoSessionsFolders))
        guard case let .approval(card)? = env.sessions.card(for: ID.approval) else { Issue.record("no approval"); return }
        #expect(card.isAnswerable)
        guard case .question? = env.sessions.card(for: ID.question) else { Issue.record("no question"); return }
        #expect(env.sessions.rows.first { $0.id == ID.copilot }?.agent == GlyphPalette.Agent.kind(.copilot))
    }

    /// What shows instead of the sessions: in, the made-up rows; out, the sessions as they were. Real requests are never
    /// touched, and banners, reminders and the tidy wait while it shows.
    @Test
    func aShowcaseStandsInForTheSessionsAndGoes() {
        let settings = AppSettings.ephemeral()
        let live = LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .prototype).makeModel() })
        let before = live.rows.map(\.id)
        #expect(!before.isEmpty && live.showsRealSessions)
        let demo = DemoSessionsPlayer.makeFeed().makeModel()
        live.show(demo, as: .demoSessions)
        #expect(Set(live.rows.map(\.id)) == Set(FixtureSessionFeed.DemoSessionsID.all))
        #expect(live.showcaseKind == .demoSessions && !live.showsRealSessions)
        live.show(nil, as: .demoSessions)
        #expect(live.rows.map(\.id) == before && live.showcaseKind == nil && live.showsRealSessions)
    }
}
