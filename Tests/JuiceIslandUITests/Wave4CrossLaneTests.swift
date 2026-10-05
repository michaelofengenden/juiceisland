import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Wave 4's three lanes together (P1175 to P1181): Gemini CLI, Antigravity CLI and Grok Build (lane GEMINI), Qoder,
/// CodeBuddy, Factory Droid and Kimi Code (lane CLAUDEFMT), Pi, Oh My Pi and Amp (lane PLUGINS), all from the one agents
/// table. Each check runs in a temporary home (`AgentsEndToEndTests.World`: fake commands and folders, the real Agents
/// pane, welcome and installers) or over fixtures. No agent runs; nothing outside the scratch folder is read or written.
@MainActor
@Suite(.serialized)
struct Wave4CrossLaneTests {
    typealias World = AgentsEndToEndTests.World
    typealias E = AgentsEndToEndTests
    typealias W = WelcomeEndToEndTests

    /// The ten agents wave 4 added, in the table's order.
    static let added: [AgentKind] = [.gemini, .antigravity, .grok, .qoder, .codebuddy, .factory, .kimi, .pi, .ohmypi, .amp]
    static var addedIDs: [String] { added.map(\.rawValue) }
    /// What 0.4.0 recorded as connectable (`NewAgents.catalog` before this wave).
    static let known04 = NewAgents.before + ["copilot", "cursor", "qwen", "devin", "kilo"]

    /// The owner's files before Connect, each with something of the owner's that Connect and Remove must keep.
    static let before: [String: String] = [
        // https://geminicli.com/docs/hooks/reference/ (Configuration schema)
        ".gemini/settings.json": """
            {
              "general": { "vimMode": true },
              "hooks": {
                "AfterAgent": [
                  { "hooks": [ { "type": "command", "command": "say done", "timeout": 5000 } ] }
                ]
              }
            }

            """,
        // https://antigravity.google/docs/hooks/ (Schema and file format): a hook name of the owner's own.
        ".gemini/config/hooks.json": """
            {
              "reminder": {
                "PreInvocation": [{ "type": "command", "command": "./scripts/reminder.sh" }]
              }
            }

            """,
        // https://docs.x.ai/build/features/hooks: every `*.json` in `~/.grok/hooks/` loads; this one is the owner's.
        ".grok/hooks/mine.json": #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"# + "\n",
        // https://docs.qoder.com/cli/hooks
        ".qoder/settings.json": "{\n  \"model\": \"auto\",\n  \"hooks\": {\n    \"Stop\": [{ \"hooks\": [{ \"type\": \"command\", \"command\": \"say done\" }] }]\n  }\n}\n",
        // https://www.codebuddy.ai/docs/cli/hooks
        ".codebuddy/settings.json": "{\n  \"permissions\": { \"allow\": [\"Read\"] }\n}\n",
        // https://docs.factory.com/reference/hooks-reference: Droid's current file, events at the top.
        ".factory/hooks.json": #"{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}"# + "\n",
        // https://moonshotai.github.io/kimi-code/en/customization/hooks.html
        ".kimi-code/config.toml": "default_model = \"kimi-k2\"\n\n[loop_control]\nmax_steps_per_turn = 100\n",
        // https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md: an extension of the owner's.
        ".pi/agent/extensions/mine.ts": "export default function (pi) {}\n",
        // https://ampcode.com/docs/customize/plugins: the owner's own policy plugin.
        ".config/amp/plugins/policy.ts": "export default function (amp) {}\n",
    ]
    /// Gemini CLI by its `tmp` folder, Grok by its `bin`, Oh My Pi by its agent folder (no `extensions` yet).
    static let folders = [".gemini/tmp", ".grok/bin", ".omp/agent"]
    static let commands = ["gemini", "agy", "grok", "qodercli", "codebuddy", "droid", "kimi", "pi", "omp", "amp"]

    /// The files Connect writes for the ten, from the home folder.
    static let written: Set<String> = [
        ".gemini/settings.json", ".gemini/config/hooks.json", ".grok/hooks/juice-island.json", ".qoder/settings.json",
        ".codebuddy/settings.json", ".factory/hooks.json", ".kimi-code/config.toml", ".pi/agent/extensions/juice-island.ts",
        ".omp/agent/extensions/juice-island.ts", ".config/amp/plugins/juice-island.ts",
    ]

    static func everyAgent() async throws -> World {
        try await World(files: before, folders: folders, commands: commands)
    }

    static func spec(_ id: String) -> AgentHookSpec? { AgentHookTable.wave1.first { $0.kind.rawValue == id } }

    // MARK: Found, tagged, listed

    /// Settings › Agents and the welcome's Agents screen list every new agent found, in the table's order, each with the
    /// table's Approve or Watch tag and its own mark, ticked for Connect; the agents not found are only named.
    @Test
    func everyNewAgentFoundIsListedWithItsTagAndNoneThatIsNot() async throws {
        let world = try await Self.everyAgent()
        let suite = W.Suite()
        defer {
            world.stop()
            suite.remove()
        }
        await world.ready(Self.addedIDs)
        #expect(world.pane.rows.map(\.id) == Self.addedIDs)
        for row in world.pane.rows {
            let spec = try #require(Self.spec(row.id))
            #expect(row.reach == (spec.answers == .approve ? .approve : .watch), "\(row.id)")
            #expect(row.name == spec.name && row.status == .notConnected, "\(row.id): \(row.name) \(row.status)")
            #expect(row.look == AgentLook.of(EngineSessionsModel.agent(spec.kind)), "\(row.id)")
        }
        #expect(world.pane.rows.filter { $0.reach == .approve }.map(\.id) == ["qoder", "codebuddy"])
        let missing = AgentHookTable.wave1.filter { !Self.added.contains($0.kind) }.map(\.name)
        #expect(Array(world.pane.notFound.suffix(missing.count)) == missing)
        #expect(!world.pane.notFound.contains { name in Self.added.contains { AgentHookTable.spec($0)?.name == name } })

        let model = WelcomeModel(env: W.environment(world, settings: suite.launch()), services: W.ScratchServices(home: world.home))
        model.go(to: .agents)
        await world.ready(Self.addedIDs)
        let lines = model.lines.filter { $0.kind == .agent }
        #expect(lines.map(\.id) == Self.addedIDs)
        for line in lines {
            #expect(line.reach == world.row(line.id)?.reach && line.state == .tick(true), "\(line.id): \(line.state)")
        }
        #expect(Set(model.ticked.agents) == Set(Self.addedIDs))
    }

    /// A Mac with only Antigravity CLI's folders and the older Kimi CLI's: those two rows (Kimi under its older name),
    /// no Gemini CLI though `~/.gemini` is there (P1100), and the welcome lists the same two.
    @Test
    func onlyTheAgentsFoundHereHaveRows() async throws {
        let world = try await World(files: [:], folders: [".gemini/config", ".gemini/antigravity-cli", ".kimi"], commands: [])
        let suite = W.Suite()
        defer {
            world.stop()
            suite.remove()
        }
        await world.ready(["antigravity", "kimi"])
        #expect(world.pane.rows.map(\.id) == ["antigravity", "kimi"])
        #expect(world.row("kimi")?.name == "Kimi CLI" && world.row("kimi")?.place == "~/.kimi/config.toml")
        #expect(world.pane.notFound.contains("Gemini CLI") && !world.pane.notFound.contains("Antigravity"))
        #expect(!world.pane.notFound.contains("Kimi Code") && !world.pane.notFound.contains("Kimi CLI"))
        let model = WelcomeModel(env: W.environment(world, settings: suite.launch()), services: W.ScratchServices(home: world.home))
        model.go(to: .agents)
        await world.ready(["antigravity", "kimi"])
        #expect(model.lines.map(\.id) == ["antigravity", "kimi"])
        #expect(model.lines.allSatisfy { $0.reach == .watch })
    }

    // MARK: Connect all, Remove from all

    /// The welcome's Connect, once, for all ten: only their files change or appear, each that was there backed up first
    /// as it was, and the owner's own files beside Juice's untouched. Then Remove from all agents: every file as it was,
    /// byte for byte, Juice's own files gone, and the folder Connect made for Oh My Pi gone with them.
    @Test
    func connectForAllWritesOnlyTheirFilesAndRemoveFromAllGivesEachBack() async throws {
        let world = try await Self.everyAgent()
        let suite = W.Suite()
        defer {
            world.stop()
            suite.remove()
        }
        let original = W.snapshot(world.home)
        let model = WelcomeModel(env: W.environment(world, settings: suite.launch()), services: W.ScratchServices(home: world.home))
        model.go(to: .agents)
        await world.ready(Self.addedIDs)
        #expect(W.snapshot(world.home) == original)

        model.connect()
        #expect(await world.rig.waitUntil(60) {
            Self.addedIDs.allSatisfy { id in world.row(id).map { !$0.busy && $0.status == .connected } ?? false }
        }, "\(world.pane.rows.map { "\($0.id) \($0.status) \($0.refusal ?? "")" })")
        let after = W.snapshot(world.home)
        let changed = Set(after.keys.filter { !W.isBackup($0) && after[$0] != original[$0] })
        #expect(changed == Self.written)
        #expect(Set(original.keys).isSubset(of: Set(after.keys)))
        for path in changed where original[path] != nil {
            let backups = after.filter { $0.key.hasPrefix(path + ".backup.") }
            #expect(backups.count == 1 && backups.values.first == original[path], "\(path): \(backups.count) backups")
        }
        for path in [".grok/hooks/mine.json", ".pi/agent/extensions/mine.ts", ".config/amp/plugins/policy.ts"] {
            #expect(after[path] == original[path], "\(path)")
        }
        for path in Self.written {
            let text = String(decoding: after[path] ?? Data(), as: UTF8.self)
            #expect(text.contains(world.rig.hookHome!.helperURL.path) || text.contains(world.rig.hookHome!.bridgeURL.path), "\(path)")
        }

        #expect(world.pane.canRemoveFromAll)
        world.pane.removeFromAll()
        #expect(await world.rig.waitUntil(60) {
            Self.addedIDs.allSatisfy { id in world.row(id).map { !$0.busy && $0.status == .notConnected } ?? false }
        }, "\(world.pane.rows.map { "\($0.id) \($0.status) \($0.refusal ?? "")" })")
        let removed = W.snapshot(world.home).filter { !W.isBackup($0.key) }
        #expect(removed == original, "\(Set(removed.keys).symmetricDifference(original.keys)) \(removed.filter { original[$0.key] != $0.value }.keys)")
        #expect(!FileManager.default.fileExists(atPath: world.url(".omp/agent/extensions").path))
        #expect(FileManager.default.fileExists(atPath: world.url(".grok/hooks").path))
        #expect(!world.pane.canRemoveFromAll)
    }

    // MARK: The new agents line

    /// After an update from 0.4.0, the launch records the ten as new, once each, however many launches pass before the
    /// line is closed; the line counts those found here and not connected, so "10 new agents can connect", then 9 once
    /// Qoder is connected. Kimi, found by both its folders, counts once.
    @Test
    func theNewAgentsLineCountsEachNewAgentOnce() async throws {
        #expect(NewAgents.atLaunch(waiting: [], known: Self.known04, firstRun: false) == Self.addedIDs)
        #expect(NewAgents.atLaunch(waiting: Self.addedIDs, known: NewAgents.catalog, firstRun: false) == Self.addedIDs)
        #expect(NewAgents.atLaunch(waiting: Self.addedIDs, known: Self.known04, firstRun: false) == Self.addedIDs)
        #expect(NewAgents.atLaunch(waiting: [], known: Self.known04, firstRun: true).isEmpty)

        let suite = W.Suite()
        defer { suite.remove() }
        let first = suite.launch()
        first.agentsKnown = Self.known04
        _ = WelcomeGate.atLaunch(first, juiceHooks: true)
        #expect(first.newAgents == Self.addedIDs)
        let second = suite.launch()
        _ = WelcomeGate.atLaunch(second, juiceHooks: true)
        #expect(second.newAgents == Self.addedIDs)

        let world = try await World(files: Self.before, folders: Self.folders + [".kimi"], commands: Self.commands)
        defer { world.stop() }
        await world.ready(Self.addedIDs)
        let shown = NewAgents.shown(second.newAgents, rows: world.pane.rows)
        #expect(shown.map(\.id) == Self.addedIDs)
        #expect(NewAgents.line(shown.count) == "10 new agents can connect")
        await world.click(.connect, on: "qoder") { $0.status == .connected }
        #expect(NewAgents.line(NewAgents.shown(second.newAgents, rows: world.pane.rows).count) == "9 new agents can connect")
    }

    // MARK: Caller detection

    /// Devin and Grok Build run Claude Code's `settings.json` hooks: with every wave 4 change in the helper (the agents'
    /// own words read first, the Watch agents' paths), a session through Claude's hook is still Devin's or Grok's row,
    /// never Claude's, and Devin's approval through it is still answered from the island while Grok's never is.
    @Test
    func callerDetectionStillNamesDevinAndGrokThroughClaudesHook() async throws {
        let world = try await World(files: [".claude/settings.json": #"{"model":"opus"}"#, ".claude/.claude.json": "{}"],
                                    folders: [".grok/bin"], commands: ["claude", "grok"])
        defer { world.stop() }
        let rig = world.rig
        await world.ready(["claude", "grok"])
        await world.click(.connect, on: "claude") { $0.status == .connected }
        let start = try #require(E.command(world, ".claude/settings.json", event: "SessionStart"))
        let prompt = try #require(E.command(world, ".claude/settings.json", event: "UserPromptSubmit"))
        let ask = try #require(E.command(world, ".claude/settings.json", event: "PermissionRequest"))

        // Devin marks its hooks with the project's folder (P905).
        rig.extraEnvironment = ["DEVIN_PROJECT_DIR": "/tmp/project"]
        await rig.finished(E.claudeShaped("SessionStart", session: "dv-1", extra: ["source": "startup"]), source: nil, entrypoint: nil,
                           events: [E.started("dv-1", tool: .codebuddy, title: "Devin · project")], command: start)
        await rig.finished(E.claudeShaped("UserPromptSubmit", session: "dv-1", extra: ["prompt": "fix the tests"]), source: nil,
                           entrypoint: nil, events: [E.activity("dv-1", "Prompt: fix the tests")], command: prompt)
        await rig.waitUntil { rig.row("dv-1")?.agent == .kind(.devin) }
        #expect(rig.row("dv-1")?.agent == .kind(.devin))
        let count = rig.engine.openRequests.count
        let run = rig.hook(E.claudeShaped("PermissionRequest", session: "dv-1",
                                          extra: ["tool_name": "Bash", "tool_input": ["command": "git push origin main"]]),
                           source: nil, entrypoint: nil, events: [E.asked("dv-1")], command: ask)
        await rig.waitUntil { rig.engine.openRequests.count > count }
        await rig.waitUntil { if case let .approval(card)? = rig.card("dv-1") { card.isAnswerable } else { false } }
        await rig.model.decide("dv-1", .allowOnce)
        let answered = await run.result(within: 30)
        #expect(E.object(answered?.stdout ?? Data())?["decision"] as? String == "approve",
                "\(String(decoding: answered?.stdout ?? Data(), as: UTF8.self))")
        await rig.settle()

        // Grok sets `GROK_HOOK_EVENT` on every hook it runs (P1110).
        rig.extraEnvironment = ["GROK_HOOK_EVENT": "session_start"]
        defer { rig.extraEnvironment = [:] }
        let started = await rig.finished(WatchAgentsEndToEndTests.grok("SessionStart", camel: "session_start", session: "gk-0",
                                                                       extra: ["source": "startup"]),
                                         source: nil, entrypoint: nil,
                                         events: [E.started("gk-0", tool: .grokBuild, title: "Grok · project")], command: start)
        #expect(started.stdout.isEmpty && started.status == 0)
        rig.extraEnvironment = ["GROK_HOOK_EVENT": "user_prompt_submit"]
        await rig.finished(WatchAgentsEndToEndTests.grok("UserPromptSubmit", camel: "user_prompt_submit", session: "gk-0",
                                                         extra: ["prompt": "fix the tests"]),
                           source: nil, entrypoint: nil, events: [E.activity("gk-0", "Prompt: fix the tests")], command: prompt)
        await rig.waitUntil { rig.row("gk-0")?.agent == .other(.grokBuild) }
        #expect(rig.row("gk-0")?.agent == .other(.grokBuild))
        #expect(rig.upstream.current?.commands.filter { $0.session == "gk-0" }.map(\.source) == ["grok", "grok"])
        if case let .approval(card)? = rig.card("gk-0") { #expect(!card.isAnswerable) }
        #expect(rig.engine.state.sessions.allSatisfy { $0.tool != .claudeCode })
    }

    // MARK: Watch cards

    /// Every agent of the table asks once, through the bridge as its hooks or plugin bring it: a Watch agent's card never
    /// has Allow or Deny (not answerable), Allow all never counts it and never shows on it, and a Yes on it sends nothing;
    /// an Approve agent's card is answerable and Allow all covers exactly those (P930, P1129, P1159).
    @Test
    func noWatchAgentsCardShowsAllowDenyOrAllowAll() async throws {
        let feed = FixtureSessionFeed(scenario: .empty, now: DemoClock.now)
        func id(_ kind: AgentKind) -> String {
            switch kind {
            case .amp: "amp-T-\(kind.rawValue)"
            case .kilo: "kilo-ses_\(kind.rawValue)"
            default: "w4-\(kind.rawValue)"
            }
        }
        for spec in AgentHookTable.wave1 {
            let session = id(spec.kind)
            feed.engine.loadPreviewEvents([E.started(session, tool: spec.kind.carrierTool, title: "\(spec.kind.displayName) · project")])
            // The hook's note names the session's agent, as the helper's does (Copilot and Devin ride a fork's tool,
            // Antigravity Gemini's).
            #expect(feed.engine.loadPreviewNote(event: "SessionStart", sessionID: session, source: spec.kind.rawValue))
            feed.engine.loadPreviewEvents([E.asked(session)])
        }
        let model = feed.makeModel()
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: feed.now), sessions: model)
        let approve = AgentHookTable.wave1.filter { $0.answers == .approve }.map { id($0.kind) }
        #expect(Set(BatchAnswer.targets(env).map(\.sessionID)) == Set(approve))
        let watch = BatchAnswer.watchAgents(env.settings)
        for spec in AgentHookTable.wave1 {
            let session = id(spec.kind)
            #expect(env.sessions.row(id: session)?.agent == EngineSessionsModel.agent(spec.kind), "\(spec.name)")
            guard case let .approval(card)? = env.sessions.card(for: session) else {
                Issue.record("\(spec.name) has no card")
                continue
            }
            if spec.answers == .watch {
                #expect(!card.isAnswerable && card.request?.dismissable == true, "\(spec.name) shows Allow and Deny")
                #expect(watch.contains(card.agent) && !BatchAnswer.covers(card, watch: watch), "\(spec.name)")
                #expect(BatchAnswer.islandTargets(drawn: .approval(card), env: env).isEmpty, "\(spec.name) shows Allow all")
                let sent = feed.sentCommands.count
                await model.decide(session, .allowOnce, request: card.request?.id)
                #expect(feed.sentCommands.count == sent, "\(spec.name)'s Yes sent an answer")
            } else {
                #expect(card.isAnswerable && !watch.contains(card.agent), "\(spec.name)")
                #expect(BatchAnswer.islandTargets(drawn: .approval(card), env: env).count == approve.count, "\(spec.name)")
            }
        }
    }

    // MARK: The issue forms

    /// The bug and feature forms list every agent of the table by the name Report a Bug gives it, so a report about a
    /// new agent never lands on "Another agent".
    @Test
    func theIssueFormsListEveryAgentOfTheTable() throws {
        let folder = RenderHarness.root.appendingPathComponent("docs/public/github/ISSUE_TEMPLATE")
        let bug = try String(contentsOf: folder.appendingPathComponent("bug.yml"), encoding: .utf8)
        let feature = try String(contentsOf: folder.appendingPathComponent("feature.yml"), encoding: .utf8)
        for spec in AgentHookTable.wave1 {
            let option = BugReport.agentOption(EngineSessionsModel.agent(spec.kind))
            #expect(option == spec.name, "\(spec.name): \(option)")
            #expect(bug.contains("        - \(spec.name)\n") && feature.contains("        - \(spec.name)\n"), "\(spec.name)")
        }
    }

    // MARK: The README

    /// The grid lists all eighteen agents once each, nine Approve (Codex with its footnote) and nine Watch, as the table
    /// and the three agents with rows of their own say; `ReadmeAgentGridTests` holds both READMEs to it.
    @Test
    func theReadmeGridListsEighteenAgentsEachApproveOrWatch() throws {
        let lines = ReadmeAgentGridTests.lines(stem: "juice")
        #expect(lines.count == 18 && Set(lines.map(\.name)).count == 18)
        #expect(lines.filter { $0.reach.hasPrefix("Approve") }.count == 9 && lines.filter { $0.reach == "Watch" }.count == 9)
        for (url, stem) in ReadmeAgentGridTests.readmes() {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains(ReadmeAgentGridTests.grid(stem: stem)), "\(url.lastPathComponent)")
        }
    }
}
