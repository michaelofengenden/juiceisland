import Darwin
import Foundation
import IslandHookNotes
import JavaScriptCore
import OpenIslandCore
import Testing
@testable import IslandEngine

/// Wave 4's plugin agents (P1150 to P1174): Juice's extension for Pi and Oh My Pi and its plugin for Amp, run in
/// JavaScriptCore with the agent's side faked. The socket is a recorder, `ps` answers from a table, timers are kept for
/// the test to look at, and every line a plugin writes is decoded with upstream's `BridgeEnvelope`, as the bridge decodes
/// it. The agents' sides are shaped from their own source and docs:
/// - Pi: https://github.com/earendil-works/pi `packages/coding-agent/src/core/extensions/types.ts` (SessionStartEvent,
///   BeforeAgentStartEvent, ToolExecutionStartEvent, ToolExecutionEndEvent, MessageEndEvent, AgentSettledEvent,
///   SessionShutdownEvent, ExtensionContext's `cwd`, `sessionManager`, `model`) at 83692682, 2026-10-03.
/// - Oh My Pi: https://github.com/can1357/oh-my-pi `packages/coding-agent/src/extensibility/shared-events.ts`
///   (SessionStopEvent) and `extensions/types.ts` at 0a35c20a, 2026-10-03.
/// - Amp: https://ampcode.com/docs/plugin-api (`PluginEventMap`: SessionStartEvent, AgentStartEvent, ToolResultEvent,
///   AgentEndEvent; `PluginThread.state` with `awaiting-approval`, `messages()`, `parentThreadID()`; `helpers`) and the
///   same types in npm `@ampcode/plugin` 0.0.0-20261003001754-g8b95194, read 2026-10-03.
/// Nothing touches the network or a real socket here; `PluginRuntimeTests` runs the written files in Node and Bun.
@MainActor
struct PluginAgentsTests {
    /// A plugin with its imports replaced by the harness's `connect` and `execFile`.
    final class Harness {
        let context = JSContext()!
        var failures: [String] = []

        init(_ source: String, env: [String: String] = Harness.env) {
            context.exceptionHandler = { [weak self] _, value in self?.failures.append(value?.toString() ?? "exception") }
            let environment = (try? JSONSerialization.data(withJSONObject: env)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            context.evaluateScript("var __env = \(environment);")
            context.evaluateScript(Self.prelude)
            let body = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("import ") }
                .joined(separator: "\n")
                .replacingOccurrences(of: "export default function", with: "globalThis.__plugin = function")
                .replacingOccurrences(of: "export const description =", with: "globalThis.__description =")
            context.evaluateScript(body)
        }

        /// The terminal a hook in iTerm sees, as Pi's and Amp's own processes inherit it.
        static let env = ["HOME": "/Users/tester", "TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p0:ABCD"]

        @discardableResult
        func run(_ script: String) -> JSValue? { context.evaluateScript(script) }

        func string(_ script: String) -> String? { run(script).flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() } }
        func bool(_ script: String) -> Bool { run(script)?.toBool() ?? false }
        func int(_ script: String) -> Int { Int(run(script)?.toInt32() ?? -1) }

        struct Socket {
            var command: BridgeCommand?
            var ended: Bool
            var destroyed: Bool
            var unrefed: Bool
            var timeout: Int?
        }

        /// Every connection the plugin opened, in order, its first line as the bridge decodes it.
        var sockets: [Socket] {
            (0..<int("__sockets.length")).map { index in
                let written = string("__sockets[\(index)].written") ?? ""
                let line = written.split(separator: "\n").first.map(String.init) ?? ""
                var command: BridgeCommand?
                if case let .command(decoded)? = try? JSONDecoder().decode(BridgeEnvelope.self, from: Data(line.utf8)) { command = decoded }
                return Socket(command: command, ended: bool("__sockets[\(index)].ended"), destroyed: bool("__sockets[\(index)].destroyed"),
                              unrefed: bool("__sockets[\(index)].unrefed"),
                              timeout: run("__sockets[\(index)].timeout").flatMap { $0.isNumber ? Int($0.toInt32()) : nil })
            }
        }

        var piHooks: [PiHookPayload] {
            sockets.compactMap { if case let .processPiHook(payload)? = $0.command { payload } else { nil } }
        }

        var openCodeHooks: [OpenCodeHookPayload] {
            sockets.compactMap { if case let .processOpenCodeHook(payload)? = $0.command { payload } else { nil } }
        }

        /// The events the plugin listens to.
        var events: Set<String> { Set((string("Object.keys(__handlers).join(',')") ?? "").split(separator: ",").map(String.init)) }

        static let prelude = #"""
        var __sockets = [];
        var __execs = [];
        var __timers = [];
        var __handlers = {};
        var __connectFails = false;
        var process = { pid: 4242, env: __env, cwd: () => "/tmp/fallback" };
        function connect(options, onConnect) {
          if (__connectFails) throw new Error("connect ENOENT " + options.path);
          const socket = {
            path: options.path, written: "", ended: false, destroyed: false, unrefed: false, handlers: {}, timeout: null,
            on(name, fn) { (this.handlers[name] = this.handlers[name] || []).push(fn); return this; },
            emit(name, arg) { for (const fn of this.handlers[name] || []) fn(arg); },
            write(text) { this.written += text; },
            end(text) { if (text) this.written += text; this.ended = true; },
            destroy() { this.destroyed = true; },
            setTimeout(ms, fn) { this.timeout = ms; this.onTimeout = fn; },
            unref() { this.unrefed = true; },
          };
          __sockets.push(socket);
          Promise.resolve().then(() => onConnect && onConnect());
          return socket;
        }
        // `ps -o tty=,ppid= -p <pid>`: the plugin's own process has no terminal, its parent (the agent) has one.
        var __ps = { 4242: "??   4100", 4100: "ttys003   1" };
        function execFile(file, args, options, callback) {
          __execs.push({ file, args, timeout: options && options.timeout });
          const pid = args[args.length - 1];
          Promise.resolve().then(() => __ps[pid] ? callback(null, __ps[pid] + "\n") : callback(new Error("no such process"), ""));
        }
        function timer(fn, ms) { const t = { fn, ms, cleared: false, unrefed: false, unref() { this.unrefed = true; return this; } }; __timers.push(t); return t; }
        function setInterval(fn, ms) { return timer(fn, ms); }
        function setTimeout(fn, ms) { return timer(fn, ms); }
        function clearInterval(t) { if (t) t.cleared = true; }
        function clearTimeout(t) { if (t) t.cleared = true; }
        function __on(name, fn) { (__handlers[name] = __handlers[name] || []).push(fn); return { unsubscribe() {} }; }
        // Every handler's own return value: a plugin of Juice's returns nothing, at once.
        function __fire(name, event, ctx) { return (__handlers[name] || []).map((fn) => fn(event, ctx)); }
        function __returnedNothing(results) { return results.every((value) => value === undefined); }
        """#
    }

    // MARK: Pi and Oh My Pi

    /// Pi's side: `pi.on` and a session's context, as `ExtensionContext` gives them (its id and file from the session
    /// manager, its model as provider and id).
    static let piSide = #"""
    var __pi = { on: __on };
    var __ctx = { cwd: "/tmp/MarathonTrainingLog", model: { provider: "anthropic", id: "claude-opus" },
      sessionManager: { getSessionId: () => "019a2b", getSessionFile: () => "/tmp/pi-sessions/019a2b.jsonl" } };
    __plugin(__pi);
    """#

    static func pi(_ kind: AgentKind = .pi, env: [String: String] = Harness.env) -> Harness {
        let harness = Harness(PiExtension.source(socketPath: "/tmp/ji-home/bridge.sock", kind: kind), env: env)
        harness.run(piSide)
        return harness
    }

    /// One default export, the revision on its first line, only Node's own modules, nothing written or logged.
    @Test
    func piExtensionIsOneFileWithNoDependencies() {
        let source = PiExtension.source(socketPath: "/tmp/ji-home/bridge.sock", kind: .pi)
        let harness = Harness(source)
        #expect(harness.failures.isEmpty)
        #expect(harness.string("typeof __plugin") == "function")
        #expect(source.hasPrefix("// Juice extension for Pi and Oh My Pi, revision \(PiExtension.revision).\n"))
        #expect(AgentPlugins.read(Data(source.utf8), kind: .pi) == .ours(revision: PiExtension.revision))
        #expect(AgentPlugins.read(Data(source.utf8), kind: .ohmypi) == .ours(revision: PiExtension.revision))
        #expect(AgentPlugins.read(Data(source.utf8), kind: .amp) == .foreign)
        let imports = source.split(separator: "\n").filter { $0.hasPrefix("import ") }
        #expect(imports == [#"import { connect } from "node:net";"#, #"import { execFile } from "node:child_process";"#])
        for banned in ["writeFile", "appendFile", "console.", "fetch(", "http", "process.env.", "execFileSync", "require("] {
            #expect(!source.contains(banned), "\(banned)")
        }
        #expect(source.contains(#"const SOCKET_PATH = "/tmp/ji-home/bridge.sock";"#))
        #expect(PiExtension.source(socketPath: "/tmp/a", kind: .ohmypi).contains(#"const AGENT = "oh-my-pi";"#))
    }

    /// A Pi session from start to end, as upstream's bridge reads it: SessionStart, the owner's prompt, a tool's start and
    /// end, Stop with the last reply once Pi settles, SessionEnd at quit; every one `pi-<session id>`, with the agent's
    /// folder, model, session file and terminal (iTerm, its session and the agent's tty, read once).
    @Test
    func aPiSessionReachesTheBridgeAsOpenIslandsPiHooks() throws {
        let harness = Self.pi()
        var returned: [Bool] = []
        for (name, event) in [("session_start", #"{ type: "session_start", reason: "startup" }"#),
                              ("before_agent_start", #"{ type: "before_agent_start", prompt: "read the results", systemPrompt: "" }"#),
                              ("agent_start", #"{ type: "agent_start" }"#),
                              ("tool_execution_start", #"{ type: "tool_execution_start", toolCallId: "c1", toolName: "read", args: { path: "results/summary.md" } }"#),
                              ("tool_execution_end", #"{ type: "tool_execution_end", toolCallId: "c1", toolName: "read", result: {}, isError: false }"#),
                              ("message_end", #"{ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "The summary says 4 of 5 passed." }] } }"#),
                              ("agent_settled", #"{ type: "agent_settled" }"#),
                              ("session_shutdown", #"{ type: "session_shutdown", reason: "quit" }"#)] {
            returned.append(harness.bool("__returnedNothing(__fire('\(name)', \(event), __ctx))"))
        }
        #expect(harness.failures.isEmpty)
        #expect(returned.allSatisfy { $0 })
        let hooks = harness.piHooks
        #expect(hooks.map(\.hookEventName) == [.sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .stop, .sessionEnd])
        #expect(hooks.allSatisfy { $0.sessionID == "pi-019a2b" && $0.agent == .pi && $0.cwd == "/tmp/MarathonTrainingLog" })
        #expect(hooks.allSatisfy { $0.model == "anthropic/claude-opus" && $0.transcriptPath == "/tmp/pi-sessions/019a2b.jsonl" })
        #expect(hooks.allSatisfy { $0.terminalApp == "iTerm" && $0.terminalSessionID == "w0t1p0:ABCD" && $0.terminalTTY == "/dev/ttys003" })
        #expect(hooks[1].prompt == "read the results")
        #expect(hooks[2].toolName == "read" && hooks[2].toolInput == #"{"path":"results/summary.md"}"#)
        #expect(hooks[4].lastAssistantMessage == "The summary says 4 of 5 passed.")
        // `ps` ran for the plugin and its parent once, at the first session start, with a time limit, never again.
        #expect(harness.int("__execs.length") == 2 && harness.int("__execs[0].timeout") == 1000)
        #expect(harness.string("__execs[0].file") == "/bin/ps")
        // One connection per event, half-closed after its line, given up after a second, never keeping Pi alive.
        #expect(harness.sockets.allSatisfy { $0.ended && $0.unrefed && $0.timeout == 1000 })
    }

    /// Oh My Pi: `omp-…` sessions under its own agent word, its turn over at `session_stop` (it has no `agent_settled`).
    @Test
    func ohMyPiSessionsAreItsOwnAndEndAtSessionStop() {
        let harness = Self.pi(.ohmypi)
        harness.run(#"__fire("session_start", { type: "session_start" }, __ctx)"#)
        #expect(harness.events.contains("session_stop") && !harness.events.contains("agent_settled"))
        #expect(harness.bool(#"__returnedNothing(__fire("session_stop", { type: "session_stop", messages: [], turn_id: 0, session_id: "019a2b", stop_hook_active: false }, __ctx))"#))
        let hooks = harness.piHooks
        #expect(hooks.map(\.hookEventName) == [.sessionStart, .stop])
        #expect(hooks.allSatisfy { $0.sessionID == "omp-019a2b" && $0.agent == .ohMyPi })
        #expect(Self.pi(.pi).events.contains("agent_settled") && !Self.pi(.pi).events.contains("session_stop"))
    }

    /// It listens to no event that lets an extension decide, or that changes what the agent does by being handled at all:
    /// `tool_call`, `tool_result`, Oh My Pi's `tool_approval_requested` and `tool_approval_resolved` (any of these four
    /// turns its early reads off, P1153), `input`, `user_bash`, `context` (P1151).
    @Test
    func itListensToNothingThatDecides() {
        for kind in [AgentKind.pi, .ohmypi] {
            let events = Self.pi(kind).events
            for banned in ["tool_call", "tool_result", "tool_approval_requested", "tool_approval_resolved", "input", "user_bash",
                           "context", "before_provider_request", "agent_before_settle", "turn_end"] {
                #expect(!events.contains(banned), "\(kind) \(banned)")
            }
            #expect(events.isSubset(of: ["session_start", "before_agent_start", "agent_start", "tool_execution_start",
                                         "tool_execution_end", "message_end", "agent_settled", "session_stop", "session_shutdown"]))
        }
    }

    /// The heartbeat upstream's state keeps a Pi session alive by: every 15 s from the session's start, never keeping the
    /// agent's process alive, stopped at shutdown; a reload ends nothing (P1165).
    @Test
    func theHeartbeatRunsFromStartToShutdown() {
        let harness = Self.pi()
        harness.run(#"__fire("session_start", { type: "session_start", reason: "startup" }, __ctx)"#)
        #expect(harness.int("__timers.length") == 1 && harness.int("__timers[0].ms") == 15000 && harness.bool("__timers[0].unrefed"))
        harness.run("__timers[0].fn()")
        #expect(harness.piHooks.map(\.hookEventName) == [.sessionStart, .heartbeat])
        harness.run(#"__fire("session_shutdown", { type: "session_shutdown", reason: "reload" }, __ctx)"#)
        #expect(harness.bool("__timers[0].cleared"))
        #expect(harness.piHooks.map(\.hookEventName) == [.sessionStart, .heartbeat])
    }

    /// Juice not running: every connect fails, and still nothing throws into Pi and every handler returns nothing.
    @Test
    func noAppMeansNothingHappensInPi() {
        let harness = Self.pi()
        harness.run("__connectFails = true")
        #expect(harness.bool(#"__returnedNothing(__fire("session_start", { type: "session_start" }, __ctx))"#))
        #expect(harness.bool(#"__returnedNothing(__fire("agent_settled", { type: "agent_settled" }, __ctx))"#))
        #expect(harness.failures.isEmpty && harness.sockets.isEmpty)
        // A context Pi has invalidated (a session replaced) throws on use: that event is dropped, nothing else.
        harness.run("__connectFails = false")
        harness.run(#"__fire("before_agent_start", { prompt: "x" }, { get cwd() { throw new Error("stale context"); } })"#)
        #expect(harness.failures.isEmpty && harness.sockets.isEmpty)
    }

    /// No session id from the manager: the session file, else the folder and the process, as upstream names it.
    @Test
    func aSessionWithNoIdIsNamedByItsFileOrFolder() {
        let harness = Harness(PiExtension.source(socketPath: "/tmp/s.sock", kind: .pi))
        harness.run(#"__plugin({ on: __on }); __fire("session_start", {}, { cwd: "/tmp/p", sessionManager: { getSessionFile: () => "/tmp/f.jsonl" } }); __fire("session_start", {}, { cwd: "/tmp/p" })"#)
        #expect(harness.piHooks.map(\.sessionID) == ["pi-/tmp/f.jsonl", "pi-/tmp/p:4242"])
        #expect(harness.piHooks.allSatisfy { $0.model == nil })
    }

    // MARK: Amp

    /// Amp's side: `amp.on`, `onDispose`, its workspace and helpers, and threads whose state the test moves.
    static let ampSide = #"""
    var __disposers = [];
    var __observers = {};
    var __subscriptions = [];
    var __messageReads = [];
    function __thread(id, parent, messages) {
      return {
        id,
        parentThreadID: () => Promise.resolve(parent || null),
        state: { subscribe(fn) {
          (__observers[id] = __observers[id] || []).push(fn);
          const subscription = { id, unsubscribed: false, unsubscribe() { this.unsubscribed = true; } };
          __subscriptions.push(subscription);
          return subscription;
        } },
        messages: (options) => { __messageReads.push(options); return Promise.resolve(messages || []); },
      };
    }
    var __amp = {
      on: __on,
      onDispose(fn) { __disposers.push(fn); return { unsubscribe() {} }; },
      system: { workspaceRoot: { toString() { return "file:///tmp/notes-site"; } } },
      helpers: {
        filePathFromURI: (uri) => String(uri).replace("file://", ""),
        shellCommandFromToolCall: (call) => call.tool === "Bash" ? { command: call.input.cmd } : null,
        filesModifiedByToolCall: (call) => call.tool === "edit_file" ? [{ toString() { return "file:///tmp/notes-site/" + call.input.path; } }] : null,
      },
    };
    function __state(id, state) { for (const fn of __observers[id] || []) fn(state); }
    var __push = [{ role: "assistant", id: 7, content: [{ type: "text", text: "Pushing the fix." },
      { type: "tool_use", id: "toolu_1", name: "Bash", input: { cmd: "git push origin main" } }] }];
    var __main = __thread("T-5f1d", null, __push);
    __plugin(__amp);
    """#

    static func amp(env: [String: String] = Harness.env) -> Harness {
        let harness = Harness(AmpPlugin.source(socketPath: "/tmp/ji-home/bridge.sock"), env: env)
        harness.run(ampSide)
        return harness
    }

    /// One default export with Amp's static `description` (300 characters at most), the revision on the first line, only
    /// Node's own modules, and no `tool.call`: the plugin never takes part in a call's decision (P1158).
    @Test
    func ampPluginIsOneFileThatDecidesNothing() {
        let source = AmpPlugin.source(socketPath: "/tmp/ji-home/bridge.sock")
        let harness = Self.amp()
        #expect(harness.failures.isEmpty)
        #expect(harness.string("typeof __plugin") == "function")
        let description = harness.string("__description") ?? ""
        #expect(!description.isEmpty && description.count <= 300 && !description.contains("Island"))
        #expect(source.hasPrefix("// Juice plugin for Amp, revision \(AmpPlugin.revision).\n"))
        #expect(AgentPlugins.read(Data(source.utf8), kind: .amp) == .ours(revision: AmpPlugin.revision))
        #expect(AgentPlugins.read(Data(source.utf8), kind: .pi) == .foreign)
        #expect(harness.events == ["session.start", "agent.start", "tool.result", "agent.end"])
        let imports = source.split(separator: "\n").filter { $0.hasPrefix("import ") }
        #expect(imports == [#"import { connect } from "node:net";"#, #"import { execFile } from "node:child_process";"#])
        for banned in ["tool.call", "writeFile", "appendFile", "console.", "fetch(", "http", "process.env.", "execFileSync", "@ampcode"] {
            #expect(!source.contains(banned), "\(banned)")
        }
    }

    /// A thread from start to Done as upstream's OpenCode decoder reads it: SessionStart, the owner's prompt, a tool's
    /// result, Stop with the turn's last reply; every one `amp-<thread id>` in the workspace's folder, with iTerm, its
    /// session and Amp's tty. Every handler returns nothing, at once.
    @Test
    func anAmpThreadReachesTheBridgeAsOpenCodeHooks() {
        let harness = Self.amp()
        let ctx = "{ thread: __main }"
        var returned: [Bool] = []
        for (name, event) in [("session.start", #"{ thread: { id: "T-5f1d" } }"#),
                              ("agent.start", #"{ thread: { id: "T-5f1d" }, message: "push the fix", id: 1 }"#),
                              ("tool.result", #"{ thread: { id: "T-5f1d" }, toolUseID: "toolu_1", tool: "Bash", input: { cmd: "git push origin main" }, status: "done" }"#),
                              ("agent.end", #"{ thread: { id: "T-5f1d" }, message: "push the fix", id: 1, status: "done", messages: [{ role: "user", id: 1, content: [{ type: "text", text: "push the fix" }] }, { role: "assistant", id: 2, content: [{ type: "thinking", thinking: "…" }, { type: "text", text: "Pushed the fix to main." }] }] }"#)] {
            returned.append(harness.bool("__returnedNothing(__fire('\(name)', \(event), \(ctx)))"))
        }
        #expect(harness.failures.isEmpty && returned.allSatisfy { $0 })
        let hooks = harness.openCodeHooks
        #expect(hooks.map(\.hookEventName) == [.sessionStart, .userPromptSubmit, .postToolUse, .stop])
        #expect(hooks.allSatisfy { $0.sessionID == "amp-T-5f1d" && $0.cwd == "/tmp/notes-site" })
        #expect(hooks.allSatisfy { $0.terminalApp == "iTerm" && $0.terminalSessionID == "w0t1p0:ABCD" && $0.terminalTTY == "/dev/ttys003" })
        #expect(hooks[1].prompt == "push the fix" && hooks[2].toolName == "Bash" && hooks[2].toolInput == nil)
        #expect(hooks[3].lastAssistantMessage == "Pushed the fix to main.")
        #expect(AgentKind.fromSessionID(hooks[0].sessionID) == .amp && OpenCodeAPI.of(sessionID: hooks[0].sessionID) == .one)
        #expect(harness.sockets.allSatisfy { $0.ended && $0.unrefed && $0.timeout == 1000 })
        // It watches the thread's state, once.
        #expect(harness.int("__subscriptions.length") == 1)
    }

    /// Amp says a thread waits for an approval (the owner's policy plugin asks): one connection stays open with a
    /// PermissionRequest naming the call, its command from Amp's own helper, until the state moves on; the island never
    /// has anything to answer it with (P1159). A file change names its file; a call it cannot read names none.
    @Test
    func awaitingApprovalHoldsOneConnectionUntilTheStateMovesOn() {
        let harness = Self.amp()
        harness.run(#"__fire("session.start", { thread: { id: "T-5f1d" } }, { thread: __main })"#)
        harness.run(#"__state("T-5f1d", "running"); __state("T-5f1d", "awaiting-approval"); __state("T-5f1d", "awaiting-approval")"#)
        #expect(harness.failures.isEmpty)
        let waiting = harness.sockets.filter { if case .processOpenCodeHook(let p)? = $0.command { p.hookEventName == .permissionRequest } else { false } }
        #expect(waiting.count == 1)
        #expect(waiting.first.map { !$0.ended && !$0.destroyed && $0.timeout == 30 * 60 * 1000 } == true)
        let asked = harness.openCodeHooks.first { $0.hookEventName == .permissionRequest }
        #expect(asked?.sessionID == "amp-T-5f1d" && asked?.toolName == "Bash" && asked?.toolInput == #"{"command":"git push origin main"}"#)
        #expect(asked?.permissionTitle == "Allow Bash" && asked?.permissionDescription == "Amp is waiting for an answer in Amp.")
        #expect(harness.string("JSON.stringify(__messageReads[0])") == #"{"from":"end","limit":3,"roles":["assistant"]}"#)
        harness.run(#"__state("T-5f1d", "running")"#)
        #expect(harness.sockets.last?.destroyed == true)
        // Again, ended by the turn's end this time; and a file change.
        harness.run(#"""
        __push[0].content[1] = { type: "tool_use", id: "toolu_2", name: "edit_file", input: { path: "docs/setup.md" } };
        __state("T-5f1d", "awaiting-approval");
        """#)
        #expect(harness.openCodeHooks.last?.toolInput == #"{"file_path":"/tmp/notes-site/docs/setup.md"}"#)
        harness.run(#"__fire("agent.end", { thread: { id: "T-5f1d" }, status: "cancelled", messages: [] }, { thread: __main })"#)
        let holds = harness.sockets.filter { if case .processOpenCodeHook(let p)? = $0.command { p.hookEventName == .permissionRequest } else { false } }
        #expect(holds.count == 2 && holds.allSatisfy(\.destroyed))
        #expect(harness.openCodeHooks.last.map { $0.hookEventName == .stop && $0.lastAssistantMessage == nil } == true)
        // No call to read: the card says Amp waits, and nothing more.
        harness.run(#"__push.length = 0; __state("T-5f1d", "awaiting-approval")"#)
        let bare = harness.openCodeHooks.last
        #expect(bare?.hookEventName == .permissionRequest && bare?.toolName == nil && bare?.toolInput == "{}")
        #expect(bare?.permissionTitle == "Amp is waiting")
        // Quitting Amp's plugin host closes it and lets go of every watch.
        harness.run("for (const dispose of __disposers) dispose()")
        #expect(harness.sockets.last?.destroyed == true && harness.bool("__subscriptions.every((s) => s.unsubscribed)"))
    }

    /// A subagent's thread (one with a parent) is its parent's work: none of its events show, and its waiting shows on
    /// the parent's row (P1161).
    @Test
    func aSubagentsThreadWaitsOnItsParentsRow() {
        let harness = Self.amp()
        harness.run(#"""
        var __child = __thread("T-c41d", "T-5f1d", __push);
        __fire("session.start", { thread: { id: "T-5f1d" } }, { thread: __main });
        __fire("session.start", { thread: { id: "T-c41d" } }, { thread: __child });
        __fire("agent.start", { thread: { id: "T-c41d" }, message: "find the links" }, { thread: __child });
        __state("T-c41d", "awaiting-approval");
        """#)
        #expect(harness.failures.isEmpty)
        let hooks = harness.openCodeHooks
        #expect(hooks.map(\.hookEventName) == [.sessionStart, .permissionRequest])
        #expect(hooks.allSatisfy { $0.sessionID == "amp-T-5f1d" })
    }

    /// Amp not running Juice: no socket. Nothing throws into Amp, every handler still returns nothing, and a thread that
    /// waits leaves no card behind.
    @Test
    func noAppMeansNothingHappensInAmp() {
        let harness = Self.amp()
        harness.run("__connectFails = true")
        #expect(harness.bool(#"__returnedNothing(__fire("session.start", { thread: { id: "T-5f1d" } }, { thread: __main }))"#))
        harness.run(#"__state("T-5f1d", "awaiting-approval"); __state("T-5f1d", "idle")"#)
        #expect(harness.bool(#"__returnedNothing(__fire("agent.end", { thread: { id: "T-5f1d" }, messages: [] }, { thread: __main }))"#))
        #expect(harness.failures.isEmpty && harness.sockets.isEmpty)
    }

    // MARK: The table

    /// The three plugin agents: Watch, no approval event, each a file of Juice's own per flavor in its own folder, found
    /// by its command or its folder (P1150, P1157).
    @Test
    func theTableHoldsThePluginAgentsAsWatch() {
        let specs = AgentHookTable.plugins
        #expect(specs.map(\.kind) == [.pi, .ohmypi, .amp])
        #expect(specs.allSatisfy { $0.answers == .watch && $0.approvalEvents.isEmpty && $0.layout == .plugin && $0.events.isEmpty })
        #expect(specs.map { $0.file(stem: "juice") } == ["extensions/juice.ts", "extensions/juice.ts", "plugins/juice.ts"])
        #expect(specs.map(\.folder) == [".pi/agent", ".omp/agent", ".config/amp"])
        #expect(specs.map(\.executables) == [["pi"], ["omp"], ["amp"]])
        #expect(specs.map(\.name) == ["Pi", "Oh My Pi", "Amp"])
        #expect(AgentHookTable.wave1.map(\.kind).filter { [.pi, .ohmypi, .amp].contains($0) } == [.pi, .ohmypi, .amp])
        #expect(specs.allSatisfy { !$0.sources.isEmpty && $0.checked == "2026-10-03" })
        #expect(AgentKind.amp.carrierTool == .openCode && AgentKind.amp.needsLabel && AgentKind.amp.displayName == "Amp")
        #expect(AgentKind.fromSessionID("amp-T-1") == .amp && AgentKind.fromSessionID("kilo-1") == .kilo)
        #expect(AgentKind.fromSessionID("opencode-ses_1") == nil && AgentKind.fromSessionID("pi-1") == nil)
        #expect(AgentKind.pi.carrierTool == .pi && AgentKind.ohmypi.carrierTool == .ohMyPi)
        // Each agent's plugin is its own: Kilo keeps OpenCode's.
        #expect(AgentPlugins.source(.kilo, socketPath: "/s").hasPrefix("// Juice plugin for OpenCode and Kilo"))
        #expect(AgentPlugins.revision(.kilo) == OpenCodePlugin.revision)
    }
}

/// Connect and Remove for the three plugin agents over a scratch home (P1154, P1160): only Juice's own file is written
/// or deleted, never another file in the folder; an older one of Juice's reads as Update; anyone else's under that name,
/// or a link, is never replaced; and the folder Connect made goes with the file.
struct PluginAgentsInstallerTests {
    final class Home {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ji-plugins-\(UUID().uuidString)", isDirectory: true)
        func installer(stem: String = "juice-island") -> AgentHookInstaller {
            AgentHookInstaller(home: root, helperPath: "/tmp/ji-home/bin/JuiceHooks", bundledHelper: nil, ownFileStem: stem,
                               bridgeSocketPath: "/tmp/ji-home/bridge.sock")
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
        func folder(_ path: String) throws { try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true) }
        func write(_ path: String, _ text: String) throws {
            try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url(path))
        }
        func read(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }
        func names(_ path: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url(path).path)) ?? []).sorted() }
    }

    @Test(arguments: AgentHookTable.plugins)
    func connectWritesOnlyJuicesFileAndRemoveTakesOnlyIt(_ spec: AgentHookSpec) throws {
        let home = Home(), installer = home.installer()
        #expect(installer.status(spec) == .notFound)
        #expect(throws: AgentHookInstaller.Failure.folderMissing) { try installer.install(spec) }
        try home.folder(spec.folder)
        #expect(installer.status(spec) == .notConnected)
        try installer.install(spec)
        let file = "\(spec.folder)/\(spec.file(stem: "juice-island"))"
        let text = try #require(home.read(file))
        #expect(text == AgentPlugins.source(spec.kind, socketPath: "/tmp/ji-home/bridge.sock"))
        #expect(installer.status(spec) == .connected && installer.snippet(spec).isEmpty)
        #expect(installer.shownPath(spec) == "~/\(file)")
        // Nothing else was written: no backup, no config file, no other file in the folder.
        let folder = (file as NSString).deletingLastPathComponent
        #expect(home.names(folder) == ["juice-island.ts"])
        #expect(home.names(spec.folder) == [(folder as NSString).lastPathComponent])
        try installer.remove(spec)
        #expect(installer.status(spec) == .notConnected)
        #expect(!home.exists(folder) && home.exists(spec.folder))
    }

    /// Another file in the agent's folder (the owner's own extension, Open Island's) is never read as Juice's, replaced or
    /// removed, and keeps the folder when Juice's file goes; one of Juice's older revisions offers Update; anyone else's
    /// file under Juice's name, or a link there, is never written.
    @Test(arguments: AgentHookTable.plugins)
    func othersFilesStayAndJuicesNameIsNeverTaken(_ spec: AgentHookSpec) throws {
        let home = Home(), installer = home.installer()
        let folder = "\(spec.folder)/\((spec.file(stem: "juice-island") as NSString).deletingLastPathComponent)"
        let mine = "export default function (pi) { pi.on('session_start', () => {}); }\n"
        try home.write("\(folder)/my-tools.ts", mine)
        try installer.install(spec)
        #expect(installer.status(spec) == .connected)
        let file = "\(folder)/juice-island.ts"
        let ours = try #require(home.read(file))
        let marker = spec.kind == .amp ? "// Juice plugin for Amp, revision " : "// Juice extension for Pi and Oh My Pi, revision "
        try home.write(file, ours.replacingOccurrences(of: marker + "\(AgentPlugins.revision(spec.kind)).", with: marker + "0."))
        #expect(installer.status(spec) == .outdated)
        try installer.install(spec)
        #expect(home.read(file) == ours && installer.status(spec) == .connected)
        try installer.remove(spec)
        #expect(home.names(folder) == ["my-tools.ts"] && home.read("\(folder)/my-tools.ts") == mine)
        // Someone else's file under Juice's name.
        try home.write(file, mine)
        #expect(installer.status(spec) == .unreadable(file: spec.file(stem: "juice-island")))
        #expect(throws: AgentHookInstaller.Failure.foreign) { try installer.install(spec) }
        #expect(throws: AgentHookInstaller.Failure.foreign) { try installer.remove(spec) }
        #expect(home.read(file) == mine)
        // A link there: Add by hand, and nothing is written through it.
        try FileManager.default.removeItem(at: home.url(file))
        try FileManager.default.createSymbolicLink(at: home.url(file), withDestinationURL: home.url("\(folder)/my-tools.ts"))
        if case .addByHand = installer.status(spec) {} else { Issue.record("a link reads as \(installer.status(spec))") }
        #expect(throws: AgentHookInstaller.Failure.addByHand) { try installer.install(spec) }
        #expect(home.read("\(folder)/my-tools.ts") == mine)
    }

    /// The private app's file and the public Juice's never meet (P925): each flavor's Connect and Remove touch only its
    /// own.
    @Test
    func eachFlavorHasItsOwnFile() throws {
        let home = Home(), spec = AgentHookTable.amp
        try home.folder(".config/amp")
        try home.installer(stem: "juice-island").install(spec)
        try home.installer(stem: "juice").install(spec)
        #expect(home.names(".config/amp/plugins") == ["juice-island.ts", "juice.ts"])
        try home.installer(stem: "juice").remove(spec)
        #expect(home.names(".config/amp/plugins") == ["juice-island.ts"])
        #expect(home.installer(stem: "juice-island").status(spec) == .connected)
    }
}

/// The written files in the real runtimes their agents use, when they are already on this Mac (P1155, P1162): Pi's
/// extension under Node (Pi loads it with `jiti` in Node) and Bun (Oh My Pi), Amp's plugin under Bun (Amp's own runtime).
/// Each is connected into a temporary home with the installer, imported as the agent imports it, with no npm install, and
/// driven through one session by a stand-in for the agent's side; a listener at a temporary path stands in for the app's
/// socket and never answers. The lines it gets are decoded as the bridge decodes them, and the runtime must exit by
/// itself, which it cannot if the plugin keeps a connection, a timer or a child alive. With neither runtime here, the
/// files are parsed in JavaScriptCore instead.
struct PluginRuntimeTests {
    /// A listener that records each connection's bytes and never writes back.
    final class Listener: @unchecked Sendable {
        let path: String
        private let fd: Int32
        private let lock = NSLock()
        private var texts: [Int: String] = [:]
        private var next = 0

        init(path: String) throws {
            self.path = path
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = try #require(HookNoteSocket.address(for: URL(fileURLWithPath: path)))
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            #expect(bound == 0 && listen(fd, 16) == 0)
            let listener = fd
            Thread { [weak self] in
                while true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    guard let self else { close(client); return }
                    let index = self.lock.withLock { () -> Int in
                        defer { self.next += 1 }
                        self.texts[self.next] = ""
                        return self.next
                    }
                    Thread {
                        var buffer = [UInt8](repeating: 0, count: 4_096)
                        while true {
                            let count = read(client, &buffer, buffer.count)
                            guard count > 0 else { break }
                            let text = String(decoding: buffer[0..<count], as: UTF8.self)
                            self.lock.withLock { self.texts[index, default: ""] += text }
                        }
                        close(client)
                    }.start()
                }
            }.start()
        }

        /// Each connection's first line, in the order they came.
        var lines: [String] {
            lock.withLock { texts.keys.sorted().compactMap { texts[$0]?.split(separator: "\n").first.map(String.init) } }
        }

        func stop() {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(path)
        }
    }

    /// `node` and `bun` where a shell or an installer puts them; nil when neither is on this Mac.
    static func runtime(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let places = path + ["\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return places.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// What a driver's run came to: whether the runtime exited by itself within 20 s (else it was stopped), its status,
    /// what it printed, and how long it took.
    struct Run {
        var finished: Bool
        var status: Int32
        var output: String
        var seconds: TimeInterval
    }

    /// Runs `driver` (an ES module) with `runtime` and `arguments`, in a bare environment: a temporary home, no terminal
    /// of the test's own but Terminal's name.
    static func drive(_ runtime: String, _ driver: URL, _ arguments: [String], home: URL) throws -> Run {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: runtime)
        process.arguments = [driver.path] + arguments
        process.currentDirectoryURL = home
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory(), "NODE_NO_WARNINGS": "1",
                               "TERM_PROGRAM": "Apple_Terminal"]
        process.standardOutput = output
        process.standardError = output
        let started = Date()
        try process.run()
        while process.isRunning, Date().timeIntervalSince(started) < 20 { usleep(20_000) }
        let finished = !process.isRunning
        if !finished { process.terminate() }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Run(finished: finished, status: process.terminationStatus, output: text, seconds: Date().timeIntervalSince(started))
    }

    /// A scratch home short enough for a socket path, removed after.
    final class Scratch {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("jp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }
        var socket: String { root.appendingPathComponent("b.sock").path }
        func installer() -> AgentHookInstaller {
            AgentHookInstaller(home: root, helperPath: "/tmp/ji-home/bin/JuiceHooks", bundledHelper: nil, ownFileStem: "juice",
                               bridgeSocketPath: socket)
        }
    }

    static let piDriver = #"""
    const plugin = await import(process.argv[2]);
    const handlers = {};
    plugin.default({ on: (name, fn) => { (handlers[name] = handlers[name] || []).push(fn); } });
    const ctx = { cwd: "/tmp/MarathonTrainingLog", model: { provider: "anthropic", id: "claude-opus" },
      sessionManager: { getSessionId: () => "019a2b", getSessionFile: () => undefined } };
    const fire = (name, event) => (handlers[name] || []).map((fn) => fn(event, ctx));
    const returned = [
      ...fire("session_start", { type: "session_start", reason: "startup" }),
      ...fire("before_agent_start", { type: "before_agent_start", prompt: "read the results" }),
      ...fire("tool_execution_start", { type: "tool_execution_start", toolCallId: "c1", toolName: "read", args: { path: "a.md" } }),
      ...fire("tool_execution_end", { type: "tool_execution_end", toolCallId: "c1", toolName: "read", result: {}, isError: false }),
      ...fire("message_end", { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "Read it." }] } }),
      ...fire(process.argv[3] === "oh-my-pi" ? "session_stop" : "agent_settled", { type: "settled" }),
      ...fire("session_shutdown", { type: "session_shutdown", reason: "quit" }),
    ];
    console.log(returned.every((value) => value === undefined) ? "RETURNED-NOTHING" : "RETURNED-SOMETHING");
    // The agent lives on after its handlers return; here the lines get a moment to land before the driver ends.
    await new Promise((resolve) => setTimeout(resolve, 1500));
    """#

    static let ampDriver = #"""
    const plugin = await import(process.argv[2]);
    const handlers = {};
    let observer = null;
    const thread = {
      id: "T-5f1d",
      parentThreadID: async () => null,
      state: { subscribe: (fn) => { observer = fn; return { unsubscribe() { observer = null; } }; } },
      messages: async () => [{ role: "assistant", id: 3, content: [{ type: "tool_use", id: "tu1", name: "Bash", input: { cmd: "git push" } }] }],
    };
    const disposers = [];
    plugin.default({
      on: (name, fn) => { (handlers[name] = handlers[name] || []).push(fn); return { unsubscribe() {} }; },
      onDispose: (fn) => { disposers.push(fn); },
      system: { workspaceRoot: { toString: () => "file:///tmp/notes-site" } },
      helpers: { filePathFromURI: (uri) => String(uri).replace("file://", ""),
                 shellCommandFromToolCall: (call) => call.tool === "Bash" ? { command: call.input.cmd } : null,
                 filesModifiedByToolCall: () => null },
    });
    const ctx = { thread };
    const fire = (name, event) => (handlers[name] || []).map((fn) => fn(event, ctx));
    const returned = [
      ...fire("session.start", { thread: { id: "T-5f1d" } }),
      ...fire("agent.start", { thread: { id: "T-5f1d" }, message: "push it", id: 1 }),
    ];
    await new Promise((resolve) => setTimeout(resolve, 200));
    observer("awaiting-approval");
    await new Promise((resolve) => setTimeout(resolve, 300));
    observer("running");
    returned.push(...fire("tool.result", { thread: { id: "T-5f1d" }, toolUseID: "tu1", tool: "Bash", input: {}, status: "done" }));
    returned.push(...fire("agent.end", { thread: { id: "T-5f1d" }, status: "done", messages: [{ role: "assistant", content: [{ type: "text", text: "Pushed." }] }] }));
    console.log(Object.keys(handlers).sort().join(","));
    console.log(returned.every((value) => value === undefined) ? "RETURNED-NOTHING" : "RETURNED-SOMETHING");
    await new Promise((resolve) => setTimeout(resolve, 1500));
    for (const dispose of disposers) dispose();
    """#

    static func decoded(_ lines: [String]) -> [BridgeCommand] {
        lines.compactMap { line in
            if case let .command(command)? = try? JSONDecoder().decode(BridgeEnvelope.self, from: Data(line.utf8)) { command } else { nil }
        }
    }

    /// Pi's extension under Node and Bun, and Oh My Pi's under Bun: six events, in order, then the runtime exits by itself
    /// though the socket never answered.
    @Test(arguments: [("node", AgentKind.pi), ("bun", AgentKind.pi), ("bun", AgentKind.ohmypi)])
    func piExtensionRunsInItsRuntime(_ name: String, _ kind: AgentKind) throws {
        let spec = try #require(AgentHookTable.spec(kind))
        let scratch = try Scratch()
        try FileManager.default.createDirectory(at: scratch.root.appendingPathComponent(spec.folder), withIntermediateDirectories: true)
        try scratch.installer().install(spec)
        let file = scratch.root.appendingPathComponent(spec.folder).appendingPathComponent(spec.file(stem: "juice"))
        guard let runtime = Self.runtime(name) else {
            // Not on this Mac: the file still parses as a module body.
            let harness = PluginAgentsTests.Harness(try String(contentsOf: file, encoding: .utf8))
            #expect(harness.failures.isEmpty && harness.string("typeof __plugin") == "function")
            return
        }
        let listener = try Listener(path: scratch.socket)
        defer { listener.stop() }
        let driver = scratch.root.appendingPathComponent("drive.mjs")
        try Data(Self.piDriver.utf8).write(to: driver)
        let run = try Self.drive(runtime, driver, [file.path, PiExtension.agentWord(kind)], home: scratch.root)
        #expect(run.finished, "\(name) did not exit: \(run.output)")
        #expect(run.status == 0 && run.output.contains("RETURNED-NOTHING"), "\(run.output)")
        for _ in 0..<100 where listener.lines.count < 6 { usleep(20_000) }
        let hooks = Self.decoded(listener.lines).compactMap { if case let .processPiHook(payload) = $0 { payload } else { nil } }
        #expect(Set(hooks.map(\.hookEventName)) == [.sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .stop, .sessionEnd], "\(listener.lines)")
        #expect(hooks.allSatisfy { $0.sessionID == "\(kind == .ohmypi ? "omp" : "pi")-019a2b" && $0.agent.tool == kind.carrierTool })
        #expect(hooks.allSatisfy { $0.terminalApp == "Terminal" && $0.cwd == "/tmp/MarathonTrainingLog" })
        #expect(hooks.first { $0.hookEventName == .stop }?.lastAssistantMessage == "Read it.")
    }

    /// Amp's plugin under Bun: its four events, the waiting thread's PermissionRequest, and an exit by itself.
    @Test
    func ampPluginRunsInBun() throws {
        let scratch = try Scratch()
        try FileManager.default.createDirectory(at: scratch.root.appendingPathComponent(".config/amp"), withIntermediateDirectories: true)
        try scratch.installer().install(AgentHookTable.amp)
        let file = scratch.root.appendingPathComponent(".config/amp/plugins/juice.ts")
        guard let runtime = Self.runtime("bun") else {
            let harness = PluginAgentsTests.Harness(try String(contentsOf: file, encoding: .utf8))
            #expect(harness.failures.isEmpty && harness.string("typeof __plugin") == "function")
            return
        }
        let listener = try Listener(path: scratch.socket)
        defer { listener.stop() }
        let driver = scratch.root.appendingPathComponent("drive.mjs")
        try Data(Self.ampDriver.utf8).write(to: driver)
        let run = try Self.drive(runtime, driver, [file.path], home: scratch.root)
        #expect(run.finished, "bun did not exit: \(run.output)")
        #expect(run.status == 0 && run.output.contains("RETURNED-NOTHING"), "\(run.output)")
        #expect(run.output.contains("agent.end,agent.start,session.start,tool.result"), "\(run.output)")
        for _ in 0..<100 where listener.lines.count < 5 { usleep(20_000) }
        let hooks = Self.decoded(listener.lines).compactMap { if case let .processOpenCodeHook(payload) = $0 { payload } else { nil } }
        #expect(Set(hooks.map(\.hookEventName)) == [.sessionStart, .userPromptSubmit, .permissionRequest, .postToolUse, .stop], "\(listener.lines)")
        #expect(hooks.allSatisfy { $0.sessionID == "amp-T-5f1d" && $0.cwd == "/tmp/notes-site" && $0.terminalApp == "Terminal" })
        #expect(hooks.first { $0.hookEventName == .permissionRequest }?.toolInput == #"{"command":"git push"}"#)
    }

    /// Juice not running (no socket at all): the files load and run, nothing is printed but the drivers' own lines, and
    /// each runtime exits at once.
    @Test
    func noSocketChangesNothingInTheRuntime() throws {
        guard let bun = Self.runtime("bun") ?? Self.runtime("node") else { return }
        let scratch = try Scratch()
        for spec in [AgentHookTable.pi, AgentHookTable.amp] {
            try FileManager.default.createDirectory(at: scratch.root.appendingPathComponent(spec.folder), withIntermediateDirectories: true)
            try scratch.installer().install(spec)
        }
        for (driverText, file, extra) in [(Self.piDriver, ".pi/agent/extensions/juice.ts", ["pi"]),
                                          (Self.ampDriver, ".config/amp/plugins/juice.ts", [])] {
            if driverText == Self.ampDriver, !bun.hasSuffix("/bun") { continue }
            let driver = scratch.root.appendingPathComponent("drive-\(UUID().uuidString.prefix(4)).mjs")
            try Data(driverText.utf8).write(to: driver)
            let run = try Self.drive(bun, driver, [scratch.root.appendingPathComponent(file).path] + extra, home: scratch.root)
            #expect(run.finished && run.status == 0 && run.output.contains("RETURNED-NOTHING"), "\(file): \(run.output)")
            #expect(run.seconds < 10, "\(file) kept its runtime alive")
        }
    }
}

/// Amp's threads and upstream's process monitor (P1168). Amp runs as `amp`, which the monitor never finds, so on
/// OpenCode's rule (ended on the second quiet poll, a minute apart) a thread would leave a minute or two after its Done,
/// or mid-turn under a long tool, and the gate would then drop its later events. Amp's threads keep Claude's and Codex's
/// rule instead: never ended while they wait on you or within 10 minutes of their last event, then on the third quiet
/// poll. OpenCode's own sessions keep upstream's.
@MainActor
struct PluginAgentsLifeTests {
    typealias F = EngineFixtures

    static func quietPoll(_ engine: SessionEngine) {
        var local = engine.state
        local.markProcessLiveness(aliveSessionIDs: [])
        local.removeInvisibleSessions()
        engine.applyMonitoredState(local)
    }

    /// Kilo's sessions ride OpenCode the same way (wave 1), and its `kilo` process is no more found than `amp`
    /// (`@kilocode/cli`'s bin is `bin/kilo`, https://registry.npmjs.org/@kilocode/cli/latest): the same rule (P1175).
    @Test(arguments: ["amp-T-5f1d", "kilo-ses_k1", "kilo2-ses_k2"])
    func anAmpThreadOutlastsQuietPollsAsClaudesDo(_ amp: String) {
        let clock = F.Box(F.now)
        let engine = F.engine(clock: clock)
        let openCode = "ses_open1"
        for id in [amp, openCode] {
            engine.ingest(F.started(id, tool: .openCode, source: nil, title: "notes-site"), ingress: .bridge)
            engine.ingest(F.prompt(id), ingress: .bridge)
            engine.ingest(F.completed(id), ingress: .bridge)
        }
        #expect(engine.agent(of: engine.state.session(id: amp)!) == AgentKind.fromSessionID(amp))
        for minute in 1...9 {
            clock.update { $0 = F.now.addingTimeInterval(TimeInterval(minute) * 60) }
            Self.quietPoll(engine)
            #expect(engine.state.session(id: amp).map { !$0.isSessionEnded } == true, "Amp's thread ended after \(minute) min")
        }
        #expect(engine.state.session(id: openCode) == nil, "OpenCode's own session keeps upstream's rule")
        // A later event still lands on the same row.
        engine.ingest(F.running(amp, summary: "Running Bash: npm test", at: clock.current), ingress: .bridge)
        #expect(engine.state.session(id: amp)?.phase == .running)
        // As the live monitor does on every bridge event (`markSessionProcessAlive`); these tests run without one.
        engine.state.markSingleSessionAlive(sessionID: amp)
        clock.update { $0 = $0.addingTimeInterval(11 * 60) }
        for pass in 1...3 {
            Self.quietPoll(engine)
            #expect((engine.state.session(id: amp) != nil) == (pass < 3), "pass \(pass)")
        }
    }
}
