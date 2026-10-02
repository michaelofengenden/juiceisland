import Foundation
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// Every agent Open Island's engine knows shows as itself (P151): its name, mark and colour, its last message and
/// prompt from its own metadata block, its approvals and questions answered in the shape its hook waits for.
@MainActor
struct AgentLookTests {
    static let others = AgentTool.allCases.filter { $0 != .claudeCode && $0 != .codex }

    @Test
    func everyAgentTheEngineKnowsHasANameAMarkAndAColourOfItsOwn() {
        #expect(Self.others.count == 11)
        for tool in Self.others { #expect(AgentLook.others[tool] != nil, "\(tool)") }
        let looks: [AgentLook] = Self.others.map { AgentLook.of($0) }
        let names = Set(looks.map { $0.name })
        #expect(names.count == looks.count)
        let marks: [AgentLook.Mark] = looks.map { $0.mark }
        for mark in marks { #expect(marks.filter { $0 == mark }.count == 1, "\(mark)") }
        for look in looks {
            #expect(!look.name.contains("Claude"))
            #expect(look.mark != .claude && look.mark != .openAI)
        }
        for tool in Self.others { #expect(AgentLook.of(tool).colour == AgentLook.colour(hex: AgentLook.colourHex(tool)), "\(tool)") }
        #expect(AgentLook.of(.geminiCLI).colour == Color(hex: 0x42E86B))
        #expect(Set(Self.others.filter { AgentLook.colourHex($0) != $0.brandColorHex }) == [.openCode, .grokBuild, .factory, .ohMyPi])
    }

    /// Every agent is told apart by its colour (a Clean footer's equalizers and the Codex group's dots carry no mark):
    /// no two agents' colours, Claude's and Codex's included, are closer than CIEDE2000 12, and no colour By agent draws
    /// a running glyph in is that close to a state's colour it could stand for (P207), in every choice of Needs you
    /// colour: an agent within 12 of it or its tint runs in the running blue, By state's own, and exactly those (P782).
    /// Claude's mark keeps its brand terracotta, 8.9 from the orange, where its shape says whose it is; its running
    /// glyph is `#D96A5A`, 14.4 from the orange and 21.8 from its tint: in Sand a running stream and an approval's "!"
    /// are both a warm stroke over a pile, and the terracotta one read as one more approval.
    @Test(arguments: NeedsYouColour.allCases)
    func noTwoAgentsColoursAreTooCloseToTellApart(_ needsYou: NeedsYouColour) {
        let wait = GlassGlyphTests.hex(needsYou.wait, .dark).lowercased(), question = GlassGlyphTests.hex(needsYou.question, .dark).lowercased()
        let near = Set(Self.others.map(AgentLook.colourHex).filter {
            CIEDE2000.distance($0, wait) < 12 || CIEDE2000.distance($0, question) < 12
        }.compactMap(AgentLook.colour(hex:)))
        #expect(near == AgentLook.nearNeedsYou[needsYou, default: []], "\(needsYou)")
        let marks = ["#d97757", "#5ac8fa"] + Self.others.map(AgentLook.colourHex)
        let agents: [GlyphPalette.Agent] = [.claude, .codex] + Self.others.map { .other($0) }
        let glyphs = agents.map { AgentLook.of($0).runningColour(needsYou) }.filter { $0 != IslandTheme.run }
            .map { GlassGlyphTests.hex($0, .dark).lowercased() }
        #expect(glyphs.count == agents.count - near.count)
        let states = ["run": "#4e80ed", "wait": wait, "question": question, "done": "#6fb982", "idle": "#5c5c61"]
        var closest = (distance: Double.infinity, pair: "")
        for colours in [marks, glyphs] {
            for i in colours.indices {
                for j in colours.indices where j > i {
                    let distance = CIEDE2000.distance(colours[i], colours[j])
                    if distance < closest.distance { closest = (distance, "\(colours[i]) \(colours[j])") }
                }
            }
        }
        for glyph in glyphs {
            for (state, hex) in states {
                let distance = CIEDE2000.distance(glyph, hex)
                if distance < closest.distance { closest = (distance, "\(glyph) \(state)") }
            }
        }
        #expect(closest.distance >= 12, "\(closest.pair): \(closest.distance)")
        #expect(GlyphPalette.colour(agent: .claude, state: .running, mode: .byAgent, needsYou: needsYou) == Color(hex: 0xD96A5A))
        #expect(AgentLook.of(.claude).colour == Color(hex: 0xD97757))
        #expect(abs(CIEDE2000.distance("#d97757", "#e97b36") - 8.9) < 0.1 && abs(CIEDE2000.distance("#d96a5a", "#e97b36") - 14.4) < 0.1)
        #expect(abs(CIEDE2000.distance("#ff6b9f", "#f472b6") - 5.9) < 0.1 && abs(CIEDE2000.distance("#4aa3df", "#6e9fff") - 9.1) < 0.1)
        // Before: OpenCode's amber read as the question's orange, and Grok's cyan sat beside Codex's new one.
        #expect(CIEDE2000.distance("#ffb547", "#f0a35e") < 12 && CIEDE2000.distance("#22d3ee", "#5ac8fa") < 12)
        #expect(IslandTheme.agentCodex == Color(hex: 0x5AC8FA) && Theme.codexMark == IslandTheme.agentCodex)
    }

    /// By state, every glyph is its state's colour, whoever's session it is. By agent, a running glyph only takes its
    /// agent's colour: approval, question and failed keep the needs-you colour and done its green, so what needs you
    /// pops as it does by state (P206).
    @Test(arguments: NeedsYouColour.allCases)
    func byAgentColoursTheRunningGlyphOnly(_ needsYou: NeedsYouColour) {
        let agents: [GlyphPalette.Agent] = [.claude, .codex] + Self.others.map { .other($0) }
        let states: [(GlyphPalette.State, Color)] = [(.running, IslandTheme.run), (.waiting, needsYou.wait), (.done, IslandTheme.done),
                                                     (.idle, IslandTheme.idleMark)]
        for agent in agents {
            for (state, colour) in states {
                #expect(GlyphPalette.colour(agent: agent, state: state, mode: .byState, needsYou: needsYou) == colour)
                #expect(GlyphPalette.colour(agent: agent, state: state, mode: .byAgent, needsYou: needsYou)
                    == (state == .running ? AgentLook.of(agent).runningColour(needsYou) : colour))
            }
        }
        #expect(GlyphPalette.colour(agent: .claude, state: .running, mode: .byAgent, needsYou: needsYou) == IslandTheme.agentClaudeRunning)
        for agent in agents where agent != .claude {
            let look = AgentLook.of(agent), near = AgentLook.nearNeedsYou[needsYou, default: []].contains(look.colour)
            #expect(look.runningColour(needsYou) == (near ? IslandTheme.run : look.colour))
        }
        #expect(GlyphPalette.colour(agent: .codex, state: .running, mode: .byAgent, needsYou: needsYou) == IslandTheme.agentCodex)
        // Under Orange no agent runs in the blue: every running glyph is as it was.
        #expect(AgentLook.nearNeedsYou[.orange] == nil)
        #expect(AgentLook.of(.openCode).colour == Color(hex: 0xC8C8CE) && AgentLook.of(.grokBuild).colour == Color(hex: 0x5EE6D8))
    }

    @Test
    func claudeAndCodexKeepTheirOwnMarksAndColours() {
        #expect(AgentLook.of(.claude) == AgentLook(name: "Claude", mark: .claude, colour: IslandTheme.agentClaude))
        #expect(AgentLook.of(.codex) == AgentLook(name: "Codex", mark: .openAI, colour: IslandTheme.agentCodex))
        #expect(AgentLook.of(.claudeCode) == AgentLook.of(.claude))
        #expect(AgentLook.of(AgentTool.codex) == AgentLook.of(GlyphPalette.Agent.codex))
        #expect(GlyphPalette.colour(agent: .other(.kimiCLI), state: .running, mode: .byAgent, needsYou: .pink) == Color(hex: 0xFDE047))
        #expect(GlyphPalette.colour(agent: .other(.kimiCLI), state: .running, mode: .byState, needsYou: .pink) == IslandTheme.run)
        #expect(GlyphPalette.colour(agent: .other(.kimiCLI), state: .waiting, mode: .byState, needsYou: .pink) == NeedsYouColour.pink.wait)
    }

    /// An agent a later engine adds, which the table does not list: the name its engine gives it, its initial on a tile
    /// and the neutral grey; never Claude's look.
    @Test
    func anAgentTheTableDoesNotListShowsItsEngineNameOnANeutralMark() {
        let look = AgentLook.of(.kimiCLI, table: [:])
        #expect(look == AgentLook(name: "Kimi CLI", mark: .tile("K"), colour: AgentLook.neutral))
        #expect(AgentLook.of(.ohMyPi, table: [:]).mark == .tile("O"))
        #expect(AgentLook.colour(hex: "#zzzzzz") == nil)
        #expect(AgentLook.colour(hex: "#42e86b") == Color(hex: 0x42E86B))
    }

    @Test
    func aRowSaysWhoseSessionItIsInItsTooltipAndACardInItsWording() {
        var row = FixtureSessionFeed(scenario: .agents).makeModel().row(id: FixtureSessionFeed.AgentID.geminiRunning)!
        #expect(SessionListLayout.rowHelp(row) == "Gemini · Ghostty")
        // The island's Clean row shows no repo: its mark's tooltip says it.
        #expect(SessionListLayout.rowHelp(row, naming: true) == "Gemini · notes-site · Ghostty")
        row.titleSource = .repo
        #expect(SessionListLayout.rowHelp(row, naming: true) == "Gemini · Ghostty")
        row.agent = .other(.qwenCode)
        #expect(SessionListLayout.rowHelp(row).hasPrefix("Qwen · "))
        #expect(GlyphPalette.Agent.other(.factory).displayName == "Factory")
        #expect(GlyphPalette.Agent.claude.displayName == "Claude")
    }
}

@MainActor
struct AgentFixtureTests {
    typealias ID = FixtureSessionFeed.AgentID

    static let expected: [String: AgentTool] = [
        ID.openCodeApproval: .openCode, ID.kimiApproval: .kimiCLI, ID.qwenQuestion: .qwenCode, ID.geminiRunning: .geminiCLI,
        ID.cursorRunning: .cursor, ID.piRunning: .pi, ID.geminiDone: .geminiCLI, ID.openCodeDone: .openCode,
        ID.factoryDone: .factory, ID.grokDone: .grokBuild, ID.qoderDone: .qoder, ID.codebuddyDone: .codebuddy,
        ID.ohMyPiDone: .ohMyPi,
    ]

    /// Before: every session that was not Codex's was Claude's, a Claude Code fork included.
    @Test
    func everySessionIsItsOwnAgent() {
        let model = FixtureSessionFeed(scenario: .agents).makeModel()
        #expect(model.rows.count == Self.expected.count)
        for (id, tool) in Self.expected {
            #expect(model.row(id: id)?.agent == .other(tool), "\(id)")
        }
        #expect(Set(Self.expected.values) == Set(AgentLookTests.others))
        #expect(!model.rows.contains { $0.agent == .claude || $0.agent == .codex })
    }

    /// Upstream titles every other agent's session "<Agent> · <folder>" (a fork's "Claude · …"): no row says that. The
    /// agent is its mark's; the title is the owner's first prompt (P204), from the agent's own metadata block, or, for
    /// Grok, whose hooks keep none, from the bridge's prompt.
    @Test
    func aSessionIsTitledByItsFirstPromptNeverByItsAgent() {
        let model = FixtureSessionFeed(scenario: .agents).makeModel()
        let expected: [String: String] = [
            ID.kimiApproval: "clean the build", ID.factoryDone: "check the release script", ID.qwenQuestion: "pick a chart",
            ID.geminiRunning: "tighten the intro", ID.ohMyPiDone: "sum the invoices", ID.openCodeDone: "sort the notes",
            ID.openCodeApproval: "push the fix", ID.cursorRunning: "run the tests", ID.piRunning: "read the results",
            ID.geminiDone: "draft the setup page", ID.grokDone: "rename the screenshots", ID.qoderDone: "list the open issues",
            ID.codebuddyDone: "fix the links",
        ]
        for (id, title) in expected {
            let row = model.row(id: id)
            #expect(row?.task == title, "\(id)")
            #expect(row?.titleSource == .prompt, "\(id)")
        }
        for row in model.rows { #expect(!row.task.contains(" · "), "\(row.id)") }
        #expect(EngineSessionsModel.title(nil, project: "notes-site", agent: .other(.geminiCLI)) == ("notes-site", .repo))
        #expect(EngineSessionsModel.title(nil, project: "", agent: .other(.geminiCLI)) == ("Gemini", .repo))
        #expect(EngineSessionsModel.title(ChatTitle(text: "Tighten the intro", source: .agent), project: "notes-site", agent: .claude)
            == ("Tighten the intro", .agent))
    }

    @Test
    func lastMessagesAndPromptsComeFromEachAgentsOwnBlock() {
        let model = FixtureSessionFeed(scenario: .agents).makeModel()
        #expect(model.row(id: ID.geminiDone)?.detail == MessageMarkup.plain(FixtureSessionFeed.geminiReply))
        #expect(model.row(id: ID.geminiDone)?.lastPrompt == "draft the setup page")
        #expect(model.row(id: ID.openCodeDone)?.detail == "Sorted the notes by date and merged the two March files.")
        #expect(model.row(id: ID.factoryDone)?.detail == "The release script tags juice-0.4-1 and pushes only to the private origin.")
        #expect(model.row(id: ID.qoderDone)?.detail == "Seven issues are open; two are labelled bug.")
        #expect(model.row(id: ID.ohMyPiDone)?.detail == "The invoices come to 1,240 in March.")
        #expect(model.row(id: ID.geminiRunning)?.lastPrompt == "tighten the intro")
        #expect(model.row(id: ID.cursorRunning)?.lastPrompt == "run the tests")
        #expect(model.row(id: ID.piRunning)?.lastPrompt == "read the results")
        #expect(model.row(id: ID.openCodeApproval)?.lastPrompt == "push the fix")
        // Grok's hooks keep no metadata: its Stop's summary is the message.
        #expect(model.row(id: ID.grokDone)?.detail == "Renamed 14 screenshots by date.")
        guard case let .done(grok)? = model.card(for: ID.grokDone) else { Issue.record("no Grok card"); return }
        #expect(grok.message == "Renamed 14 screenshots by date.")
        guard case let .done(gemini)? = model.card(for: ID.geminiDone) else { Issue.record("no Gemini card"); return }
        #expect(gemini.message == FixtureSessionFeed.geminiReply)
        #expect(gemini.agent == .other(.geminiCLI))
    }

    /// One session per metadata block, each alone: the message and the prompt come from it.
    @Test
    func everyMetadataBlockIsRead() {
        func session(_ tool: AgentTool, _ fill: (inout AgentSession) -> Void) -> AgentSession {
            var session = AgentSession(id: "s", title: "t", tool: tool, phase: .completed, summary: "summary", updatedAt: .now)
            fill(&session)
            return session
        }
        let sessions = [
            session(.claudeCode) { $0.claudeMetadata = ClaudeSessionMetadata(lastUserPrompt: "p", lastAssistantMessage: "m") },
            session(.codex) { $0.codexMetadata = CodexSessionMetadata(lastUserPrompt: "p", lastAssistantMessage: "m") },
            session(.geminiCLI) { $0.geminiMetadata = GeminiSessionMetadata(lastUserPrompt: "p", lastAssistantMessage: "m") },
            session(.openCode) { $0.openCodeMetadata = OpenCodeSessionMetadata(lastUserPrompt: "p", lastAssistantMessage: "m") },
            session(.cursor) { $0.cursorMetadata = CursorSessionMetadata(lastUserPrompt: "p", lastAssistantMessage: "m") },
            session(.pi) { $0.piMetadata = PiSessionMetadata(lastUserPrompt: "p", lastAssistantMessage: "m") },
        ]
        for session in sessions {
            #expect(EngineSessionsModel.lastMessage(session) == "m", "\(session.tool)")
            #expect(EngineSessionsModel.lastPrompt(session) == "p", "\(session.tool)")
        }
        // A block with blanks only says nothing.
        let blank = session(.openCode) { $0.openCodeMetadata = OpenCodeSessionMetadata(lastUserPrompt: " ", lastAssistantMessage: "\n") }
        #expect(EngineSessionsModel.lastMessage(blank) == nil)
        #expect(EngineSessionsModel.lastPrompt(blank) == nil)
    }

    /// Grok's summary is its message only after a Stop that carried one: upstream's own sentences, and a summary
    /// that is not a finished turn's, are no message.
    @Test
    func grokHasAMessageOnlyWhenItsStopCarriedOne() {
        func message(_ summary: String, _ phase: SessionPhase = .completed, _ tool: AgentTool = .grokBuild) -> String? {
            EngineSessionsModel.lastMessage(AgentSession(id: "g", title: "Grok · Desktop", tool: tool, phase: phase, summary: summary,
                                                         updatedAt: .now))
        }
        #expect(message("Renamed 14 screenshots by date.") == "Renamed 14 screenshots by date.")
        for sentence in ["Grok completed a turn in Desktop.", "Grok turn interrupted in Desktop.", "Grok tool failed: timeout",
                         "Grok is idle in Desktop.", "Started Grok session in Desktop.", "Resumed Grok session in Desktop.",
                         "Prompt: rename the screenshots", "  "] {
            #expect(message(sentence) == nil, "\(sentence)")
        }
        #expect(message("Renamed 14 screenshots by date.", .running) == nil)
        #expect(message("Renamed 14 screenshots by date.", .completed, .geminiCLI) == nil)
    }

    /// Needs you and Active count every agent's sessions; the Codex group stays Codex's.
    @Test
    func countsAndColumnsIncludeEveryAgent() {
        let model = FixtureSessionFeed(scenario: .agents).makeModel()
        #expect(model.needsYouCount == 3)
        #expect(Set(model.needsYou.map(\.id)) == [ID.openCodeApproval, ID.kimiApproval, ID.qwenQuestion])
        #expect(model.runningCount == 3)
        #expect(PillSummary.make(rows: model.rows, countMode: .needsYou, now: model.now).count == 3)
        #expect(PillSummary.make(rows: model.rows, countMode: .active, now: model.now).count == 10)
        let columns = SessionListLayout.columns(model.rows)
        #expect(columns.codexGroup.isEmpty)
        #expect(Set(columns.running.map(\.id)) == [ID.geminiRunning, ID.cursorRunning, ID.piRunning])
        #expect(columns.done.count == 7)
        // The closed pill's one glyph is the agent's own.
        #expect(PillLead.make(rows: model.rows, recentlyFinished: nil)?.agent == .other(.openCode))
    }

    /// A row names its terminal only when the hook knew it, and never an app that is the agent itself (Cursor's hooks
    /// run in Cursor: the mark says it).
    @Test
    func aRowNamesItsTerminalOnlyWhenTheHookKnewIt() {
        let model = FixtureSessionFeed(scenario: .agents).makeModel()
        #expect(model.row(id: ID.cursorRunning)?.host == nil)
        #expect(SessionListLayout.rowHelp(model.row(id: ID.cursorRunning)!) == "Cursor")
        #expect(model.row(id: ID.openCodeApproval)?.host == "iTerm")
        #expect(model.row(id: ID.grokDone)?.host == "Warp")
        #expect(EngineSessionsModel.host("Unknown", agent: .other(.openCode)) == nil)
        #expect(EngineSessionsModel.host(" ", agent: .claude) == nil)
        #expect(EngineSessionsModel.host(nil, agent: .claude) == nil)
        #expect(EngineSessionsModel.host("cursor", agent: .other(.cursor)) == nil)
        #expect(EngineSessionsModel.host("Cursor", agent: .claude) == "Cursor")
    }

    /// The fixtures are what the hooks send: the OpenCode plugin's own JSON (`open-island-opencode.js` `makePayload`,
    /// `permission.asked`, `question.asked`) decodes, through upstream's `BridgeCommand`, to the fixtures' payloads.
    @Test
    func theOpenCodeFixturesAreWhatThePluginSends() throws {
        let folder = FixtureSessionFeed.folder("notes-site")
        let permission = """
            {"type":"processOpenCodeHook","openCodeHook":{"hook_event_name":"PermissionRequest",\
            "session_id":"\(ID.openCodeApproval)","cwd":"\(folder)","terminal_app":"iTerm","terminal_tty":"/dev/ttys021",\
            "tool_name":"Bash","tool_input":"{\\"patterns\\":[\\"git push origin fix/intro-links\\"],\\"metadata\\":{},\\"command\\":\\"git push origin fix/intro-links\\"}",\
            "permission_id":"per_demo_\(ID.openCodeApproval.count)","permission_title":"Allow Bash",\
            "permission_description":"OpenCode wants to run Bash: git push origin fix/intro-links","_opencode_request_id":"per_x"}}
            """
        guard case let .processOpenCodeHook(sent) = try JSONDecoder().decode(BridgeCommand.self, from: Data(permission.utf8)) else {
            Issue.record("not an OpenCode hook"); return
        }
        let fixture = FixtureSessionFeed.openCodePermissionPayload(ID.openCodeApproval, project: "notes-site", tool: "Bash",
                                                                   patterns: [FixtureSessionFeed.openCodePush])
        #expect(sent == fixture)
        let question = """
            {"type":"processOpenCodeHook","openCodeHook":{"hook_event_name":"QuestionAsked","session_id":"\(ID.openCodeQuestion)",\
            "cwd":"\(folder)","terminal_app":"iTerm","terminal_tty":"/dev/ttys021","question_id":"que_demo_branch",\
            "question_text":"Which branch should the release go out from?","questions":[{"question":"Which branch should the release go out from?",\
            "header":"Question 1","options":[{"label":"main","description":"What is merged today.","allows_freeform":false},\
            {"label":"release/0.4","description":"Cut last week, fixes only.","allows_freeform":false}],"multi_select":false}]}}
            """
        guard case let .processOpenCodeHook(asked) = try JSONDecoder().decode(BridgeCommand.self, from: Data(question.utf8)) else {
            Issue.record("not an OpenCode hook"); return
        }
        let feed = FixtureSessionFeed(scenario: .agentQuestion)
        let prompt = try #require(feed.engine.state.session(id: ID.openCodeQuestion)?.questionPrompt)
        #expect(prompt.title == asked.questionPrompt.title)
        #expect(prompt.questions.map(\.question) == asked.questionPrompt.questions.map(\.question))
        #expect(prompt.questions.map { $0.options.map(\.label) } == asked.questionPrompt.questions.map { $0.options.map(\.label) })
        #expect(prompt.questions.map(\.header) == ["Question 1"])
    }

    /// A fork's request is upstream's decoding of Claude's payload with its `hook_source`: its tool, and its own
    /// sentence ("Kimi CLI wants to run Bash.").
    @Test
    func aForksRequestIsUpstreamsDecodingOfItsPayload() throws {
        let feed = FixtureSessionFeed(scenario: .agents)
        let session = try #require(feed.engine.state.session(id: ID.kimiApproval))
        #expect(session.tool == .kimiCLI)
        let request = try #require(session.permissionRequest)
        #expect(request.summary == "Kimi CLI wants to run Bash.")
        #expect(request.affectedPath == FixtureSessionFeed.kimiCommand)
        #expect(feed.engine.state.session(id: ID.qwenQuestion)?.tool == .qwenCode)
        #expect(feed.engine.state.session(id: ID.factoryDone)?.tool == .factory)
    }
}

/// CIEDE2000 colour difference between two sRGB `#rrggbb` colours (D65).
enum CIEDE2000 {
    static func lab(_ hex: String) -> (l: Double, a: Double, b: Double) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        func linear(_ c: UInt32) -> Double {
            let v = Double(c) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = (linear(value >> 16 & 0xFF), linear(value >> 8 & 0xFF), linear(value & 0xFF))
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047, y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    static func distance(_ first: String, _ second: String) -> Double {
        let (l1, a1, b1) = lab(first), (l2, a2, b2) = lab(second)
        let rad = Double.pi / 180
        let cBar = (hypot(a1, b1) + hypot(a2, b2)) / 2
        let g = 0.5 * (1 - sqrt(pow(cBar, 7) / (pow(cBar, 7) + pow(25, 7))))
        let (a1p, a2p) = ((1 + g) * a1, (1 + g) * a2)
        let (c1p, c2p) = (hypot(a1p, b1), hypot(a2p, b2))
        func hue(_ b: Double, _ a: Double) -> Double { let h = atan2(b, a) / rad; return h < 0 ? h + 360 : h }
        let (h1p, h2p) = (hue(b1, a1p), hue(b2, a2p))
        var dh = h2p - h1p
        if c1p * c2p == 0 { dh = 0 } else if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        let dL = l2 - l1, dC = c2p - c1p, dH = 2 * sqrt(c1p * c2p) * sin(dh / 2 * rad)
        let lBar = (l1 + l2) / 2, cBarP = (c1p + c2p) / 2
        let hBar = c1p * c2p == 0 ? h1p + h2p : abs(h1p - h2p) <= 180 ? (h1p + h2p) / 2
            : (h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2)
        let t = 1 - 0.17 * cos((hBar - 30) * rad) + 0.24 * cos(2 * hBar * rad) + 0.32 * cos((3 * hBar + 6) * rad)
            - 0.20 * cos((4 * hBar - 63) * rad)
        let dTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
        let rC = 2 * sqrt(pow(cBarP, 7) / (pow(cBarP, 7) + pow(25, 7)))
        let sL = 1 + 0.015 * pow(lBar - 50, 2) / sqrt(20 + pow(lBar - 50, 2)), sC = 1 + 0.045 * cBarP, sH = 1 + 0.015 * cBarP * t
        let rT = -sin(2 * dTheta * rad) * rC
        return sqrt(pow(dL / sL, 2) + pow(dC / sC, 2) + pow(dH / sH, 2) + rT * (dC / sC) * (dH / sH))
    }
}

@MainActor
struct AgentCardTests {
    typealias ID = FixtureSessionFeed.AgentID

    /// OpenCode's box: the command, never the plugin's sentence or its cut JSON; No and stop and the third button
    /// are Claude's alone.
    @Test
    func anOpenCodeApprovalShowsItsCommand() throws {
        let model = FixtureSessionFeed(scenario: .agents).makeModel()
        guard case let .approval(card)? = model.card(for: ID.openCodeApproval) else { Issue.record("no card"); return }
        #expect(card.agent == .other(.openCode))
        #expect(card.tool == "Bash")
        #expect(card.body == .command(FixtureSessionFeed.openCodePush))
        #expect(card.reason == nil)
        #expect(card.alwaysAllowLabel == nil)
        #expect(!card.canStop)
        #expect(model.row(id: ID.openCodeApproval)?.detail == FixtureSessionFeed.openCodePush)
    }

    /// A long command: upstream keeps 110 characters of the plugin's JSON, which no longer parses, so the box takes
    /// the first pattern, whole, from the plugin's sentence, and says with `…` that the cut may have hidden another.
    @Test
    func aLongOpenCodeCommandComesFromThePluginsSentence() {
        let long = "swift test --filter 'AgentFixtureTests|AgentCardTests|AgentLookTests|GeminiReplyTests' --parallel --num-workers 4"
        let payload = FixtureSessionFeed.openCodePermissionPayload("opencode-x", project: "notes-site", tool: "Bash", patterns: [long])
        let request = FixtureSessionFeed.openCodeRequest(payload)
        #expect(request.affectedPath.hasSuffix("…"))
        let mapped = ApprovalContent.make(request: request, input: nil, tool: .openCode, folder: nil)
        #expect(mapped.body == .command(long + " …"))
        let edit = FixtureSessionFeed.openCodePermissionPayload("opencode-y", project: "notes-site", tool: "Edit",
                                                                patterns: [FixtureSessionFeed.folder("notes-site") + "/docs/setup.md"])
        let editMapped = ApprovalContent.make(request: FixtureSessionFeed.openCodeRequest(edit), input: nil, tool: .openCode,
                                              folder: FixtureSessionFeed.folder("notes-site"))
        #expect(editMapped.body == .text("docs/setup.md"))
        #expect(editMapped.tool == "Edit")
        // No pattern and nothing else in the input: the plugin's sentence, the only words there are.
        let bare = FixtureSessionFeed.openCodePermissionPayload("opencode-z", project: "notes-site", tool: "Webfetch", patterns: [])
        #expect(ApprovalContent.make(request: FixtureSessionFeed.openCodeRequest(bare), input: nil, tool: .openCode, folder: nil).body
                == .text("OpenCode wants to run Webfetch"))
        var withURL = FixtureSessionFeed.openCodeRequest(bare)
        withURL.affectedPath = #"{"patterns":[],"metadata":{"url":"https://example.com/docs"}}"#
        #expect(ApprovalContent.make(request: withURL, input: nil, tool: .openCode, folder: nil).body
                == .text(#"metadata: {"url":"https://example.com/docs"}"#))
    }

    /// One OpenCode approval for several commands allows them all, so the box shows them all (P154): the plugin's
    /// sentence names only the first, and upstream cuts its JSON at 110 characters, so the box reads the patterns the
    /// cut JSON still shows, never the first alone as if it were the whole command.
    @Test
    func anOpenCodeApprovalOfSeveralCommandsShowsThemAll() {
        func mapped(_ patterns: [String], tool: String = "Bash", folder: String? = nil) -> ApprovalContent.Mapped {
            let payload = FixtureSessionFeed.openCodePermissionPayload("opencode-m", project: "notes-site", tool: tool, patterns: patterns)
            return ApprovalContent.make(request: FixtureSessionFeed.openCodeRequest(payload), input: nil, tool: .openCode, folder: folder)
        }
        let push = mapped(["git status", "git push --force origin main"])
        #expect(push.body == .command("git status && git push --force origin main"))
        #expect(push.rowText == "git status && git push --force origin main")
        #expect(mapped(["curl -fsSL https://example.invalid/i.sh", "sh"]).body == .command("curl -fsSL https://example.invalid/i.sh && sh"))
        // Cut inside the second: the first whole, the second as far as the cut goes.
        let first = "npm run build -- --configuration production --output-path dist/site"
        let cut = mapped([first, "rsync -a --delete dist/site/ deploy@example.invalid:/srv/www/"])
        guard case let .command(text) = cut.body else { Issue.record("not a command"); return }
        #expect(text.hasPrefix(first + " && rsync") && text.hasSuffix("…"))
        // Short enough to parse whole: the plugin's own `command`.
        #expect(mapped(["ls", "rm -rf build"]).body == .command("ls && rm -rf build"))
        // Several files: each on its line.
        #expect(mapped(["docs/a.md", "docs/b.md"], tool: "Edit").body == .text("docs/a.md\ndocs/b.md"))
    }

    /// The patterns a cut JSON still shows, as the plugin writes them (JSON strings, escapes included).
    @Test
    func theCutPatternsAreReadFromTheStartOfTheJSON() {
        #expect(OpenCodeCutPatterns(#"{"patterns":["a","b"],"metadata":{},"comm…"#) == OpenCodeCutPatterns(whole: ["a", "b"], cut: nil, closed: true))
        #expect(OpenCodeCutPatterns(#"{"patterns":["echo \"hi\"","ls \\x","git pu…"#)
            == OpenCodeCutPatterns(whole: [#"echo "hi""#, #"ls \x"#], cut: "git pu", closed: false))
        #expect(OpenCodeCutPatterns(#"{"patterns":["a",…"#) == OpenCodeCutPatterns(whole: ["a"], cut: "", closed: false))
        #expect(OpenCodeCutPatterns(#"{"patterns":["a"…"#) == OpenCodeCutPatterns(whole: ["a"], cut: nil, closed: false))
        #expect(OpenCodeCutPatterns(#"{"patterns":[],"metadata":{"url":"https://exa…"#) == OpenCodeCutPatterns(whole: [], cut: nil, closed: true))
        #expect(OpenCodeCutPatterns(#"{"metadata":{}}"#) == nil && OpenCodeCutPatterns(#"{"patterns":[1,2]}"#) == nil)
        let shown: (String) -> String = { $0 }
        #expect(OpenCodeCutPatterns(whole: ["a"], cut: "", closed: false).text(first: "a", separator: " && ", shown: shown) == "a && …")
        #expect(OpenCodeCutPatterns(whole: ["a"], cut: nil, closed: false).text(first: "a", separator: " && ", shown: shown) == "a …")
        #expect(OpenCodeCutPatterns(whole: [], cut: "lo", closed: false).text(first: "long", separator: " && ", shown: shown) == "long …")
        #expect(OpenCodeCutPatterns(whole: [], cut: nil, closed: true).text(first: nil, separator: " && ", shown: shown) == nil)
    }

    @Test
    func anOpenCodeDecisionGoesOutAsTheBridgeResolvesIt() async {
        let feed = FixtureSessionFeed(scenario: .agents)
        let model = feed.makeModel()
        await model.decide(ID.openCodeApproval, .denyAndStop)
        #expect(feed.sentCommands.isEmpty)
        await model.decide(ID.openCodeApproval, .denyWithReason("push to a branch instead"))
        guard case let .resolvePermission(session, resolution)? = feed.sentCommands.first else { Issue.record("nothing sent"); return }
        #expect(session == ID.openCodeApproval)
        #expect(resolution == .deny(message: "push to a branch instead", interrupt: false))
        if case .approval? = model.card(for: ID.openCodeApproval) { Issue.record("the approval card stayed") }

        let again = FixtureSessionFeed(scenario: .agents)
        await again.makeModel().decide(ID.openCodeApproval, .allowOnce)
        guard case let .resolvePermission(_, allowed)? = again.sentCommands.first else { Issue.record("nothing sent"); return }
        #expect(allowed == .allowOnce())
    }

    /// A Claude Code fork's approval is Claude's: the request's own command until a transcript under a `projects`
    /// folder has it (Kimi's has not), and its sentence ("Kimi CLI wants to run Bash.") never shown.
    @Test
    func aForksApprovalReadsAsClaudesDoes() async {
        let feed = FixtureSessionFeed(scenario: .agents)
        let model = feed.makeModel()
        guard case let .approval(card)? = model.card(for: ID.kimiApproval) else { Issue.record("no card"); return }
        #expect(card.agent == .other(.kimiCLI))
        #expect(card.body == .command(FixtureSessionFeed.kimiCommand))
        #expect(card.reason == nil)
        #expect(!card.canStop)
        await model.decide(ID.kimiApproval, .allowOnce)
        guard case let .resolvePermission(session, resolution)? = feed.sentCommands.first else { Issue.record("nothing sent"); return }
        #expect(session == ID.kimiApproval)
        #expect(resolution == .allowOnce())
    }

    @Test
    func aForksQuestionIsAnsweredInClaudesShape() async {
        let feed = FixtureSessionFeed(scenario: .agents)
        let model = feed.makeModel()
        guard case let .question(card)? = model.card(for: ID.qwenQuestion) else { Issue.record("no card"); return }
        #expect(card.agent == .other(.qwenCode))
        #expect(card.topic == "Chart")
        #expect(card.options.map(\.label) == ["Burn-down", "Daily spend"])
        #expect(model.answerQuestion(ID.qwenQuestion, .option(1)))
        await settle { !feed.sentCommands.isEmpty }
        guard case let .answerQuestion(session, response)? = feed.sentCommands.first else { Issue.record("nothing sent"); return }
        #expect(session == ID.qwenQuestion)
        #expect(response.rawAnswer == "Daily spend")
        #expect(response.answers == ["Which chart should the usage page lead with?": "Daily spend"])
    }

    /// OpenCode's question: the plugin's "Question 1" is no topic (the card would read "Question · Question 1"), and
    /// the answer goes as the bridge hands it to the plugin (`rawAnswer`).
    @Test
    func anOpenCodeQuestionHasNoFillerTopicAndSendsItsAnswer() async {
        let feed = FixtureSessionFeed(scenario: .agentQuestion)
        let model = feed.makeModel()
        guard case let .question(card)? = model.card(for: ID.openCodeQuestion) else { Issue.record("no card"); return }
        #expect(card.agent == .other(.openCode))
        #expect(card.topic == nil)
        #expect(card.options.map(\.label) == ["main", "release/0.4"])
        #expect(model.answerQuestion(ID.openCodeQuestion, .text("release/0.4, then main")))
        await settle { !feed.sentCommands.isEmpty }
        guard case let .answerQuestion(_, response)? = feed.sentCommands.first else { Issue.record("nothing sent"); return }
        #expect(response.rawAnswer == "release/0.4, then main")
        #expect(EngineSessionsModel.isFillerHeader("Question"))
        #expect(EngineSessionsModel.isFillerHeader("Question 12"))
        #expect(!EngineSessionsModel.isFillerHeader("Questions"))
        #expect(!EngineSessionsModel.isFillerHeader("Chart"))
    }

    /// Two OpenCode questions: the card pages through both and sends both answers at once, as upstream does; the
    /// bridge hands the plugin one text (`displaySummary`, every answer under its question), the only shape the plugin
    /// replies with (`answers: [[text]]`).
    @Test
    func twoOpenCodeQuestionsAreAnsweredTogether() async throws {
        let feed = FixtureSessionFeed(scenario: .agentQuestion)
        let id = "opencode-ses_demo_two"
        var asked = FixtureSessionFeed.openCodePayload(id, project: "notes-site", event: .questionAsked)
        asked.questionID = "que_demo_two"
        asked.questionText = "Which branch?"
        asked.questions = [
            OpenCodeQuestionPayload(question: "Which branch?", header: "Question 1", options: [
                OpenCodeQuestionOptionPayload(label: "main"), OpenCodeQuestionOptionPayload(label: "release/0.4"),
            ]),
            OpenCodeQuestionPayload(question: "Tag it?", header: "Tag", options: [
                OpenCodeQuestionOptionPayload(label: "Yes"), OpenCodeQuestionOptionPayload(label: "No"),
            ]),
        ]
        let events = FixtureSessionFeed.openCodeStart(id, project: "notes-site", prompt: "ship it", at: feed.now - 120)
            + [.questionAsked(QuestionAsked(sessionID: id, prompt: asked.questionPrompt, timestamp: feed.now - 60))]
        #expect(feed.engine.loadPreviewEvents(events))
        let model = feed.makeModel()
        guard case let .question(first)? = model.card(for: id) else { Issue.record("no card"); return }
        #expect(first.topic == nil && first.count == 2)
        #expect(!model.answerQuestion(id, .option(0)))
        guard case let .question(second)? = model.card(for: id) else { Issue.record("no second step"); return }
        #expect(second.topic == "Tag" && second.step == 1)
        #expect(model.answerQuestion(id, .option(0)))
        await settle { !feed.sentCommands.isEmpty }
        guard case let .answerQuestion(session, response)? = feed.sentCommands.first else { Issue.record("nothing sent"); return }
        #expect(session == id)
        #expect(response.answers == ["Which branch?": "main", "Tag it?": "Yes"])
        #expect(response.displaySummary.contains("Which branch?: main") && response.displaySummary.contains("Tag it?: Yes"))
    }

    @Test
    func theCardsSayTheAgentsName() {
        let model = FixtureSessionFeed(scenario: .agents).makeModel()
        guard case let .approval(card)? = model.card(for: ID.kimiApproval) else { Issue.record("no card"); return }
        #expect(card.agent.displayName == "Kimi")
        guard case let .done(done)? = model.card(for: ID.openCodeDone) else { Issue.record("no card"); return }
        #expect(done.agent.displayName == "OpenCode")
    }

    private func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Gemini's reply as upstream's own card shows it, found in one pass (P152).
@MainActor
struct GeminiReplyTests {
    static func upstream(_ body: String?, preview: String? = "preview") -> String? {
        AgentSession(id: "g", title: "t", tool: .geminiCLI, phase: .completed, summary: "", updatedAt: .now,
                     geminiMetadata: GeminiSessionMetadata(lastAssistantMessage: preview, lastAssistantMessageBody: body))
            .completionAssistantMessageText
    }

    static func ours(_ body: String?, preview: String? = "preview") -> String? {
        GeminiReply.text(GeminiSessionMetadata(lastAssistantMessage: preview, lastAssistantMessageBody: body))
    }

    static let answer = "Drafted docs/setup.md with the install steps and the config folder."

    @Test
    func theReplyIsUpstreamsOnItsOwnCases() {
        let answer = Self.answer
        let cases: [String?] = [
            nil, "", "   \n ", "Short.", answer, answer + "\n\n" + answer, answer + "\n" + answer, answer + answer,
            "Thinking about it.\n\n\n\n" + answer, "Part one.\r\n\r\n\r\nPart two, " + answer + "\r\n\r\n" + answer,
            "Intro line.\n\n" + answer + "\n  \n" + answer.replacingOccurrences(of: " ", with: "  "),
            "Lead.\n\nNote: x\n\n" + answer + "\n\nok\n\n" + answer, answer + "\n\n" + answer + "\n\n" + answer,
            FixtureSessionFeed.geminiReply + "\n\n" + FixtureSessionFeed.geminiReply,
            String(repeating: "abcdefghij", count: 12), "x" + String(repeating: "ab", count: 40) + "y",
        ]
        for body in cases {
            #expect(Self.ours(body) == Self.upstream(body), "\(String(describing: body))")
            #expect(Self.ours(body, preview: nil) == Self.upstream(body, preview: nil), "\(String(describing: body))")
        }
    }

    /// Random texts over a small alphabet, so tails repeat often and at every length: equal to upstream on each.
    @Test
    func theReplyIsUpstreamsOnRandomTexts() {
        var generator = SeededGenerator(seed: 160)
        let alphabet = Array("ab \nc")
        for _ in 0..<300 {
            let count = Int.random(in: 0...160, using: &generator)
            let text = String((0..<count).map { _ in alphabet.randomElement(using: &generator)! })
            let body = Bool.random(using: &generator) ? text + text.suffix(Int.random(in: 0...count, using: &generator)) : text
            #expect(Self.ours(body) == Self.upstream(body), "\(body.debugDescription)")
        }
    }

    /// 8,000 characters (the hook's cap) with no copy at the end: one pass, in milliseconds. Upstream's search tries
    /// every tail against every earlier stretch, about n³/24 comparisons, each with two arrays made.
    @Test
    func aLongReplyTakesOnePass() {
        var generator = SeededGenerator(seed: 8)
        let words = ["notes", "setup", "config", "install", "page", "draft", "intro", "folder", "serve", "links"]
        var body = ""
        while body.count < 8_000 { body += words.randomElement(using: &generator)! + (Bool.random(using: &generator) ? " " : "\n") }
        body = String(body.prefix(8_000))
        let start = ContinuousClock.now
        let text = Self.ours(body)
        let session = AgentSession(id: "g", title: "t", tool: .geminiCLI, phase: .completed, summary: "", updatedAt: .now,
                                   geminiMetadata: GeminiSessionMetadata(lastAssistantMessageBody: body))
        #expect(EngineSessionsModel.lastMessage(session) == text)
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(text == body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test
    func theZArrayCountsWhatEachSuffixSharesWithTheStart() {
        #expect(GeminiReply.zArray(Array("aabxaab")) == [7, 1, 0, 0, 3, 1, 0])
        #expect(GeminiReply.zArray([]) == [])
    }
}

/// A deterministic generator (SplitMix64), so random cases are the same at every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
