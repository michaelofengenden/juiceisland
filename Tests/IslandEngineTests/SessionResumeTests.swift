import Foundation
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Route (b) of a folded session (wave 6, P1325 to P1349): a reply goes on through the agent's own resume once the tab
/// is gone, and Open in terminal reopens the conversation. Every run here is an injected stand-in and every window an
/// injected opener: no test starts a CLI, sends a prompt or opens a window. Fixtures only.
@MainActor
struct SessionResumeTests {
    typealias F = EngineFixtures

    static let claudeID = "8f2c3a1e-5b7d-4a6b-9c1d-2e3f4a5b6c7d"
    static let codexID = "019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b"
    static let home = "/tmp/ji-resume"
    static let lab = "\(home)/.claude-lab"
    static let side = "\(home)/.codex-side"
    static let folder = "/tmp/ji-resume/project"
    nonisolated static let folders: Set<String> = ["/tmp/ji-resume/project", "/tmp/ji-resume/.claude-lab", "/tmp/ji-resume/.codex-side", "/tmp/ji-resume/.claude"]

    /// A run as the resumer drives it: records each signal, and ends when the test says so (or at SIGINT, when given an
    /// exit for it).
    final class FakeRun: ResumeProcess, @unchecked Sendable {
        let pid: Int32
        let interrupts = F.Box(0)
        let terminates = F.Box(0)
        private let lock = NSLock()
        private var ended: ResumeExit?
        private var waiters: [CheckedContinuation<ResumeExit, Never>] = []
        private let exitOnInterrupt: ResumeExit?

        init(pid: Int32, exitOnInterrupt: ResumeExit? = nil) {
            self.pid = pid
            self.exitOnInterrupt = exitOnInterrupt
        }

        var hasExited: Bool { lock.withLock { ended != nil } }

        func interrupt() {
            interrupts.update { $0 += 1 }
            if let exitOnInterrupt { end(exitOnInterrupt) }
        }

        func terminate() { terminates.update { $0 += 1 } }

        func exit() async -> ResumeExit {
            await withCheckedContinuation { continuation in
                let done: ResumeExit? = lock.withLock {
                    if let ended { return ended }
                    waiters.append(continuation)
                    return nil
                }
                if let done { continuation.resume(returning: done) }
            }
        }

        func end(_ exit: ResumeExit) {
            let waiting: [CheckedContinuation<ResumeExit, Never>] = lock.withLock {
                guard ended == nil else { return [] }
                ended = exit
                defer { waiters = [] }
                return waiters
            }
            for waiter in waiting { waiter.resume(returning: exit) }
        }
    }

    /// The resumer over a headless engine, with a starter that records each command and hands out `FakeRun`s.
    final class Rig {
        let engine: SessionEngine
        let resumer: SessionResumer
        let commands: F.Box<[ResumeCommand]>
        let runs: F.Box<[FakeRun]>
        let windows: F.Box<[FreshSessionLaunch]>
        let alive: F.Box<Set<Int32>>
        let startError: F.Box<ResumeStartError?>

        @MainActor
        init(starts: Bool = true, opens: Bool = true, usual: FreshSessionLaunch.Host = .ghostty,
             environment: [String: String] = ["SSH_AUTH_SOCK": "/tmp/ji-resume/agent.sock", "SHELL": "/bin/zsh",
                                               "__CFBundleIdentifier": "com.ofengenden.juice", "CLAUDE_CODE_ENTRYPOINT": "cli"],
             exitOnInterrupt: ResumeExit? = nil) {
            let commands = F.Box<[ResumeCommand]>([]), runs = F.Box<[FakeRun]>([]), windows = F.Box<[FreshSessionLaunch]>([])
            let alive = F.Box<Set<Int32>>([]), startError = F.Box<ResumeStartError?>(nil)
            self.commands = commands
            self.runs = runs
            self.windows = windows
            self.alive = alive
            self.startError = startError
            let engine = F.engine(configure: { dependencies in
                dependencies.processExists = { alive.current.contains($0) }
                // A jump never reaches a real app: every runner call fails here.
                var runner = JumpRunner()
                runner.appURL = { _ in nil }
                runner.isAppRunning = { _ in false }
                runner.appleScript = { _, _ in throw CocoaError(.featureUnsupported) }
                runner.open = { _, _ in throw CocoaError(.featureUnsupported) }
                runner.command = { _, _, _ in false }
                runner.capture = { _, _, _ in throw CocoaError(.featureUnsupported) }
                runner.isExecutable = { _ in false }
                runner.frontmostBundleID = { nil }
                runner.appForPID = { _ in nil }
                dependencies.jumpRunner = runner
            })
            self.engine = engine
            var dependencies = SessionResumer.Dependencies()
            if starts {
                dependencies.start = { command in
                    if let error = startError.current { throw error }
                    commands.update { $0.append(command) }
                    var made: FakeRun!
                    runs.update {
                        made = FakeRun(pid: Int32(7000 + $0.count), exitOnInterrupt: exitOnInterrupt)
                        $0.append(made)
                    }
                    return made
                }
            }
            if opens {
                dependencies.openWindow = { launch in
                    windows.update { $0.append(launch) }
                    return true
                }
            }
            dependencies.isFolder = { SessionResumeTests.folders.contains($0) }
            dependencies.usualHost = { usual }
            dependencies.environment = { environment }
            dependencies.sleep = { _ in }
            dependencies.quitGrace = 0
            resumer = SessionResumer(engine: engine, dependencies: dependencies)
        }

        /// A Claude session in Terminal that finished its turn and whose tab then closed (SessionEnd).
        @MainActor
        func endedClaude(_ id: String = SessionResumeTests.claudeID, pid: Int32 = 4242, ended: Bool = true,
                         host: String = ExactJump.terminalBundleID, profile: String = SessionResumeTests.lab) {
            engine.ingest(F.started(id, transcript: "\(profile)/projects/-tmp-ji-resume-project/\(id).jsonl",
                                    cwd: SessionResumeTests.folder), ingress: .bridge)
            engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: id, agentPID: pid, hostBundleID: host,
                                                entrypoint: "cli", source: "claude"))
            engine.ingest(F.prompt(id), ingress: .bridge)
            engine.ingest(F.completed(id), ingress: .bridge)
            if ended {
                engine.ingest(.sessionCompleted(SessionCompleted(sessionID: id, summary: "Done.", timestamp: F.now, isSessionEnd: true)),
                              ingress: .bridge)
            }
        }

        /// A Codex CLI session in its own home whose agent quit.
        @MainActor
        func endedCodex(_ id: String = SessionResumeTests.codexID) {
            engine.ingest(F.started(id, tool: .codex, transcript: "\(SessionResumeTests.side)/sessions/2026/10/05/rollout-\(id).jsonl",
                                    cwd: SessionResumeTests.folder, terminal: "Terminal"), ingress: .bridge)
            engine.ingest(F.prompt(id), ingress: .bridge)
            engine.ingest(.sessionCompleted(SessionCompleted(sessionID: id, summary: "Done.", timestamp: F.now, isSessionEnd: true)),
                          ingress: .bridge)
        }

        /// Lets the main actor run what the runs' ends handed to it.
        @MainActor
        func settle(until condition: () -> Bool) async {
            for _ in 0..<200 where !condition() { await Task.yield() }
        }
    }

    static func claudeResult(_ text: String, error: Bool = false) -> String {
        let object: [String: Any] = ["type": "result", "subtype": error ? "error_during_execution" : "success", "is_error": error,
                                     "result": text, "session_id": claudeID]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    // MARK: P1325 the commands

    @Test
    func claudesReplyIsAPrintModeResumeOfTheSameSessionWithTheTextOnStdin() {
        let command = ResumeCommand.make(provider: .claude, sessionID: Self.claudeID, text: "-v and run the tests", folder: Self.folder,
                                         profile: Self.lab, inherited: ["SSH_AUTH_SOCK": "/tmp/ji-resume/agent.sock",
                                                                        "__CFBundleIdentifier": "com.ofengenden.juice",
                                                                        "CLAUDE_CODE_ENTRYPOINT": "cli", "OPEN_ISLAND_SKIP_HOOKS": "1"],
                                         home: Self.home, user: "tester", temporary: "/tmp/ji-resume/tmp")
        #expect(command.tool == "claude")
        // No `--fork-session`: the same id and transcript. The text is never an argument, so "-v" stays text.
        #expect(command.arguments == ["-p", "--resume", Self.claudeID, "--output-format", "json"])
        #expect(command.input == "-v and run the tests")
        #expect(command.folder == Self.folder)
        #expect(command.environment == ["HOME": Self.home, "USER": "tester", "LOGNAME": "tester", "LANG": "en_US.UTF-8",
                                        "TMPDIR": "/tmp/ji-resume/tmp", "TERM": "dumb", "SHELL": "/bin/zsh",
                                        "SSH_AUTH_SOCK": "/tmp/ji-resume/agent.sock", "CLAUDE_CONFIG_DIR": Self.lab])
        // Hooks on: none of the skip switches, whatever the app's own environment holds (P1326).
        for key in CLIEnvironment.islandSkipKeys { #expect(command.environment[key] == nil) }
        // The default folder runs with no variable, as the CLI finds its login differently once it is set.
        let plain = ResumeCommand.make(provider: .claude, sessionID: Self.claudeID, text: "go on", folder: Self.folder,
                                       profile: "\(Self.home)/.claude", inherited: [:], home: Self.home)
        #expect(plain.environment["CLAUDE_CONFIG_DIR"] == nil && plain.environment["SSH_AUTH_SOCK"] == nil)
    }

    @Test
    func codexsReplyIsAnExecResumeOfTheSameThreadReadFromStdin() {
        let command = ResumeCommand.make(provider: .codex, sessionID: Self.codexID, text: "/review", folder: Self.folder,
                                         profile: Self.side, inherited: [:], home: Self.home, user: "tester")
        #expect(command.tool == "codex")
        #expect(command.arguments == ["exec", "resume", "--json", Self.codexID, "-"])
        #expect(command.input == "/review")
        #expect(command.environment["CODEX_HOME"] == Self.side && command.environment["CLAUDE_CONFIG_DIR"] == nil)
        let plain = ResumeCommand.make(provider: .codex, sessionID: Self.codexID, text: "x", folder: Self.folder,
                                       profile: "\(Self.home)/.codex", inherited: [:], home: Self.home)
        #expect(plain.environment["CODEX_HOME"] == nil)
    }

    @Test
    func openInTerminalsLineIsTheInteractiveResumeEachWordQuoted() {
        #expect(ResumeCommand.terminalLine(provider: .claude, sessionID: Self.claudeID, folder: Self.folder, profile: Self.lab,
                                           home: Self.home)
                == "cd '\(Self.folder)' && CLAUDE_CONFIG_DIR='\(Self.lab)' claude --resume '\(Self.claudeID)'")
        #expect(ResumeCommand.terminalLine(provider: .claude, sessionID: Self.claudeID, folder: "/tmp/it's here",
                                           profile: "\(Self.home)/.claude", home: Self.home)
                == "cd '/tmp/it'\\''s here' && claude --resume '\(Self.claudeID)'")
        #expect(ResumeCommand.terminalLine(provider: .codex, sessionID: Self.codexID, folder: Self.folder, profile: Self.side,
                                           home: Self.home)
                == "cd '\(Self.folder)' && CODEX_HOME='\(Self.side)' codex resume '\(Self.codexID)'")
    }

    /// On a stopped card the new window carries the turn on (P1439): the interactive resume takes the words as its first
    /// prompt, quoted as every other word, so the agent goes on in the window rather than waiting at its prompt.
    @Test
    func aStoppedTurnsLineCarriesItOnWithTheWordsTheCardShows() {
        #expect(ResumeCommand.terminalLine(provider: .claude, sessionID: Self.claudeID, folder: Self.folder, profile: Self.lab,
                                           prompt: SessionEngine.continuePrompt, home: Self.home)
                == "cd '\(Self.folder)' && CLAUDE_CONFIG_DIR='\(Self.lab)' claude --resume '\(Self.claudeID)' 'Continue where you left off.'")
        #expect(ResumeCommand.terminalLine(provider: .codex, sessionID: Self.codexID, folder: Self.folder, profile: Self.side,
                                           prompt: SessionEngine.continuePrompt, home: Self.home)
                == "cd '\(Self.folder)' && CODEX_HOME='\(Self.side)' codex resume '\(Self.codexID)' 'Continue where you left off.'")
        // No words, or only blanks: the conversation alone.
        #expect(ResumeCommand.terminalLine(provider: .claude, sessionID: Self.claudeID, folder: Self.folder, profile: Self.lab,
                                           prompt: "  ", home: Self.home)
                == "cd '\(Self.folder)' && CLAUDE_CONFIG_DIR='\(Self.lab)' claude --resume '\(Self.claudeID)'")
    }

    @Test
    func openInTerminalCarriesTheTurnOnOnlyWhenAsked() async {
        let rig = Rig()
        rig.endedClaude()
        #expect(await rig.resumer.openInTerminal(Self.claudeID, continuing: SessionEngine.continuePrompt))
        #expect(rig.windows.current.last?.line.hasSuffix("claude --resume '\(Self.claudeID)' 'Continue where you left off.'") == true)
        #expect(rig.engine.foldNotes.last?.said == "opened · a new window with the resume, carrying the turn on")
        #expect(await rig.resumer.openInTerminal(Self.claudeID, continuing: nil))
        #expect(rig.windows.current.last?.line.hasSuffix("claude --resume '\(Self.claudeID)'") == true)
        #expect(rig.engine.foldNotes.last?.said == "opened · a new window with the resume")
        // While its agent still runs, the plain jump: no words are typed anywhere.
        rig.endedClaude(pid: 5151, ended: false)
        rig.alive.update { $0.insert(5151) }
        #expect(await rig.resumer.openInTerminal(Self.claudeID, continuing: SessionEngine.continuePrompt) == false)
        #expect(rig.windows.current.count == 2 && rig.commands.current.isEmpty)
    }

    // MARK: P1440 Codex's writer lock

    /// Codex allows one writer per thread, and its shared daemon may hold a thread up to 30 minutes after its tab closed:
    /// `codex exec resume` is then refused with "already has an active writer". The card says so plainly, not "Failed".
    @Test
    func codexsWriterLockSaysCodexStillHoldsIt() {
        let refused = ResumeExit(status: 1, output: ResumeOutput(provider: .codex),
                                 errorTail: "Error: thread \(Self.codexID) already has an active writer\n")
        #expect(refused.heldElsewhere)
        #expect(refused.problem == "Codex still holds this conversation; try again later")
        let inJSON = ResumeExit(status: 1, output: ResumeOutput(provider: .codex, lines: [
            #"{"type":"error","message":"thread already has an active writer"}"#,
        ]))
        #expect(inJSON.heldElsewhere && inJSON.problem == "Codex still holds this conversation; try again later")
        // Any other failure, and Claude's, read as before.
        let other = ResumeExit(status: 1, output: ResumeOutput(provider: .codex), errorTail: "Error: no rollout found\n")
        #expect(!other.heldElsewhere && other.problem == "Failed · Error: no rollout found")
        let claude = ResumeExit(status: 1, output: ResumeOutput(provider: .claude), errorTail: "already has an active writer")
        #expect(!claude.heldElsewhere)
    }

    // MARK: P1331 what a run printed

    @Test
    func aRunsOutputGivesItsAnswerOrItsFailure() {
        let done = ResumeOutput(provider: .claude, lines: ["", "not json", Self.claudeResult("All 50 runs pass.")])
        #expect(done.answer == "All 50 runs pass." && done.failure == nil && done.finished)
        #expect(ResumeExit(status: 0, output: done).problem == nil)

        let failed = ResumeOutput(provider: .claude, lines: [Self.claudeResult("Credit balance is too low", error: true)])
        #expect(failed.answer == nil && failed.failure == "Credit balance is too low")
        #expect(ResumeExit(status: 1, output: failed).problem == "Failed · Credit balance is too low")

        // Nothing on stdout: stderr's first line says why.
        let missing = ResumeExit(status: 1, output: ResumeOutput(provider: .claude),
                                 errorTail: "\nNo conversation found with session ID: \(Self.claudeID)\n")
        #expect(missing.problem == "Failed · No conversation found with session ID: \(Self.claudeID)")
        #expect(ResumeExit(status: 2, output: ResumeOutput(provider: .claude)).problem == "Failed · it stopped with an error (2)")
        let long = ResumeExit(status: 1, output: ResumeOutput(provider: .claude), errorTail: String(repeating: "x", count: 300))
        #expect(long.problem?.count == "Failed · ".count + 120 && long.problem?.hasSuffix("…") == true)

        let codex = ResumeOutput(provider: .codex, lines: [
            #"{"type":"thread.started","thread_id":"\#(Self.codexID)"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"error","message":"Reconnecting... 1/5"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"thinking"}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Renamed it."}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1}}"#,
        ])
        // A retry the turn outlived is no failure.
        #expect(codex.answer == "Renamed it." && codex.finished && ResumeExit(status: 0, output: codex).problem == nil)
        let codexFailed = ResumeOutput(provider: .codex, lines: [
            #"{"type":"turn.started"}"#, #"{"type":"turn.failed","error":{"message":"usage limit reached"}}"#,
        ])
        #expect(ResumeExit(status: 1, output: codexFailed).problem == "Failed · usage limit reached")
    }

    // MARK: P1332 when a reply may resume

    @Test
    func onlyAClaudeOrCodexSessionWhoseAgentIsGoneResumes() {
        let rig = Rig()
        rig.endedClaude()
        #expect(rig.resumer.availability(for: Self.claudeID) == .resume(note: nil))
        rig.endedCodex()
        #expect(rig.resumer.availability(for: Self.codexID) == .resume(note: SessionResumer.codexNote))

        // The agent's own process still runs (stopped with Ctrl-Z, or in a terminal Juice cannot type into): no second
        // writer of its transcript.
        let running = "1c9b2a3d-0e1f-4a5b-8c7d-6e5f4a3b2c1d"
        rig.endedClaude(running, pid: 5151, ended: false)
        rig.alive.update { $0.insert(5151) }
        #expect(rig.resumer.availability(for: running) == .openOnly)
        // Gone: it may.
        rig.alive.update { $0.remove(5151) }
        #expect(rig.resumer.availability(for: running) == .resume(note: nil))

        // Another agent, an id that is not a UUID, a folder or a profile not on this Mac: Open in terminal to reply.
        let gemini = "2d3e4f5a-6b7c-4d8e-9f0a-1b2c3d4e5f6a"
        rig.engine.ingest(F.started(gemini, tool: .geminiCLI, cwd: Self.folder), ingress: .bridge)
        #expect(rig.resumer.availability(for: gemini) == .openOnly)
        rig.endedClaude("claude-process:77")
        #expect(rig.resumer.availability(for: "claude-process:77") == .openOnly)
        let elsewhere = "3e4f5a6b-7c8d-4e9f-8a0b-1c2d3e4f5a6b"
        rig.endedClaude(elsewhere, profile: "\(Self.home)/.claude-gone")
        #expect(rig.resumer.availability(for: elsewhere) == .openOnly)
        #expect(rig.resumer.availability(for: "4f5a6b7c-8d9e-4f0a-9b1c-2d3e4f5a6b7c") == .openOnly)
    }

    @Test
    func aCodexAppThreadNeverResumesInTheCLI() {
        let rig = Rig()
        rig.endedCodex()
        var session = rig.engine.state.session(id: Self.codexID)!
        session.isCodexAppSession = true
        rig.engine.replace(session)
        #expect(rig.resumer.availability(for: Self.codexID) == .openOnly)
    }

    // MARK: P1325, P1333 a run

    @Test
    func aReplyStartsOneRunThatTheIslandFollowsUntilItEnds() async {
        let rig = Rig()
        rig.endedClaude()
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "  now the docs\n") == .sent)
        #expect(rig.commands.current.map(\.arguments) == [["-p", "--resume", Self.claudeID, "--output-format", "json"]])
        #expect(rig.commands.current.first?.input == "now the docs")
        #expect(rig.commands.current.first?.environment["CLAUDE_CONFIG_DIR"] == Self.lab)
        // Only the ssh agent's socket and the shell come from the app's environment: never its bundle id or entrypoint.
        #expect(rig.commands.current.first?.environment["__CFBundleIdentifier"] == nil)
        #expect(rig.commands.current.first?.environment["CLAUDE_CODE_ENTRYPOINT"] == nil)
        #expect(rig.resumer.isRunning(Self.claudeID))
        #expect(rig.resumer.runs[Self.claudeID]?.pid == 7000)
        // One run per session: a second Return while it runs sends nothing (the card holds it).
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "and the tests") == .nothingToSend)
        #expect(rig.commands.current.count == 1)
        #expect(rig.resumer.availability(for: Self.claudeID) == .resume(note: nil))
        // Empty text sends nothing either.
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: " \n ") == .nothingToSend)

        rig.runs.current[0].end(ResumeExit(status: 0, output: ResumeOutput(provider: .claude, lines: [Self.claudeResult("Docs updated.")])))
        await rig.settle { !rig.resumer.isRunning(Self.claudeID) }
        #expect(!rig.resumer.isRunning(Self.claudeID))
        #expect(rig.resumer.answer(Self.claudeID) == "Docs updated." && rig.resumer.problem(Self.claudeID) == nil)
        #expect(!rig.engine.islandResumes.isRunning(Self.claudeID) && rig.engine.islandResumes.wasResumed(Self.claudeID))
        // The next reply starts the next run.
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "thanks") == .sent)
        #expect(rig.commands.current.count == 2)
    }

    @Test
    func aRunThatEndsBadlySaysWhyUntilTheNextSend() async {
        let rig = Rig()
        rig.endedClaude()
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "go on") == .sent)
        rig.runs.current[0].end(ResumeExit(status: 1, output: ResumeOutput(provider: .claude),
                                           errorTail: "No conversation found with session ID: \(Self.claudeID)"))
        await rig.settle { !rig.resumer.isRunning(Self.claudeID) }
        #expect(rig.resumer.problem(Self.claudeID) == "Failed · No conversation found with session ID: \(Self.claudeID)")
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "again") == .sent)
        #expect(rig.resumer.problem(Self.claudeID) == nil)
    }

    @Test
    func aRunThatCannotStartIsNotSentAndSaysWhy() async {
        let rig = Rig()
        rig.endedClaude()
        rig.startError.update { $0 = .toolMissing("claude") }
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "go on") == .notSent)
        #expect(rig.resumer.problem(Self.claudeID) == "Not sent · Claude Code not found")
        #expect(!rig.resumer.isRunning(Self.claudeID) && !rig.engine.islandResumes.isRunning(Self.claudeID))
        rig.startError.update { $0 = .couldNotStart }
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "go on") == .notSent)
        #expect(rig.resumer.problem(Self.claudeID) == "Not sent · it could not start")
    }

    /// A headless engine with no runner given starts nothing and opens nothing: no test can start a CLI.
    @Test
    func aHeadlessEngineRunsNothing() async {
        let rig = Rig(starts: false, opens: false)
        rig.endedClaude()
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "go on") == .notSent)
        #expect(rig.resumer.problem(Self.claudeID) == "Not sent")
        #expect(await rig.resumer.openInTerminal(Self.claudeID) == false)
        #expect(rig.commands.current.isEmpty && rig.windows.current.isEmpty)
    }

    /// Nothing but `continueConversation` starts a run: asking, opening, stopping and ending never do (P1334).
    @Test
    func aRunNeverStartsByItself() async {
        let rig = Rig()
        rig.endedClaude()
        rig.endedCodex()
        _ = rig.resumer.availability(for: Self.claudeID)
        _ = rig.resumer.isRunning(Self.codexID)
        rig.resumer.stop(Self.claudeID)
        rig.resumer.endAll()
        _ = await rig.resumer.openInTerminal(Self.codexID)
        #expect(rig.commands.current.isEmpty)
    }

    // MARK: P1335 Stop, and the app's quit

    @Test
    func stopInterruptsThenTerminatesARunThatOutlivesIt() async {
        let rig = Rig()
        rig.endedClaude()
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "go on") == .sent)
        let run = rig.runs.current[0]
        rig.resumer.stop(Self.claudeID)
        rig.resumer.stop(Self.claudeID)
        #expect(run.interrupts.current == 1)
        await rig.settle { run.terminates.current == 1 }
        #expect(run.terminates.current == 1)
        // It stays Working until the process has exited; a Stop leaves no problem line.
        #expect(rig.resumer.isRunning(Self.claudeID))
        run.end(ResumeExit(status: 143, output: ResumeOutput(provider: .claude)))
        await rig.settle { !rig.resumer.isRunning(Self.claudeID) }
        #expect(!rig.resumer.isRunning(Self.claudeID) && rig.resumer.problem(Self.claudeID) == nil)
    }

    @Test
    func aRunThatEndsAtItsInterruptIsNotTerminated() async {
        let rig = Rig(exitOnInterrupt: ResumeExit(status: 130, output: ResumeOutput(provider: .claude)))
        rig.endedClaude()
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "go on") == .sent)
        let run = rig.runs.current[0]
        rig.resumer.stop(Self.claudeID)
        await rig.settle { !rig.resumer.isRunning(Self.claudeID) }
        for _ in 0..<20 { await Task.yield() }
        #expect(run.interrupts.current == 1 && run.terminates.current == 0)
    }

    @Test
    func quittingEndsEveryRun() async {
        let rig = Rig()
        rig.endedClaude()
        rig.endedCodex()
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "a") == .sent)
        #expect(await rig.resumer.continueConversation(Self.codexID, text: "b") == .sent)
        rig.resumer.endAll()
        #expect(rig.runs.current.map(\.interrupts.current) == [1, 1])
        #expect(rig.runs.current.map(\.terminates.current) == [1, 1])
    }

    // MARK: P1330 Open in terminal

    @Test
    func openInTerminalOpensTheInteractiveResumeInTheSessionsOwnTerminal() async {
        let rig = Rig()
        rig.endedClaude()
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "go on") == .sent)
        // While the island's run lasts, no second copy.
        #expect(await rig.resumer.openInTerminal(Self.claudeID) == false)
        // The run's own hooks name no terminal and replace the old handles.
        rig.engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: Self.claudeID, agentPID: 7000,
                                                entrypoint: "sdk-cli", source: "claude", sessionStartSource: "resume"))
        rig.runs.current[0].end(ResumeExit(status: 0, output: ResumeOutput(provider: .claude)))
        await rig.settle { !rig.resumer.isRunning(Self.claudeID) }
        #expect(await rig.resumer.openInTerminal(Self.claudeID))
        #expect(rig.windows.current == [FreshSessionLaunch(
            host: .terminal, folder: Self.folder,
            line: "cd '\(Self.folder)' && CLAUDE_CONFIG_DIR='\(Self.lab)' claude --resume '\(Self.claudeID)'")])
    }

    @Test
    func aSessionFromAnotherHostOpensInTheUsualTerminal() async {
        let rig = Rig(usual: .ghostty)
        rig.endedClaude(host: "com.microsoft.VSCode")
        #expect(await rig.resumer.openInTerminal(Self.claudeID))
        #expect(rig.windows.current.map(\.host) == [.ghostty])
        rig.endedCodex()
        #expect(await rig.resumer.openInTerminal(Self.codexID))
        #expect(rig.windows.current.last?.line == "cd '\(Self.folder)' && CODEX_HOME='\(Self.side)' codex resume '\(Self.codexID)'")
    }

    @Test
    func whileTheAgentStillRunsOpenInTerminalJumpsAndOpensNoCopy() async {
        let rig = Rig()
        rig.endedClaude(pid: 5151, ended: false)
        rig.alive.update { $0.insert(5151) }
        // The plain jump (its stubbed runner reaches no app here), never a window.
        #expect(await rig.resumer.openInTerminal(Self.claudeID) == false)
        #expect(rig.windows.current.isEmpty && rig.engine.recentJumps.map(\.sessionID) == [Self.claudeID])
        #expect(rig.engine.foldNotes.last?.said == "opened · the plain jump, its agent still runs")
    }

    /// The log says "its agent still runs" only when it does (P1441): a session with no resume to open (here an id
    /// that is not a conversation's, as another agent's would be) whose agent has ended takes the plain jump, and says
    /// just that.
    @Test
    func thePlainJumpSaysItsAgentRunsOnlyWhenItDoes() async {
        let rig = Rig()
        rig.endedClaude("s1")
        #expect(await rig.resumer.openInTerminal("s1") == false)
        #expect(rig.windows.current.isEmpty && rig.engine.recentJumps.map(\.sessionID) == ["s1"])
        #expect(rig.engine.foldNotes.last?.said == "opened · the plain jump")
    }

    // MARK: P1327 the session stays the owner's

    @Test
    func aResumedSessionStaysTheOwnersThoughItsRunSaysSdkCli() async {
        let rig = Rig()
        rig.endedClaude()
        #expect(await rig.resumer.continueConversation(Self.claudeID, text: "go on") == .sent)
        // The run's hooks: `claude -p` names itself `sdk-cli`, a new process, a resume start.
        rig.engine.ingest(note: HookContextNote(event: "SessionStart", sessionID: Self.claudeID, agentPID: 7000,
                                                entrypoint: "sdk-cli", source: "claude", sessionStartSource: "resume"))
        rig.engine.ingest(F.started(Self.claudeID, transcript: "\(Self.lab)/projects/-tmp-ji-resume-project/\(Self.claudeID).jsonl",
                                    cwd: Self.folder, source: .resume), ingress: .bridge)
        rig.engine.ingest(F.prompt(Self.claudeID, "go on"), ingress: .bridge)
        let session = rig.engine.state.session(id: Self.claudeID)!
        #expect(!session.isSessionEnded && session.phase == .running)
        #expect(rig.engine.scope(of: session) == .owner && rig.engine.notifiesOfTurnEnd(Self.claudeID))
        // The run is the island's own: the session's agent is not taken as still running.
        rig.alive.update { $0.insert(7000) }
        #expect(rig.resumer.agentStillRuns(Self.claudeID) == false)

        // A session the island never resumed is a scripted run when its notes say so.
        let scripted = "5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d"
        rig.endedClaude(scripted)
        rig.engine.ingest(note: HookContextNote(event: "UserPromptSubmit", sessionID: scripted, agentPID: 4242,
                                                entrypoint: "sdk-cli", source: "claude"))
        #expect(rig.engine.scope(of: rig.engine.state.session(id: scripted)!) == .scripted)
    }

    // MARK: P1328 approvals come as cards

    @Test
    func anIslandRunsApprovalIsHeldAndShownAtOnce() {
        let line = HookRequestLine(source: "claude", input: Data("{}".utf8), entrypoint: "sdk-cli", agentPID: 7000, hasTerminal: false)
        let main: [String: Any] = ["session_id": Self.claudeID, "permission_mode": "default", "tool_name": "Bash"]
        // A print-mode run nobody sits at: released at once, as before.
        #expect(AttentionPolicy.brokerHold(line, main, answersSubagents: false).held == false)
        #expect(AttentionPolicy.claude(entrypoint: "sdk-cli", hasTerminal: false, agentID: nil, permissionMode: "default").show == false)
        // The island's own run of that session: its card is the only place to answer.
        let running: (String) -> Bool = { $0 == Self.claudeID }
        #expect(AttentionPolicy.brokerHold(line, main, answersSubagents: false, islandRun: running).held)
        #expect(AttentionPolicy.claude(entrypoint: "sdk-cli", hasTerminal: false, agentID: nil, permissionMode: "default",
                                       islandRun: true) == .init(hold: true, show: true, place: .terminal))
        // Another session's, `dontAsk`, and a subagent's (unless Answer subagents holds it, as in a terminal) are not held.
        var other = main
        other["session_id"] = Self.codexID
        #expect(AttentionPolicy.brokerHold(line, other, answersSubagents: false, islandRun: running).held == false)
        var quiet = main
        quiet["permission_mode"] = "dontAsk"
        #expect(AttentionPolicy.brokerHold(line, quiet, answersSubagents: false, islandRun: running).held == false)
        var subagent = main
        subagent["agent_id"] = "a1"
        #expect(AttentionPolicy.brokerHold(line, subagent, answersSubagents: false, islandRun: running).held == false)
        #expect(AttentionPolicy.brokerHold(line, subagent, answersSubagents: true, islandRun: running).held)
    }

    @Test
    func theEngineConfirmsAnIslandRunsHeldApprovalWithNoNotice() async {
        let scene = AttentionScene(armed: true)
        scene.engine.ingest(F.started(Self.claudeID, transcript: AttentionScene.transcript(Self.claudeID)), ingress: .bridge)
        scene.engine.ingest(F.prompt(Self.claudeID), ingress: .bridge)
        scene.engine.islandRunStarted(Self.claudeID)
        let object: [String: Any] = ["session_id": Self.claudeID, "hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                     "tool_input": ["command": "npm test"], "permission_mode": "default",
                                     "transcript_path": AttentionScene.transcript(Self.claudeID), "cwd": "/tmp/project"]
        let line = HookRequestLine(source: "claude", input: try! JSONSerialization.data(withJSONObject: object), entrypoint: "sdk-cli",
                                   agentPID: 7000, hasTerminal: false)
        let hold = AttentionPolicy.brokerHold(line, object, answersSubagents: false, islandRun: scene.engine.islandResumes.isRunning)
        #expect(hold.held)
        scene.broker.held.update { _ = $0.insert("r1") }
        scene.engine.takeBrokeredRequest(BrokeredRequest(id: "r1", line: line, object: object, held: hold.held, at: scene.clock.current))
        let request = scene.engine.openRequests.first { $0.id == "r1" }
        // Confirmed at once (no `permission_prompt` will come) and answerable on the island; the armed window never
        // releases it.
        #expect(request?.state == .confirmed && request?.channel == .answer(.broker) && request?.windowReleases == false)
        scene.at(30)
        #expect(scene.broker.released.current.isEmpty)
        #expect(scene.engine.needsYouCount == 1)
    }
}
