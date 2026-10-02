import Foundation
import IslandHookNotes
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Answer Codex on the island (P470) through the engine, with the broker stood in: what the broker holds from the request
/// alone, what the engine hands back before any card (the owner looking at Codex, a reviewer that is not the owner, one
/// that cannot be read, a helper that ended, an entry past its grace), and what an island answer sends. Inputs in
/// codex-rs's shapes (`hooks/src/schema.rs`, `protocol.rs` `TurnContextItem`); fictional values.
@MainActor
@Suite(.serialized)
struct CodexHoldTests {
    typealias S = AttentionScene
    typealias R = RolloutFixtures
    typealias T = CodexAttentionTableTests

    /// A Codex session whose rollout the tracker has read (its reviewer), with Answer Codex on the island on.
    private func scene(reviewer: String? = "user", frontmost: Bool = false, app: Bool = false, on: Bool = true) -> S {
        let s = S(frontmost: frontmost)
        s.engine.answersCodex = on
        s.begin("c1", tool: .codex)
        if app {
            var thread = s.engine.state.session(id: "c1")!
            thread.isCodexAppSession = true
            s.engine.replace(thread)
        }
        if let reviewer { s.rollout("c1", [R.meta(id: "c1"), T.reviewer(reviewer), T.turn]) }
        return s
    }

    private static func line(_ object: [String: Any], source: String = "codex") -> HookRequestLine {
        HookRequestLine(source: source, input: try! JSONSerialization.data(withJSONObject: object))
    }

    // MARK: The broker

    /// From the request alone: only with the switch on, only a main-thread shell command or patch in Codex's `default`
    /// mode, bounded by the backstop; a network approval, an MCP or connector call, `request_permissions`, `write_stdin`,
    /// a subagent's, bypass and a Codex too old to name its mode are released, and Claude's requests are unchanged.
    @Test
    func theBrokerHoldsOnlyACodexMainThreadCommandOrPatchWithTheSwitchOn() {
        let bash = S.codex("PermissionRequest")
        let patch = S.codex("PermissionRequest", tool: "apply_patch", input: ["command": "*** Begin Patch\n*** End Patch\n"])
        for object in [bash, patch] {
            #expect(AttentionPolicy.brokerHold(Self.line(object), object, answersSubagents: false) == .released)
            #expect(AttentionPolicy.brokerHold(Self.line(object), object, answersSubagents: true) == .released)
            let held = AttentionPolicy.brokerHold(Self.line(object), object, answersSubagents: false, answersCodex: true, backstop: 15)
            #expect(held == BrokerHold(held: true, bound: 15))
        }
        var noMode = S.codex("PermissionRequest")
        noMode["permission_mode"] = nil
        let released: [[String: Any]] = [
            S.codex("PermissionRequest", input: ["command": "curl example.com", "description": "network-access example.com"]),
            S.codex("PermissionRequest", tool: "mcp__notes__write", input: ["title": "x"]),
            S.codex("PermissionRequest", tool: "request_permissions", input: ["reason": "network", "permissions": [:]]),
            S.codex("PermissionRequest", tool: "write_stdin", input: ["chars": "y\n"]),
            S.codex("PermissionRequest", agent: "k1"),
            S.codex("PermissionRequest", mode: "bypassPermissions"),
            noMode,
        ]
        for object in released {
            #expect(AttentionPolicy.brokerHold(Self.line(object), object, answersSubagents: true, answersCodex: true) == .released,
                    "\(object["tool_name"] ?? "") \(object["permission_mode"] ?? "none")")
        }
        // A Bash command whose justification is not a network approval's is still the command's.
        let why = S.codex("PermissionRequest", input: ["command": "make test", "description": "Run the tests outside the sandbox"])
        #expect(AttentionPolicy.brokerHold(Self.line(why), why, answersSubagents: false, answersCodex: true).held)
        // Claude's main thread is held as before, whatever the Codex switch says; its subagents only with theirs.
        let claude = S.claude("PermissionRequest", tool: "Bash", input: S.push)
        let claudeLine = HookRequestLine(source: "claude", input: try! JSONSerialization.data(withJSONObject: claude), entrypoint: "cli")
        #expect(AttentionPolicy.brokerHold(claudeLine, claude, answersSubagents: false, answersCodex: true) == BrokerHold(held: true))
        let child = S.claude("PermissionRequest", tool: "Bash", input: S.push, agent: "a1")
        let childLine = HookRequestLine(source: "claude", input: try! JSONSerialization.data(withJSONObject: child), entrypoint: "cli")
        #expect(AttentionPolicy.brokerHold(childLine, child, answersSubagents: false, answersCodex: true) == .released)
    }

    /// Codex's hook takes `allow`, or `deny` with a message, and nothing else (`PermissionRequestDecisionWire` denies
    /// unknown fields and fails a hook that sends `updatedInput`, `updatedPermissions` or `interrupt`).
    @Test
    func anIslandAnswerIsOnlyWhatCodexsHookTakes() throws {
        #expect(SessionEngine.codexDecision(for: .allowOnce()) == .allow)
        #expect(SessionEngine.codexDecision(for: .deny(message: "keep the cache")) == .deny(message: "keep the cache"))
        #expect(SessionEngine.codexDecision(for: .deny()) == .deny(message: ApprovalChoices.denyMessage))
        #expect(SessionEngine.codexDecision(for: .deny(message: "stop", interrupt: true)) == nil)
        #expect(SessionEngine.codexDecision(for: .allowOnce(updatedInput: .object(["command": .string("ls")]))) == nil)
        let rule = ClaudePermissionUpdate.addRules(destination: .localSettings, rules: [ClaudePermissionRuleValue(toolName: "Bash")], behavior: .allow)
        #expect(SessionEngine.codexDecision(for: .allowOnce(updatedPermissions: [rule])) == nil)
        // As upstream's encoder prints them: exactly the fields Codex's schema allows.
        for (decision, expected) in [(CodexPermissionRequestDecision.allow, #"{"behavior":"allow"}"#),
                                     (.deny(message: "no"), #"{"behavior":"deny","message":"no"}"#)] {
            let data = try #require(try CodexHookOutputEncoder.standardOutput(for: .codexHookDirective(.permissionRequest(decision))))
            let printed = String(decoding: data, as: UTF8.self)
            #expect(printed == #"{"continue":true,"hookSpecificOutput":{"decision":\#(expected),"hookEventName":"PermissionRequest"}}"# + "\n")
        }
    }

    // MARK: Held

    /// Held: confirmed and sounded at once (Codex sends no notice), answerable, its hold's end on the card; Yes and No go
    /// over its own connection as Codex's decision; Always allow and No and stop send nothing.
    @Test
    func aHeldRequestIsConfirmedAtOnceAndAnsweredOverItsOwnConnection() async throws {
        let s = scene()
        let id = try #require(s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil))
        #expect(s.broker.held.current == [id])
        await s.settle { s.head("c1") != nil }
        let head = try #require(s.head("c1"))
        #expect(head.id == id && head.isConfirmed && head.isAnswerable && head.channel == .answer(.broker))
        #expect(head.holdEndsAt == head.openedAt.addingTimeInterval(CodexHold.limit) && head.isHeldForIsland)
        #expect(s.needsYou == [.needsYou(sessionID: "c1")] && s.glyph("c1") == "!")
        for refused in [ApprovalDecision.alwaysAllow, .denyAndStop] {
            #expect(await s.engine.approve(requestID: id, decision: refused) == .nothingToSend)
        }
        #expect(s.broker.answers.current.isEmpty && s.broker.held.current == [id])
        #expect(await s.engine.approve(requestID: id, decision: .allowOnce) == .sent)
        #expect(s.broker.answers.current.map(\.response) == [.codexHookDirective(.permissionRequest(.allow))])
        #expect(!s.isOpen(id) && s.phase("c1") == .running)

        let second = try #require(s.hook(S.codex("PermissionRequest", input: ["command": "rm -rf build"]), source: "codex", entrypoint: nil))
        await s.settle { s.head("c1")?.id == second }
        #expect(await s.engine.approve(requestID: second, decision: .denyWithReason("keep the build")) == .sent)
        #expect(s.broker.answers.current.last?.response == .codexHookDirective(.permissionRequest(.deny(message: "keep the build"))))
        #expect(s.engine.attentionTally.codexHolds.isEmpty)
    }

    /// Held only while the island shows it, as a subagent's (P350): not shown within the grace, released; at the limit,
    /// released; either way its card turns read-only (Open, ✕) and stays until its call's own evidence.
    @Test
    func aHoldEndsWhenTheIslandStopsShowingItOrAtItsLimit() async throws {
        let s = scene()
        let unseen = try #require(s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil))
        await s.settle { s.head("c1") != nil }
        s.at(CodexHold.showGrace + 0.1)
        #expect(s.broker.released.current == [unseen] && s.head("c1")?.isAnswerable == false && s.head("c1")?.isConfirmed == true)
        s.rollout("c1", [T.exec("call_1", at: 1), R.item("function_call_output", ["call_id": "call_1", "output": "ok"], at: 3)])
        #expect(!s.isOpen(unseen))

        let shown = try #require(s.hook(S.codex("PermissionRequest", input: ["command": "make lint"]), source: "codex", entrypoint: nil))
        await s.settle { s.head("c1")?.id == shown }
        s.engine.islandShows(requestID: shown)
        s.at(s.t + CodexHold.limit - 1)
        #expect(s.broker.held.current == [shown])
        s.at(s.t + 1.5)
        #expect(s.broker.released.current.last == shown && s.head("c1")?.channel == .open && s.head("c1")?.holdEndsAt == nil)
        #expect(await s.engine.approve(requestID: shown, decision: .allowOnce) == .nothingToSend)
        #expect(s.engine.attentionTally.codexHolds == ["notShown": 1, "timeUp": 1])
    }

    // MARK: Handed back before any card

    /// The owner looking at where Codex asks keeps the prompt there: the session's own tab in front, or the Codex app for
    /// its threads. Released at once and shown as with the switch off (read-only, from 8 s).
    @Test
    func theTabTheOwnerLooksAtKeepsTheApprovalInCodex() async throws {
        let tab = scene(frontmost: true)
        let app = scene(app: true)
        app.front.update { $0 = ExactJump.codexBundleID }
        for s in [tab, app] {
            let id = try #require(s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil))
            await s.settle { s.request(id) != nil }
            #expect(s.broker.released.current == [id] && s.request(id)?.isAnswerable == false && s.request(id)?.state == .pending)
            s.at(8)
            #expect(s.head("c1")?.id == id && s.head("c1")?.isAnswerable == false)
            #expect(s.engine.attentionTally.codexHolds == ["focused": 1])
        }
        // The Codex app in front says nothing about a terminal session: held.
        let other = scene()
        other.front.update { $0 = ExactJump.codexBundleID }
        let id = try #require(other.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil))
        await other.settle { other.head("c1") != nil }
        #expect(other.head("c1")?.id == id && other.head("c1")?.isAnswerable == true)
    }

    /// Where the tab probe cannot tell the session's tab (it reads Ghostty, Terminal and iTerm by tab, outside tmux), the
    /// host app in front counts as the owner looking: Codex in an IDE (its extension, or the CLI in the IDE's terminal), a
    /// terminal the probe does not read, a tmux pane. Released at once, before any card; another app in front holds it
    /// (P496).
    @Test
    func anIDEOrATerminalTheProbeCannotReadInFrontKeepsTheApprovalInCodex() async throws {
        let cases: [(host: String, tmux: Bool)] = [("com.microsoft.VSCode", false), ("dev.warp.Warp-Stable", false),
                                                   ("net.kovidgoyal.kitty", false), ("com.googlecode.iterm2", true)]
        for (host, tmux) in cases {
            for inFront in [true, false] {
                let s = scene()
                s.front.update { $0 = inFront ? host : "com.apple.Safari" }
                if tmux {
                    s.engine.ingest(note: HookContextNote(version: HookContextNote.currentVersion, event: "SessionStart", sessionID: "c1",
                                                          tmux: "/private/tmp/tmux-501/default,4242,0", tmuxPane: "%3", agentPID: 900,
                                                          hostBundleID: host))
                }
                let id = try #require(s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil, host: host))
                await s.settle { s.request(id) != nil }
                if inFront {
                    #expect(s.broker.released.current == [id] && s.request(id)?.isAnswerable == false, "\(host) tmux \(tmux)")
                    #expect(s.engine.attentionTally.codexHolds == ["focused": 1], "\(host) tmux \(tmux)")
                } else {
                    #expect(s.broker.released.current.isEmpty && s.request(id)?.isAnswerable == true, "\(host) tmux \(tmux) behind")
                }
            }
        }
        #expect(CodexHold.look(place: .terminal, host: nil, inTmux: false, frontmost: "net.kovidgoyal.kitty") == .focused)
        #expect(CodexHold.look(place: .terminal, host: nil, inTmux: false, frontmost: "com.apple.Safari") == .probeTab)
        #expect(CodexHold.look(place: .terminal, host: "com.mitchellh.ghostty", inTmux: false, frontmost: "com.mitchellh.ghostty") == .probeTab)
        #expect(CodexHold.look(place: .terminal, host: nil, inTmux: true, frontmost: "com.mitchellh.ghostty") == .focused)
    }

    /// An island Allow must never settle what Codex's reviewer would: an auto reviewer, a strict-review turn, or a reviewer
    /// that cannot be read is never held; the first two are not shown at all (as with the switch off), the last read-only.
    @Test
    func aReviewerThatIsNotTheOwnerOrCannotBeReadIsNeverHeld() async throws {
        let auto = scene(reviewer: "auto_review")
        let strict = scene()
        strict.rollout("c1", [CodexAttentionTests.call("request_permissions", "call_P", arguments: "{}"),
                              CodexAttentionTests.output("call_P", #"{"permissions":{},"scope":"turn","strict_auto_review":true}"#)])
        for s in [auto, strict] {
            let id = try #require(s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil))
            await s.settle { !s.broker.released.current.isEmpty }
            s.at(10)
            #expect(s.broker.released.current == [id] && s.engine.openRequests.isEmpty && s.signals.isEmpty)
            #expect(s.engine.attentionTally.codexHolds == ["reviewer": 1])
        }
        let unknown = scene(reviewer: nil)
        let id = try #require(unknown.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil))
        await unknown.settle { unknown.request(id) != nil }
        #expect(unknown.broker.released.current == [id] && unknown.request(id)?.isAnswerable == false)
        #expect(unknown.engine.attentionTally.codexHolds == ["unknownReviewer": 1])
    }

    /// A helper that ended before the card was entered (Esc in Codex) is not held when its card comes; an entry past
    /// `showGrace` is handed back; a subagent's is never held; the switch off never holds.
    @Test
    func nothingIsHeldThatCodexNoLongerWaitsOnOrThatCameLate() async throws {
        let ended = scene()
        let first = try #require(ended.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil))
        #expect(ended.broker.end(first))
        ended.engine.brokeredRequestEnded(first)
        await ended.settle { ended.request(first) != nil }
        #expect(ended.request(first)?.isAnswerable == false && ended.engine.attentionTally.codexHolds == ["hookEnded": 1])

        let late = scene()
        let second = try #require(late.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil))
        late.at(CodexHold.showGrace)
        #expect(late.broker.released.current == [second])
        await late.settle { late.request(second) != nil }
        #expect(late.request(second)?.isAnswerable == false && late.engine.attentionTally.codexHolds == ["late": 1])

        let off = scene(on: false)
        let third = try #require(off.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil))
        #expect(off.broker.held.current.isEmpty)
        await off.settle()
        #expect(off.request(third)?.isAnswerable == false && off.engine.attentionTally.codexHolds.isEmpty)
    }

    /// The switch going off (or Window mode) ends every Codex hold at once, and leaves a Claude subagent's hold to its own
    /// switch; Answer subagents going off leaves a Codex hold alone.
    @Test
    func eachSwitchEndsOnlyItsOwnHolds() async throws {
        let s = scene()
        s.engine.answersSubagents = true
        s.begin("s1")
        let codex = try #require(s.hook(S.codex("PermissionRequest"), source: "codex", entrypoint: nil))
        let claude = try #require(s.hook(S.claude("PermissionRequest", tool: "Bash", input: S.push, agent: "a1")))
        await s.settle { s.head("c1") != nil && s.head("s1") != nil }
        #expect(s.head("c1")?.isHeldForIsland == true && s.head("s1")?.isHeldForIsland == true)
        s.engine.answersSubagents = false
        #expect(s.broker.released.current == [claude] && s.head("c1")?.isHeldForIsland == true)
        s.engine.answersCodex = false
        #expect(s.broker.released.current == [claude, codex] && s.head("c1")?.isAnswerable == false)
        #expect(s.engine.attentionTally.codexHolds == ["switchedOff": 1] && s.engine.attentionTally.subagentHolds == ["switchedOff": 1])
    }
}
