// Changed from Open Island 1.2.1's Sources/OpenIslandApp/Resources/open-island-pi.ts (GPL-3.0), October 2026: the same
// events and payload, on the app's own socket, with the differences below.
import Foundation
import IslandHookNotes

/// Juice's extension for Pi and Oh My Pi (P1150 to P1156): a TypeScript file Juice writes whole into the agent's own
/// extensions folder (`~/.pi/agent/extensions/<flavor's stem>.ts`, `~/.omp/agent/extensions/…`), only on a click in
/// Settings › Agents (`AgentHookInstaller`). Both agents load every `.ts` and `.js` there at start (Pi through `jiti`, Oh
/// My Pi through Bun) with no npm install, so it imports only Node's own `net` and `child_process`.
///
/// What it sends is what Open Island's extension sends (`BridgeServer.handlePiHook` decodes it unchanged: SessionStart,
/// UserPromptSubmit, PreToolUse, PostToolUse, Stop, SessionEnd and a Heartbeat every 15 s, which upstream's state uses as
/// a Pi session's liveness), with these differences: the app's own socket (`HookHome`, P900), baked in; no handler ever
/// returns a promise, so neither agent waits on the island, even at its turn's end or its shutdown (upstream returned the
/// send for both, holding the agent up to 3 s); one connection per event, given up after 1 s; the terminal's tty read once
/// at the first session start, off the agent's thread (upstream ran `ps` up to eight times, blocking, as the module
/// loaded, which Pi's docs ask extensions not to do); no `OPEN_ISLAND_ACTIVE` put into the agent's environment. It
/// registers none of the events that let an extension decide or that change what the agent does by being handled:
/// `tool_call`, `tool_result`, Oh My Pi's `tool_approval_requested` and `tool_approval_resolved` (any handler of these
/// four turns off Oh My Pi's early reads, `speculation/host.ts` `hasLifecycleHandlers`, P1153).
public enum PiExtension {
    /// The extension's revision, on its first line: an older one of Juice's is offered Update.
    public static let revision = 1
    /// The first line of every revision, before the number.
    static let marker = "// Juice extension for Pi and Oh My Pi, revision "

    /// The extension for `kind` (`.pi` or `.ohmypi`) that dials `socketPath`.
    public static func source(socketPath: String, kind: AgentKind) -> String {
        template.replacingOccurrences(of: socketPlaceholder, with: AgentPlugins.jsString(socketPath))
            .replacingOccurrences(of: agentPlaceholder, with: AgentPlugins.jsString(agentWord(kind)))
    }

    /// The word upstream's payload names the agent by (`PiAgentVariant`).
    static func agentWord(_ kind: AgentKind) -> String { kind == .ohmypi ? "oh-my-pi" : "pi" }

    static let socketPlaceholder = "__JUICE_SOCKET_PATH__"
    static let agentPlaceholder = "__JUICE_PI_AGENT__"

    static let template = #"""
// Juice extension for Pi and Oh My Pi, revision 1.
// Tells the app's own hook socket what this agent's sessions do: their start, prompts, tools and turns. It never
// waits on the app, decides nothing and changes nothing in the agent. Installed and removed only from the app's
// Settings, Agents. It writes no file and logs nothing.
import { connect } from "node:net";
import { execFile } from "node:child_process";

const REVISION = 1;
const SOCKET_PATH = __JUICE_SOCKET_PATH__;
const AGENT = __JUICE_PI_AGENT__;
const PREFIX = AGENT === "oh-my-pi" ? "omp" : "pi";
// One connection per event, given up after this long. Nothing in the agent waits on it.
const SEND_TIMEOUT_MS = 1000;
// The island keeps a Pi session while these come: they are its liveness.
const HEARTBEAT_MS = 15000;

function send(hook) {
  try {
    const sock = connect({ path: SOCKET_PATH }, () => {
      sock.end(JSON.stringify({ type: "command", command: { type: "processPiHook", piHook: hook } }) + "\n");
    });
    sock.on("data", () => {});
    sock.on("error", () => {});
    sock.setTimeout(SEND_TIMEOUT_MS, () => sock.destroy());
    if (typeof sock.unref === "function") sock.unref();
  } catch {}
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

function textOf(content) {
  if (typeof content === "string") return content.trim();
  if (!Array.isArray(content)) return "";
  const texts = [];
  for (const part of content) {
    if (part && typeof part === "object" && part.type === "text" && typeof part.text === "string") texts.push(part.text);
  }
  return texts.join("\n").trim();
}

function preview(value) {
  try {
    const text = typeof value === "string" ? value : JSON.stringify(value);
    if (typeof text !== "string") return undefined;
    return text.length > 500 ? `${text.slice(0, 499)}…` : text;
  } catch {
    return undefined;
  }
}

export default function juiceExtension(pi) {
  let terminal = null;
  let lastReply = "";
  let stopSent = false;
  let heartbeat;

  // The terminal's fields, read once, at the first session start; every event waits for them, in order.
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

  // What every event carries, read from the context while it is still the session's.
  function context(ctx) {
    const manager = ctx && ctx.sessionManager;
    const cwd = (ctx && ctx.cwd) || process.cwd();
    let id;
    let file;
    try {
      file = manager && manager.getSessionFile ? manager.getSessionFile() : undefined;
      id = (manager && manager.getSessionId ? manager.getSessionId() : undefined) || file;
    } catch {}
    const model = ctx && ctx.model ? [ctx.model.provider, ctx.model.id].filter(Boolean).join("/") : undefined;
    return { agent: AGENT, session_id: `${PREFIX}-${id || `${cwd}:${process.pid}`}`, cwd, model, transcript_path: file };
  }

  // Never returned to the agent: nothing waits on it.
  function emit(event, ctx, extra) {
    let hook;
    try {
      hook = { hook_event_name: event, ...context(ctx) };
    } catch {
      return;
    }
    for (const [key, value] of Object.entries(extra || {})) {
      if (value !== undefined && value !== null && value !== "") hook[key] = value;
    }
    for (const key of Object.keys(hook)) if (hook[key] === undefined || hook[key] === "") delete hook[key];
    ready().then((fields) => send({ ...fields, ...hook }));
  }

  function stopHeartbeat() {
    if (heartbeat === undefined) return;
    clearInterval(heartbeat);
    heartbeat = undefined;
  }

  function startHeartbeat(ctx) {
    stopHeartbeat();
    heartbeat = setInterval(() => {
      emit("Heartbeat", ctx);
    }, HEARTBEAT_MS);
    if (heartbeat && typeof heartbeat.unref === "function") heartbeat.unref();
  }

  pi.on("session_start", (_event, ctx) => {
    lastReply = "";
    stopSent = false;
    emit("SessionStart", ctx);
    startHeartbeat(ctx);
  });

  pi.on("before_agent_start", (event, ctx) => {
    lastReply = "";
    stopSent = false;
    emit("UserPromptSubmit", ctx, { prompt: event && typeof event.prompt === "string" ? event.prompt : undefined });
  });

  pi.on("agent_start", () => {
    stopSent = false;
  });

  pi.on("tool_execution_start", (event, ctx) => {
    emit("PreToolUse", ctx, { tool_name: event && event.toolName, tool_input: preview(event && event.args) });
  });

  pi.on("tool_execution_end", (event, ctx) => {
    emit("PostToolUse", ctx, { tool_name: event && event.toolName });
  });

  pi.on("message_end", (event) => {
    const message = event && event.message;
    if (!message || message.role !== "assistant") return;
    const text = textOf(message.content);
    if (text) lastReply = text;
  });

  // Pi's turn is over once it settles; Oh My Pi's main agent stops.
  pi.on(AGENT === "oh-my-pi" ? "session_stop" : "agent_settled", (_event, ctx) => {
    if (stopSent) return;
    stopSent = true;
    emit("Stop", ctx, { last_assistant_message: lastReply || undefined });
  });

  pi.on("session_shutdown", (event, ctx) => {
    stopHeartbeat();
    if (event && event.reason === "reload") return;
    emit("SessionEnd", ctx);
  });
}
"""#
}
