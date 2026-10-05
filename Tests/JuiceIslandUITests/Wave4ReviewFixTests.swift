import Foundation
import Testing
@testable import IslandEngine
import IslandHookNotes
import JuiceCore
@testable import JuiceIslandUI

/// Wave 4's review (W4R-1 to W4R-7, P1186 to P1192): the welcome's Connect counts what it writes and says what is below
/// the fold, a command another Homebrew formula ships finds no agent, the READMEs promise answers only where the island
/// gives them, Qoder's IDE is named as Watch, Antigravity's row is the product's, and a long "Not found" line becomes a
/// count. Temporary homes and fixtures only: nothing of this Mac's is read or written.
@MainActor
struct Wave4ReviewFixTests {
    // MARK: W4R-1, the welcome's list below the fold (P1186)

    /// Connect says how many lines it writes, so a ticked line the person has not scrolled to still counts on the
    /// button; one line is plain Connect, none is Next.
    @Test
    func connectCountsTheLinesItWrites() {
        let env = AppEnvironment.demo(sessions: .empty)
        let model = WelcomeModel.fixture(step: .agents, env: env)
        let ticked = model.ticked
        #expect(ticked.profiles.count + ticked.agents.count == 6)
        #expect(WelcomeText.agentsButton(model) == "Connect 6")
        for id in ["claude", "codex:~/.codex", "opencode", "copilot"] { model.toggle(id) }
        #expect(WelcomeText.agentsButton(model) == "Connect")
        model.toggle("cursor")
        #expect(WelcomeText.agentsButton(model) == "Next")
    }

    /// The lines more than half below the list's visible bottom are the ones "more below" counts; none before the list
    /// has a height.
    @Test
    func theLinesBelowTheFoldAreCounted() {
        let mids: [CGFloat] = [20, 60, 100, 140, 180, 220]
        #expect(WelcomeFold.below(mids: mids, visibleHeight: 160) == 2)
        #expect(WelcomeFold.below(mids: mids, visibleHeight: 400) == 0)
        #expect(WelcomeFold.below(mids: mids, visibleHeight: 0) == 0)
        // Scrolled down: the lines above the top are seen already and never counted.
        #expect(WelcomeFold.below(mids: mids.map { $0 - 120 }, visibleHeight: 160) == 0)
        #expect(WelcomeText.moreBelow(6) == "6 more below")
    }

    // MARK: W4R-2, commands another formula ships (P1187)

    /// `grok`, `cbc`, the `amp` editor and `cln`'s `pi` (Homebrew formulae of those names) find no agent; nor does AWS's
    /// `copilot`. Amp's own `amp`, the `pi-coding-agent` formula's `pi` and `codebuddy` do, and Grok Build is found by
    /// the folders its installer makes.
    @Test
    func aCommandAnotherFormulaShipsFindsNoAgent() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ji-namesakes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true), bin = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        func program(_ path: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        func link(_ name: String, to target: String) throws {
            try program(target)
            let url = bin.appendingPathComponent(name)
            try? fm.removeItem(at: url)
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: "../" + target)
        }
        // Homebrew's links, as `brew install amp cln copilot` makes them (formula names from formulae.brew.sh).
        try link("amp", to: "Cellar/amp/0.7.1/bin/amp")
        try link("pi", to: "Cellar/cln/1.3.7/bin/pi")
        try link("copilot", to: "Cellar/copilot/1.34.1/bin/copilot")
        try program("bin/grok")
        try program("bin/cbc")
        let table = TableAgents(installer: AgentHookInstaller(home: home, helperPath: "/tmp/ji-home/bin/JuiceHooks", bundledHelper: nil,
                                                              ownFileStem: "juice-island", bridgeSocketPath: "/tmp/ji-home/bridge.sock"),
                                directories: { [bin.path] })
        await table.readAgain()
        #expect(table.found.isEmpty, "\(table.found)")

        // The agents' own: npm's link into node_modules, the agent's formula, CodeBuddy's own command, Grok's folders.
        try link("amp", to: "lib/node_modules/@sourcegraph/amp/dist/main.js")
        try link("pi", to: "Cellar/pi-coding-agent/0.70.0/bin/pi")
        try program("bin/codebuddy")
        try fm.createDirectory(at: home.appendingPathComponent(".grok/bin"), withIntermediateDirectories: true)
        await table.readAgain()
        #expect(table.found == [.amp, .pi, .codebuddy, .grok], "\(table.found)")
    }

    // MARK: W4R-4 and W4R-5, what the READMEs promise (P1189, P1190)

    static func readme(_ path: String) throws -> String {
        try String(contentsOf: ReadmeAgentGridTests.root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The public README's first sentence promises answers only from the agents marked Approve: nine of its eighteen
    /// are Watch, and Pi has no prompts at all.
    @Test
    func thePublicReadmePromisesAnswersOnlyFromApproveAgents() throws {
        let text = try Self.readme("docs/public/README.md")
        let first = try #require(text.components(separatedBy: "\n\n").dropFirst().first)
        #expect(!first.contains("answer its prompts"))
        #expect(first.contains("answer prompts from the agents marked Approve"))
    }

    /// Qoder is Approve for its CLI only: both grids say the IDE is Watch, in a note as Codex has.
    @Test
    func bothGridsSayQodersIDEIsWatch() throws {
        for path in ["docs/public/README.md", "README.md"] {
            let text = try Self.readme(path)
            #expect(text.contains("| Qoder | Approve² |"), "\(path)")
            #expect(text.contains("² Qoder CLI; the Qoder IDE is Watch."), "\(path)")
        }
    }

    // MARK: W4R-6, Antigravity (P1191)

    /// Antigravity 2.0 and its IDE read the same `~/.gemini/config/hooks.json` as the CLI, so Connect connects all three,
    /// and the row, like the sessions, is the product's.
    @Test
    func antigravitysRowIsTheProducts() {
        #expect(AgentHookTable.antigravity.name == "Antigravity")
        #expect(AgentLook.of(EngineSessionsModel.agent(.antigravity)).name == AgentHookTable.antigravity.name)
    }

    // MARK: W4R-7, the "Not found" line (P1192)

    /// A few names are listed; more are counted, the names in the line's help, so the line never ends in an ellipsis.
    @Test
    func manyAgentsNotFoundAreCounted() {
        #expect(AgentsPaneText.notFound(["Kilo", "Devin"]) == "Not found: Kilo, Devin")
        let all = AgentHookTable.wave1.map(\.name) + ["OpenCode"]
        #expect(all.count == 16)
        #expect(AgentsPaneText.notFound(all) == "16 agents not found")
    }
}
