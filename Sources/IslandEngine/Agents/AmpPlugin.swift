import Foundation
import IslandHookNotes

/// Juice's plugin for Amp (P1157 to P1164): a TypeScript file Juice writes whole into Amp's system plugins folder
/// (`~/.config/amp/plugins/<flavor's stem>.ts`), only on a click in Settings › Agents (`AgentHookInstaller`). Amp runs
/// every `.ts` and `.js` there with its own Bun, with no npm install, so it imports only Node's own `net` and
/// `child_process` and no type from `@ampcode/plugin`.
///
/// It speaks OpenCode's hook payload to the app's own socket (`BridgeServer.handleOpenCodeHook` decodes it unchanged),
/// its sessions named `amp-<thread id>`, by which the engine labels them Amp (`AgentKind.fromSessionID`), as Kilo's are:
/// `session.start` is SessionStart, `agent.start` UserPromptSubmit, `tool.result` PostToolUse and `agent.end` Stop with
/// the turn's last reply. While a thread's state is `awaiting-approval` (another plugin of the owner's asks before a
/// call: Amp itself asks about none, "Amp does not ask for approval before running tools"), it keeps one connection open
/// with a PermissionRequest naming the call, and closes it once the state moves on: the island shows the thread as
/// waiting, read-only, with Open (Watch, `SessionEngine.takeBridgeRequest`), and the bridge ends the card when the
/// connection closes.
///
/// Amp is Watch (P1158): Amp asks about no call, its plugin API says nothing of what another plugin will ask, and a
/// `tool.call` handler must return a decision, so a plugin of Juice's there would either gate calls Amp never asks about
/// or answer `allow` beside the owner's own policy plugin, in an order Amp leaves undefined. So it registers no
/// `tool.call`; every handler it has returns nothing, which Amp's types read as "no change", at once, and nothing in
/// Amp waits on the app.
public enum AmpPlugin {
    /// The plugin's revision, on its first line: an older one of Juice's is offered Update.
    public static let revision = 1
    /// The first line of every revision, before the number.
    static let marker = "// Juice plugin for Amp, revision "

    /// The plugin that dials `socketPath`.
    public static func source(socketPath: String) -> String {
        template.replacingOccurrences(of: socketPlaceholder, with: AgentPlugins.jsString(socketPath))
    }

    static let socketPlaceholder = "__JUICE_SOCKET_PATH__"

    static let template = #"""
// Juice plugin for Amp, revision 1.
// Tells the app's own hook socket what Amp's threads do: their start, prompts, tool results and turns, and when Amp
// waits for an approval. It decides no tool call, never waits on the app and changes nothing in Amp. Installed and
// removed only from the app's Settings, Agents. It writes no file and logs nothing.
import { connect } from "node:net";
import { execFile } from "node:child_process";

export const description = "Shows Amp's threads in Juice. It decides no tool call and waits on nothing.";

const REVISION = 1;
const SOCKET_PATH = __JUICE_SOCKET_PATH__;
// One connection per event, given up after this long. Nothing in Amp waits on it.
const SEND_TIMEOUT_MS = 1000;
// A waiting thread's connection stays open this long at most. It holds nothing: Amp's own prompt decides.
const HOLD_MS = 30 * 60 * 1000;
// The threads it keeps anything for, oldest forgotten first.
const THREAD_LIMIT = 200;

function envelope(command) {
  return JSON.stringify({ type: "command", command }) + "\n";
}

function send(command) {
  try {
    const sock = connect({ path: SOCKET_PATH }, () => {
      sock.end(envelope(command));
    });
    sock.on("data", () => {});
    sock.on("error", () => {});
    sock.setTimeout(SEND_TIMEOUT_MS, () => sock.destroy());
    if (typeof sock.unref === "function") sock.unref();
  } catch {}
}

// Keeps a connection open while Amp waits: the island shows the thread as waiting until it closes. Returns its close.
function hold(command) {
  let sock = null;
  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    try {
      if (sock) sock.destroy();
    } catch {}
  };
  try {
    sock = connect({ path: SOCKET_PATH }, () => {
      if (!closed) sock.write(envelope(command));
    });
    sock.on("data", () => {});
    sock.on("error", close);
    sock.on("end", close);
    sock.setTimeout(HOLD_MS, close);
    if (typeof sock.unref === "function") sock.unref();
  } catch {
    close();
  }
  return close;
}

function hookCommand(event, sessionID, cwd, extra) {
  const hook = { hook_event_name: event, session_id: sessionID, cwd: cwd || "." };
  for (const [key, value] of Object.entries(extra || {})) {
    if (value !== undefined && value !== null && value !== "") hook[key] = value;
  }
  return { type: "processOpenCodeHook", openCodeHook: hook };
}

function terminalFields(env) {
  const result = {};
  if (env.ITERM_SESSION_ID) {
    result.terminal_app = "iTerm";
    result.terminal_session_id = env.ITERM_SESSION_ID;
  } else if (env.CMUX_WORKSPACE_ID || env.CMUX_SOCKET_PATH) {
    result.terminal_app = "cmux";
    if (env.CMUX_SURFACE_ID) result.terminal_session_id = env.CMUX_SURFACE_ID;
  } else if (env.ZELLIJ != null) {
    result.terminal_app = "Zellij";
    const pane = env.ZELLIJ_PANE_ID || "";
    const name = env.ZELLIJ_SESSION_NAME || "";
    if (pane) result.terminal_session_id = `${pane}:${name}`;
  } else if (env.GHOSTTY_RESOURCES_DIR || (env.TERM_PROGRAM || "").toLowerCase().includes("ghostty")) {
    result.terminal_app = "Ghostty";
  } else if (env.TERM_PROGRAM === "Apple_Terminal") {
    result.terminal_app = "Terminal";
  } else if (env.TERM_PROGRAM) {
    result.terminal_app = env.TERM_PROGRAM;
  }
  if (env.TERM_SESSION_ID && !result.terminal_session_id) result.terminal_session_id = env.TERM_SESSION_ID;
  return result;
}

// The terminal's tty: the first process up from this one that has one (`ps`, at most 8 steps of 1 s each).
function findTTY(pid, steps, done) {
  if (steps <= 0 || !pid || pid <= 1) return done(undefined);
  try {
    execFile("/bin/ps", ["-o", "tty=,ppid=", "-p", String(pid)], { timeout: 1000 }, (error, stdout) => {
      if (error) return done(undefined);
      const [tty, parent] = String(stdout).trim().split(/\s+/);
      if (tty && tty !== "??" && tty !== "?") return done(`/dev/${tty}`);
      findTTY(Number.parseInt(parent || "", 10), steps - 1, done);
    });
  } catch {
    done(undefined);
  }
}

function preview(value, limit) {
  try {
    const text = typeof value === "string" ? value : JSON.stringify(value);
    if (typeof text !== "string") return undefined;
    return text.length > limit ? text.slice(0, limit) : text;
  } catch {
    return undefined;
  }
}

// A promise of `promise`'s value, or of `fallback` after `ms`.
function within(promise, ms, fallback) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(fallback), ms);
    if (timer && typeof timer.unref === "function") timer.unref();
    Promise.resolve(promise).then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      () => {
        clearTimeout(timer);
        resolve(fallback);
      },
    );
  });
}

// The turn's last reply: the text of its last assistant message.
function lastReply(messages) {
  if (!Array.isArray(messages)) return undefined;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (!message || message.role !== "assistant" || !Array.isArray(message.content)) continue;
    const text = message.content
      .filter((block) => block && block.type === "text" && typeof block.text === "string")
      .map((block) => block.text)
      .join("\n")
      .trim();
    if (text) return text;
  }
  return undefined;
}

// The call Amp waits on: the last tool use of the thread's last assistant messages.
function lastCall(messages) {
  if (!Array.isArray(messages)) return null;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const content = messages[index] && Array.isArray(messages[index].content) ? messages[index].content : [];
    for (let block = content.length - 1; block >= 0; block -= 1) {
      if (content[block] && content[block].type === "tool_use" && typeof content[block].name === "string") return content[block];
    }
  }
  return null;
}

export default function juiceAmpPlugin(amp) {
  const threads = new Map();
  let terminal = null;
  let cwd;
  try {
    const root = amp.system && amp.system.workspaceRoot;
    if (root) cwd = amp.helpers.filePathFromURI(root);
  } catch {}
  if (!cwd && typeof process === "object" && typeof process.cwd === "function") cwd = process.cwd();

  // The terminal's fields, read once, at the first event; every event waits for them, in order.
  function ready() {
    if (!terminal) {
      terminal = new Promise((resolve) => {
        const fields = terminalFields((typeof process === "object" && process.env) || {});
        findTTY(typeof process === "object" ? process.pid : 0, 8, (tty) => {
          if (tty) fields.terminal_tty = tty;
          resolve(fields);
        });
      });
    }
    return terminal;
  }

  // A thread's own record: whether it is a subagent's (whose parent it then names), its state watch and its waiting
  // card's connection. `known` settles once the parent is asked.
  function record(id, thread) {
    let entry = threads.get(id);
    if (entry) return entry;
    entry = { parent: null, known: null, watch: null, close: null, waiting: false };
    const asked = thread && typeof thread.parentThreadID === "function" ? within(thread.parentThreadID(), 1000, null) : null;
    entry.known = Promise.all([ready(), asked]).then(([fields, parent]) => {
      entry.parent = typeof parent === "string" && parent ? parent : null;
      return fields;
    });
    threads.set(id, entry);
    if (threads.size > THREAD_LIMIT) {
      const [oldest] = threads.keys();
      forget(oldest);
    }
    watch(id, entry, thread);
    return entry;
  }

  function forget(id) {
    const entry = threads.get(id);
    if (!entry) return;
    if (entry.close) entry.close();
    try {
      if (entry.watch) entry.watch.unsubscribe();
    } catch {}
    threads.delete(id);
  }

  // A subagent's thread is its parent's session: only its waiting shows, on its parent's row.
  function emit(event, id, thread, extra) {
    if (!id) return;
    const entry = record(id, thread);
    entry.known.then((fields) => {
      if (entry.parent) return;
      send(hookCommand(event, `amp-${id}`, cwd, { ...fields, ...extra }));
    });
  }

  function watch(id, entry, thread) {
    if (!thread || !thread.state || typeof thread.state.subscribe !== "function") return;
    try {
      entry.watch = thread.state.subscribe((state) => {
        if (state === "awaiting-approval") startWaiting(id, entry, thread);
        else endWaiting(entry);
      });
    } catch {}
  }

  function startWaiting(id, entry, thread) {
    if (entry.waiting) return;
    entry.waiting = true;
    const read = thread && typeof thread.messages === "function"
      ? within(thread.messages({ from: "end", limit: 3, roles: ["assistant"] }), 1000, [])
      : Promise.resolve([]);
    Promise.all([entry.known, read]).then(([fields, messages]) => {
      if (!entry.waiting || entry.close) return;
      const session = `amp-${entry.parent || id}`;
      entry.close = hold(hookCommand("PermissionRequest", session, cwd, { ...fields, ...waiting(lastCall(messages)) }));
    });
  }

  function endWaiting(entry) {
    if (!entry.waiting) return;
    entry.waiting = false;
    if (entry.close) {
      entry.close();
      entry.close = null;
    }
  }

  // What the island's read-only card shows: the call's command, or the file it changes, or its input.
  function waiting(call) {
    if (!call) {
      return { tool_input: "{}", permission_title: "Amp is waiting", permission_description: "Amp is waiting for an answer in Amp." };
    }
    const asked = { toolUseID: call.id, tool: call.name, input: call.input || {} };
    let input = call.input || {};
    try {
      const shell = amp.helpers.shellCommandFromToolCall(asked);
      const files = shell ? null : amp.helpers.filesModifiedByToolCall(asked);
      if (shell && shell.command) input = { command: shell.command };
      else if (files && files.length > 0) input = { file_path: amp.helpers.filePathFromURI(files[0]) };
    } catch {}
    return {
      tool_name: call.name,
      tool_input: preview(input, 4000),
      permission_title: `Allow ${call.name}`,
      permission_description: "Amp is waiting for an answer in Amp.",
    };
  }

  function threadOf(event, ctx) {
    return (event && event.thread && event.thread.id) || (ctx && ctx.thread && ctx.thread.id) || null;
  }

  amp.on("session.start", (event, ctx) => {
    emit("SessionStart", threadOf(event, ctx), ctx && ctx.thread);
  });

  amp.on("agent.start", (event, ctx) => {
    emit("UserPromptSubmit", threadOf(event, ctx), ctx && ctx.thread, {
      prompt: event && typeof event.message === "string" ? event.message : undefined,
    });
  });

  amp.on("tool.result", (event, ctx) => {
    emit("PostToolUse", threadOf(event, ctx), ctx && ctx.thread, { tool_name: event && event.tool });
  });

  amp.on("agent.end", (event, ctx) => {
    const id = threadOf(event, ctx);
    const entry = id ? threads.get(id) : null;
    if (entry) endWaiting(entry);
    emit("Stop", id, ctx && ctx.thread, { last_assistant_message: lastReply(event && event.messages) });
  });

  if (typeof amp.onDispose === "function") {
    amp.onDispose(() => {
      for (const id of [...threads.keys()]) forget(id);
    });
  }
}
"""#
}
