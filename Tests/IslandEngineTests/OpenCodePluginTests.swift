import Foundation
import JavaScriptCore
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Juice Island's OpenCode plugin run in JavaScriptCore with OpenCode's side faked (P480 to P484): the socket is a
/// recorder, OpenCode 1's server a recorded `fetch`, OpenCode 2's context an event queue and a recorded
/// `permission.reply`. Every line the plugin writes is decoded with upstream's `BridgeEnvelope`, as the bridge decodes
/// it; every answer comes back as the bridge encodes one. The events are shaped from OpenCode's public source
/// (anomalyco/opencode: v1.18.33 `packages/opencode/src/{permission,question}`, v2.0.18 `packages/schema/src`
/// `session-event.ts`, `permission.ts`, `form.ts`, and `tool/plugin/question.ts`). Nothing touches the network or a
/// real socket.
@MainActor
struct OpenCodePluginTests {
    /// The plugin with its two imports replaced by the harness's `connect` and `homedir`.
    final class Harness {
        let context = JSContext()!
        var failures: [String] = []

        init() {
            context.exceptionHandler = { [weak self] _, value in self?.failures.append(value?.toString() ?? "exception") }
            context.evaluateScript(Self.prelude)
            let body = OpenCodePlugin.source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("import ") }
                .joined(separator: "\n")
                .replacingOccurrences(of: "export default ", with: "globalThis.__plugin = ")
            context.evaluateScript(body)
        }

        @discardableResult
        func run(_ script: String) -> JSValue? { context.evaluateScript(script) }

        /// Every command the plugin wrote, in order, as the bridge decodes it.
        var commands: [OpenCodeHookPayload] {
            sockets.compactMap(\.payload)
        }

        struct Socket {
            var payload: OpenCodeHookPayload?
            var destroyed: Bool
            var timeout: Int?
        }

        var sockets: [Socket] {
            let count = Int(run("__sockets.length")?.toInt32() ?? 0)
            return (0..<count).map { index in
                let written = run("__sockets[\(index)].written")?.toString() ?? ""
                let line = written.split(separator: "\n").first.map(String.init) ?? ""
                var payload: OpenCodeHookPayload?
                if case let .command(.processOpenCodeHook(decoded))? = try? JSONDecoder().decode(BridgeEnvelope.self, from: Data(line.utf8)) {
                    payload = decoded
                }
                return Socket(payload: payload, destroyed: run("__sockets[\(index)].destroyed")?.toBool() ?? false,
                              timeout: (run("__sockets[\(index)].timeout")).flatMap { $0.isNumber ? Int($0.toInt32()) : nil })
            }
        }

        func socketIndex(_ event: OpenCodeHookEventName) -> Int? {
            sockets.firstIndex { $0.payload?.hookEventName == event }
        }

        /// The bridge's answer on a held connection: its hello, then the response line.
        func answer(socket index: Int, _ directive: OpenCodeHookDirective) throws {
            let response = try BridgeCodec.encodeLine(.response(.openCodeHookDirective(directive)))
            let line = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .newlines)
            let hello = #"{"type":"hello"}"#
            run("__sockets[\(index)].emit('data', \(Self.quoted(hello + "\n" + line + "\n")))")
        }

        static func quoted(_ text: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [text])
            return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
        }

        static let prelude = #"""
        var __sockets = [];
        var __fetches = [];
        var __replies = [];
        var __queue = [];
        var __waiter = null;
        var process = { pid: 4242, env: { HOME: "/Users/tester", OPEN_ISLAND_SOCKET_PATH: "/tmp/ji-test.sock",
                                          TERM_PROGRAM: "iTerm.app", ITERM_SESSION_ID: "w0t1p0:ABCD" } };
        function homedir() { return "/Users/tester"; }
        class Request { constructor(url, init) { this.url = url; this.init = init; } }
        function connect(options, onConnect) {
          const socket = {
            path: options.path, written: "", destroyed: false, handlers: {}, timeout: null,
            on(name, fn) { (this.handlers[name] = this.handlers[name] || []).push(fn); return this; },
            emit(name, arg) { for (const fn of this.handlers[name] || []) fn(arg); },
            write(text) { this.written += text; },
            end(text) { if (text) this.written += text; Promise.resolve().then(() => this.emit("end")); },
            destroy() { this.destroyed = true; },
            setTimeout(ms, fn) { this.timeout = ms; this.onTimeout = fn; },
          };
          __sockets.push(socket);
          Promise.resolve().then(() => onConnect && onConnect());
          return socket;
        }
        function __push(event) {
          if (__waiter) { const w = __waiter; __waiter = null; w({ value: event, done: false }); } else { __queue.push(event); }
        }
        var __ctx = {
          location: { directory: "/tmp/notes-site" },
          event: { subscribe: () => ({ [Symbol.asyncIterator]() { return {
            next: () => __queue.length ? Promise.resolve({ value: __queue.shift(), done: false })
                                       : new Promise((resolve) => { __waiter = resolve; }),
            return: () => Promise.resolve({ done: true }) }; } }) },
          permission: { reply: async (input) => { __replies.push(input); } },
        };
        var __v1 = null;
        function __startV1() {
          __plugin.server({ client: { _client: { getConfig: () => ({ fetch: async (request) => {
            __fetches.push({ url: request.url, body: request.init.body }); } }) } }, serverUrl: { port: "5555" } })
            .then((hooks) => { __v1 = hooks; });
        }
        function __v1Event(event) { __v1.event({ event }); }
        """#
    }

    /// v2 events: the `data` envelope OpenCode 2's event stream carries.
    static func v2(_ type: String, _ data: [String: Any], directory: String? = "/tmp/notes-site") -> String {
        var event: [String: Any] = ["id": "evt_1", "type": type, "created": 1, "data": data]
        if let directory { event["location"] = ["directory": directory] }
        let json = try! JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        return String(decoding: json, as: UTF8.self)
    }

    /// v1 events: the `properties` envelope OpenCode 1's bus carries.
    static func v1(_ type: String, _ properties: [String: Any]) -> String {
        let json = try! JSONSerialization.data(withJSONObject: ["type": type, "properties": properties], options: [.sortedKeys])
        return String(decoding: json, as: UTF8.self)
    }

    // MARK: The module

    /// One default export both loaders take: OpenCode 2's wants `id` and a `setup` function (external.ts), OpenCode 1's
    /// an `id` and a `server` function (plugin/shared.ts `readV1Plugin`); the first line names the revision Setup reads.
    @Test
    func oneExportForBothLoaders() throws {
        let harness = Harness()
        #expect(harness.failures.isEmpty)
        #expect(harness.run("typeof __plugin.id")?.toString() == "string")
        #expect(harness.run("__plugin.id")?.toString() == "juice-island")
        #expect(harness.run("typeof __plugin.setup")?.toString() == "function")
        #expect(harness.run("typeof __plugin.server")?.toString() == "function")
        #expect(harness.run("__plugin.revision")?.toInt32() == Int32(OpenCodePlugin.revision))
        #expect(OpenCodePluginFile.of(contents: OpenCodePlugin.data) == .ours(revision: OpenCodePlugin.revision))
        #expect(OpenCodePlugin.source.contains("const REVISION = \(OpenCodePlugin.revision);"))
    }

    /// P483: no log file, no environment changed for OpenCode's shells, no other host than OpenCode's own server.
    @Test
    func itWritesNoLogAndChangesNoShell() {
        let source = OpenCodePlugin.source
        for banned in ["appendFileSync", "writeFileSync", "/tmp/", "shell.env", "debugLog", "console."] {
            #expect(!source.contains(banned), "\(banned)")
        }
        #expect(source.components(separatedBy: "http://").count == 2)
        #expect(source.contains("http://localhost:${port}"))
    }

    // MARK: OpenCode 2

    /// A v2 session from start to Done: SessionStart with its folder, the owner's prompt (never a synthetic one),
    /// PreToolUse and PostToolUse named from the tool's input, Stop with the last reply; every session `opencode2-…`
    /// and no terminal (P482).
    @Test
    func aV2TurnReachesTheBridgeAsOpenIslandsHooks() throws {
        let harness = Harness()
        harness.run("__plugin.setup(__ctx)")
        let events = [
            Self.v2("session.created", ["sessionID": "ses_1", "location": ["directory": "/tmp/notes-site"], "slug": "s", "version": "2.0.18"]),
            Self.v2("session.inbox.enqueued", ["sessionID": "ses_1", "inboxID": "msg_1",
                                               "item": ["type": "user", "payload": ["text": "sort the notes"], "delivery": "queue"]]),
            Self.v2("session.inbox.enqueued", ["sessionID": "ses_1", "inboxID": "msg_2",
                                               "item": ["type": "synthetic", "payload": ["text": "Continue if you have next steps"],
                                                        "delivery": "queue"]]),
            Self.v2("session.tool.input.started", ["sessionID": "ses_1", "assistantMessageID": "msg_3", "id": "call_1", "name": "glob"]),
            Self.v2("session.tool.called", ["sessionID": "ses_1", "assistantMessageID": "msg_3", "id": "call_1",
                                            "input": ["pattern": "**/*.md"], "executed": true]),
            Self.v2("session.tool.success", ["sessionID": "ses_1", "assistantMessageID": "msg_3", "id": "call_1",
                                             "content": [["type": "text", "text": "a.md"]], "executed": true]),
            Self.v2("session.text.ended", ["sessionID": "ses_1", "assistantMessageID": "msg_4", "ordinal": 0,
                                           "text": "Sorted the notes by date."]),
            Self.v2("session.execution.succeeded", ["sessionID": "ses_1"]),
        ]
        for event in events { harness.run("__push(\(event))") }
        #expect(harness.failures.isEmpty)
        let sent = harness.commands
        #expect(sent.map(\.hookEventName) == [.sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .stop])
        #expect(sent.allSatisfy { $0.sessionID == "opencode2-ses_1" && $0.cwd == "/tmp/notes-site" })
        #expect(sent.allSatisfy { $0.terminalApp == nil && $0.terminalTTY == nil && $0.terminalSessionID == nil })
        #expect(sent[1].prompt == "sort the notes")
        #expect(sent[2].toolName == "Glob" && sent[2].toolInput == #"{"pattern":"**/*.md"}"#)
        #expect(sent[3].toolName == "Glob")
        #expect(sent[4].lastAssistantMessage == "Sorted the notes by date.")
        #expect(OpenCodeAPI.of(sessionID: sent[0].sessionID) == .two)
    }

    /// A turn a steered prompt took over is not Done (no Stop, no sound); one the owner interrupted is.
    @Test
    func aSupersededTurnIsNotDone() {
        let harness = Harness()
        harness.run("__plugin.setup(__ctx)")
        harness.run("__push(\(Self.v2("session.execution.interrupted", ["sessionID": "ses_1", "reason": "superseded"])))")
        #expect(harness.commands.isEmpty)
        harness.run("__push(\(Self.v2("session.execution.interrupted", ["sessionID": "ses_1", "reason": "user"])))")
        #expect(harness.commands.map(\.hookEventName) == [.stop])
    }

    /// An approval: the box gets OpenCode's whole command (`cd` included, P179) from the tool's input, the patterns and
    /// the sentence the app reads; Allow goes back through `ctx.permission.reply` for that request only.
    @Test
    func aV2ApprovalIsAnsweredThroughPermissionReply() throws {
        let harness = Harness()
        harness.run("__plugin.setup(__ctx)")
        for event in [
            Self.v2("session.tool.input.started", ["sessionID": "ses_1", "assistantMessageID": "msg_1", "id": "call_9", "name": "shell"]),
            Self.v2("session.tool.called", ["sessionID": "ses_1", "assistantMessageID": "msg_1", "id": "call_9",
                                            "input": ["command": "cd ~ && rm -rf build"], "executed": true]),
            Self.v2("permission.asked", ["id": "per_1", "sessionID": "ses_1", "action": "shell", "resources": ["rm -rf build"],
                                         "save": ["rm *"], "source": ["type": "tool", "messageID": "msg_1", "id": "call_9"]]),
        ] { harness.run("__push(\(event))") }
        let index = try #require(harness.socketIndex(.permissionRequest))
        let asked = try #require(harness.sockets[index].payload)
        #expect(asked.sessionID == "opencode2-ses_1" && asked.permissionID == "per_1" && asked.toolName == "Shell")
        #expect(asked.permissionDescription == "OpenCode wants to run Shell: rm -rf build")
        let input = try #require(asked.toolInput)
        #expect(input.hasPrefix(#"{"metadata":{"command":"cd ~ && rm -rf build"},"patterns":["rm -rf build"]"#))
        #expect(harness.sockets[index].timeout == 30 * 60 * 1000)
        // What the card shows (the app's own reading of the bridge's request).
        #expect(OpenCodeCutPatternsProbe.command(in: asked.toolInputPreview ?? "") == "cd ~ && rm -rf build")

        try harness.answer(socket: index, .allow)
        #expect(harness.failures.isEmpty)
        #expect(harness.run("JSON.stringify(__replies)")?.toString() == #"[{"sessionID":"ses_1","requestID":"per_1","decision":"once"}]"#)
    }

    /// A No carries the island's reason, as OpenCode's own reject with feedback does.
    @Test
    func aV2DenialCarriesItsReason() throws {
        let harness = Harness()
        harness.run("__plugin.setup(__ctx)")
        harness.run("__push(\(Self.v2("permission.asked", ["id": "per_2", "sessionID": "ses_1", "action": "edit", "resources": ["src/a.ts"]])))")
        let index = try #require(harness.socketIndex(.permissionRequest))
        #expect(harness.sockets[index].payload?.toolInput == #"{"patterns":["src/a.ts"],"file_path":"src/a.ts"}"#)
        try harness.answer(socket: index, .deny(reason: "use the other file"))
        #expect(harness.run("JSON.stringify(__replies)")?.toString()
                == #"[{"sessionID":"ses_1","requestID":"per_2","decision":"reject","message":"use the other file"}]"#)
    }

    /// Answered in OpenCode first: the card's connection closes (the bridge lets the request go, so a late click answers
    /// nothing) and PostToolUse follows. A newer request of the session closes the older one's connection too.
    @Test
    func aV2RequestAnsweredInOpenCodeClosesItsCard() throws {
        let harness = Harness()
        harness.run("__plugin.setup(__ctx)")
        harness.run("__push(\(Self.v2("permission.asked", ["id": "per_3", "sessionID": "ses_1", "action": "shell", "resources": ["ls"]])))")
        harness.run("__push(\(Self.v2("permission.asked", ["id": "per_4", "sessionID": "ses_1", "action": "shell", "resources": ["pwd"]])))")
        #expect(harness.sockets.map(\.destroyed) == [true, false])
        harness.run("__push(\(Self.v2("permission.replied", ["sessionID": "ses_1", "requestID": "per_4", "reply": "once"])))")
        #expect(harness.sockets.map(\.destroyed) == [true, true, false])
        #expect(harness.commands.last?.hookEventName == .postToolUse)
        // A click that arrives after: nothing goes to OpenCode.
        try harness.answer(socket: 1, .allow)
        #expect(harness.run("__replies.length")?.toInt32() == 0)
    }

    /// OpenCode 2's question (a form the question tool asks, `metadata.kind` "question"): its header and question
    /// from the field, options by label, a multiselect as one; any other form is not a question. It is held only to
    /// keep the card up, and closed once OpenCode is answered.
    @Test
    func aV2QuestionIsSentAndClosedWhenOpenCodeIsAnswered() throws {
        let harness = Harness()
        harness.run("__plugin.setup(__ctx)")
        let form: [String: Any] = [
            "id": "frm_1", "sessionID": "ses_1", "title": "Questions",
            "metadata": ["kind": "question", "tool": ["messageID": "msg_1", "id": "call_2"]],
            "fields": [
                ["key": "q0", "title": "Branch", "description": "Which branch should the release go out from?", "type": "string",
                 "options": [["value": "main", "label": "main", "description": "What is merged today."],
                             ["value": "release/0.4", "label": "release/0.4", "description": "Fixes only."]], "custom": true],
                ["key": "q1", "title": "Checks", "description": "Which checks should run?", "type": "multiselect",
                 "options": [["value": "unit", "label": "unit"], ["value": "ui", "label": "ui"]]],
            ],
        ]
        harness.run("__push(\(Self.v2("form.created", ["form": ["id": "frm_x", "sessionID": "ses_1", "title": "Sign in", "fields": [["key": "k", "type": "string"]]]])))")
        #expect(harness.commands.isEmpty)
        harness.run("__push(\(Self.v2("form.created", ["form": form])))")
        let index = try #require(harness.socketIndex(.questionAsked))
        let asked = try #require(harness.sockets[index].payload)
        #expect(asked.sessionID == "opencode2-ses_1" && asked.questionID == "frm_1")
        let prompt = asked.questionPrompt
        #expect(prompt.questions.map(\.question) == ["Which branch should the release go out from?", "Which checks should run?"])
        #expect(prompt.questions.map(\.header) == ["Branch", "Checks"])
        #expect(prompt.questions.map { $0.options.map(\.label) } == [["main", "release/0.4"], ["unit", "ui"]])
        #expect(prompt.questions.map(\.multiSelect) == [false, true])
        // Should an answer reach the plugin anyway, it goes nowhere: OpenCode 2 has no reply a plugin can make.
        try harness.answer(socket: index, .answer(text: "main"))
        #expect(harness.run("__replies.length")?.toInt32() == 0 && harness.run("__fetches.length")?.toInt32() == 0)

        let again = Harness()
        again.run("__plugin.setup(__ctx)")
        again.run("__push(\(Self.v2("form.created", ["form": form])))")
        again.run("__push(\(Self.v2("form.replied", ["id": "frm_1", "sessionID": "ses_1", "answer": ["q0": "main"]])))")
        #expect(again.sockets.map(\.destroyed) == [true, false])
        #expect(again.commands.map(\.hookEventName) == [.questionAsked, .postToolUse])
    }

    /// The cleanup `setup` returns closes every open card's connection.
    @Test
    func unloadingClosesEveryCard() {
        let harness = Harness()
        harness.run("var __cleanup = null; __plugin.setup(__ctx).then((c) => { __cleanup = c; })")
        harness.run("__push(\(Self.v2("permission.asked", ["id": "per_5", "sessionID": "ses_2", "action": "shell", "resources": ["ls"]])))")
        harness.run("__cleanup()")
        #expect(harness.sockets.map(\.destroyed) == [true])
    }

    // MARK: OpenCode 1

    /// OpenCode 1 as Open Island's plugin reports it (`opencode-…`, its terminal), with the folder kept for SessionEnd,
    /// a synthetic part left out, one PreToolUse per call, and the island's answers posted to OpenCode's own server.
    @Test
    func v1KeepsOpenIslandsPathWithItsFixes() throws {
        let harness = Harness()
        harness.run("__startV1()")
        func event(_ json: String) { harness.run("__v1Event(\(json))") }
        event(Self.v1("session.created", ["info": ["id": "ses_a", "directory": "/tmp/notes-site"]]))
        event(Self.v1("message.updated", ["info": ["id": "m1", "sessionID": "ses_a", "role": "user"]]))
        event(Self.v1("message.part.updated", ["part": ["type": "text", "messageID": "m1", "text": "push the fix"]]))
        event(Self.v1("message.part.updated", ["part": ["type": "text", "messageID": "m1", "text": "<path>a</path>", "synthetic": true]]))
        let running: [String: Any] = ["part": ["id": "p1", "type": "tool", "tool": "bash", "sessionID": "ses_a",
                                               "state": ["status": "running", "input": ["command": "ls"]]]]
        event(Self.v1("message.part.updated", running))
        event(Self.v1("message.part.updated", running))
        event(Self.v1("message.part.updated", ["part": ["id": "p1", "type": "tool", "tool": "bash", "sessionID": "ses_a",
                                                        "state": ["status": "completed"]]]))
        event(Self.v1("permission.asked", ["id": "per_9", "sessionID": "ses_a", "permission": "bash",
                                           "patterns": ["git push origin fix/intro-links"],
                                           "metadata": ["command": "git push origin fix/intro-links"]]))
        let permission = try #require(harness.socketIndex(.permissionRequest))
        try harness.answer(socket: permission, .deny(reason: "Denied from Juice Island."))
        event(Self.v1("question.asked", ["id": "que_1", "sessionID": "ses_a",
                                         "questions": [["question": "Ship it?", "header": "Ship", "options": [["label": "Yes", "description": ""]]]]]))
        event(Self.v1("session.deleted", ["info": ["id": "ses_a"]]))
        #expect(harness.failures.isEmpty)
        let sent = harness.commands
        #expect(sent.map(\.hookEventName) == [.sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .permissionRequest,
                                               .questionAsked, .sessionEnd])
        #expect(sent.allSatisfy { $0.sessionID == "opencode-ses_a" && $0.cwd == "/tmp/notes-site" })
        #expect(sent.allSatisfy { $0.terminalApp == "iTerm" && $0.terminalSessionID == "w0t1p0:ABCD" })
        #expect(sent[2].toolName == "Bash")
        #expect(OpenCodeAPI.of(sessionID: sent[0].sessionID) == .one)

        let question = try #require(harness.socketIndex(.questionAsked))
        try harness.answer(socket: question, .answer(text: "Yes"))
        #expect(harness.run("JSON.stringify(__fetches)")?.toString() == """
            [{"url":"http://localhost:5555/permission/per_9/reply","body":"{\\"reply\\":\\"reject\\",\\"message\\":\\"Denied from Juice Island.\\"}"},\
            {"url":"http://localhost:5555/question/que_1/reply","body":"{\\"answers\\":[[\\"Yes\\"]]}"}]
            """)
    }

    /// v1, as the bridge keeps one request per session: a newer one of the session closes the older one's connection,
    /// so a click on a card the island no longer shows cannot answer it.
    @Test
    func v1ANewerRequestClosesTheOlderCard() throws {
        let harness = Harness()
        harness.run("__startV1()")
        harness.run("__v1Event(\(Self.v1("permission.asked", ["id": "per_1", "sessionID": "ses_a", "permission": "bash", "patterns": ["ls"]])))")
        harness.run("__v1Event(\(Self.v1("question.asked", ["id": "que_1", "sessionID": "ses_a", "questions": [["question": "Go?", "options": [["label": "Yes"]]]]])))")
        #expect(harness.sockets.map(\.destroyed) == [true, false])
        try harness.answer(socket: 0, .allow)
        #expect(harness.run("__fetches.length")?.toInt32() == 0)
    }

    /// v1: `permission.replied` and `question.replied` close their card's connection.
    @Test
    func v1ClosesACardAnsweredInOpenCode() throws {
        let harness = Harness()
        harness.run("__startV1()")
        harness.run("__v1Event(\(Self.v1("permission.asked", ["id": "per_1", "sessionID": "ses_a", "permission": "edit", "patterns": ["a.ts"]])))")
        harness.run("__v1Event(\(Self.v1("permission.replied", ["sessionID": "ses_a", "requestID": "per_1", "reply": "once"])))")
        #expect(harness.sockets.first?.destroyed == true)
        #expect(harness.commands.map(\.hookEventName) == [.permissionRequest, .postToolUse])
    }
}

/// The app's reading of a clipped OpenCode input (`OpenCodeCutPatterns.metadataCommand`, in JuiceIslandUI), repeated
/// for the engine's tests: the whole command the box shows, from `"metadata":{"command":"…"`.
enum OpenCodeCutPatternsProbe {
    static func command(in text: String) -> String? {
        guard let start = text.range(of: #""metadata":{"command":""#) else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
