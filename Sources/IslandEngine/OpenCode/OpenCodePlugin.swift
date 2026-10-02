// Changed from Open Island 1.2.1's Sources/OpenIslandApp/Resources/open-island-opencode.js (GPL-3.0), September 2026:
// the same plugin, loading under OpenCode 2 too, with the differences below.
import Foundation

/// Juice Island's plugin for OpenCode (P480 to P484): one file for both plugin APIs. OpenCode 1 loads its `server`, as
/// it loads Open Island's plugin; OpenCode 2's loader wants a default export with an `id` and a `setup` and refuses
/// anything else ("Plugin must export a default definition with an id and an effect or setup function",
/// anomalyco/opencode `packages/core/src/config/plugin/external.ts`), which is why Open Island 1.2.1's plugin, a bare
/// function, never loads under OpenCode 2. It is written only by a click in Settings › Setup (`OpenCodePluginInstaller`)
/// to `~/.config/opencode/plugins/open-island.js`, the name Open Island's plugin has, so it takes that file's place;
/// both OpenCode 1 (1.4 and later) and OpenCode 2 load every `plugin/*.js` and `plugins/*.js` of their config folder.
///
/// What it sends is what Open Island's plugin sends (`BridgeServer.handleOpenCodeHook` decodes it unchanged), with
/// these differences: no debug log (upstream appends each event's first 300 characters, prompts and replies included,
/// to a file in /tmp, P483); a session's folder kept for its SessionEnd; a tool's PreToolUse once per call; a part
/// OpenCode wrote itself never sent as the owner's prompt; OpenCode's whole command first in an approval's input
/// (P179); a card's connection closed once OpenCode is answered elsewhere; no `shell.env` hook. Under OpenCode 2 it
/// reads the event stream (`ctx.event.subscribe`: `data` envelopes, `session.execution.*`, `session.inbox.enqueued`,
/// `permission.asked` with `action` and `resources`, `form.created`), answers an approval with
/// `ctx.permission.reply`, sends no terminal (P482), and names its sessions `opencode2-…` (`OpenCodeAPI`) because
/// OpenCode 2 gives plugins no way to answer a question (P481).
public enum OpenCodePlugin {
    /// The plugin's revision, on its first line: a file whose revision is older than this build's is offered Update.
    public static let revision = 1
    /// Open Island's name for the file: ours replaces it in place.
    public static let fileName = "open-island.js"
    /// The first line of every revision, before the number.
    static let marker = "// Juice Island plugin for OpenCode, revision "
    /// The first line of Open Island's plugin (1.2.1), which only OpenCode 1 loads.
    static let openIslandMarker = "// Open Island plugin for OpenCode"

    public static var data: Data { Data(source.utf8) }

    public static let source = #"""
// Juice Island plugin for OpenCode, revision 1.
// Tells Juice Island's hook socket what OpenCode's sessions do, for OpenCode 1 (server) and OpenCode 2 (setup).
// Installed, updated and removed only from Juice Island's Settings, Setup. It writes no file and logs nothing.
import { connect } from "net";
import { homedir } from "os";

const REVISION = 1;
// A card's connection stays open this long at most. It holds nothing: OpenCode shows its own prompt at the same time and
// takes the first answer.
const HOLD_MS = 30 * 60 * 1000;
const SOCKET_PATH =
  process.env.OPEN_ISLAND_SOCKET_PATH ||
  `${process.env.HOME || homedir()}/Library/Application Support/OpenIsland/bridge.sock`;

function encodeEnvelope(command) {
  return JSON.stringify({ type: "command", command }) + "\n";
}

// Fire and forget.
function send(command) {
  return new Promise((resolve) => {
    try {
      const sock = connect({ path: SOCKET_PATH }, () => {
        sock.end(encodeEnvelope(command));
      });
      sock.on("data", () => {});
      sock.on("end", () => resolve(true));
      sock.on("error", () => resolve(false));
      sock.setTimeout(3000, () => {
        sock.destroy();
        resolve(false);
      });
    } catch {
      resolve(false);
    }
  });
}

// Keeps the connection open for the island's answer: the bridge says hello first, then its reply. `cancel` closes it,
// so a late click can no longer answer.
function hold(command, timeoutMs = HOLD_MS) {
  let sock = null;
  let settled = false;
  let settle;
  const reply = new Promise((resolve) => {
    settle = resolve;
  });
  const finish = (value) => {
    if (settled) return;
    settled = true;
    try {
      if (sock) sock.destroy();
    } catch {}
    settle(value);
  };
  try {
    sock = connect({ path: SOCKET_PATH }, () => {
      sock.write(encodeEnvelope(command));
    });
    let buffer = "";
    sock.on("data", (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n").filter(Boolean);
      if (lines.length < 2) return;
      let parsed = null;
      try {
        parsed = JSON.parse(lines[1]);
      } catch {}
      finish(parsed);
    });
    sock.on("end", () => finish(null));
    sock.on("error", () => finish(null));
    sock.setTimeout(timeoutMs, () => finish(null));
  } catch {
    finish(null);
  }
  return { reply, cancel: () => finish(null) };
}

function directiveOf(reply) {
  return reply?.response?.directive || null;
}

function capitalized(name) {
  const text = String(name || "");
  return text.charAt(0).toUpperCase() + text.slice(1);
}

// A map that forgets its oldest entries.
function bounded(limit = 200) {
  const map = new Map();
  return {
    get: (key) => map.get(key),
    has: (key) => map.has(key),
    delete: (key) => map.delete(key),
    set(key, value) {
      map.delete(key);
      map.set(key, value);
      if (map.size > limit) map.delete(map.keys().next().value);
    },
  };
}

// One open card per request id; a newer card for the same session closes the older one's connection, since the bridge
// keeps only the newest per session.
function holds() {
  const byRequest = new Map();
  return {
    open(sessionID, requestID, command) {
      for (const [id, entry] of byRequest) {
        if (entry.sessionID === sessionID) {
          entry.handle.cancel();
          byRequest.delete(id);
        }
      }
      const handle = hold(command);
      byRequest.set(requestID, { sessionID, handle });
      handle.reply.then(() => {
        if (byRequest.get(requestID)?.handle === handle) byRequest.delete(requestID);
      });
      return handle.reply;
    },
    close(requestID) {
      const entry = byRequest.get(requestID);
      if (!entry) return;
      entry.handle.cancel();
      byRequest.delete(requestID);
    },
    closeAll() {
      for (const entry of byRequest.values()) entry.handle.cancel();
      byRequest.clear();
    },
  };
}

function hookCommand(hookEventName, sessionID, cwd, extra = {}) {
  const hook = { hook_event_name: hookEventName, session_id: sessionID, cwd: cwd || "." };
  for (const [key, value] of Object.entries(extra)) {
    if (value !== undefined && value !== null && value !== "") hook[key] = value;
  }
  return { type: "processOpenCodeHook", openCodeHook: hook };
}

function preview(input) {
  if (typeof input === "string") return input.slice(0, 200);
  try {
    return JSON.stringify(input || {}).slice(0, 200);
  } catch {
    return undefined;
  }
}

// What the island's approval card reads (App/Models/Sessions/ApprovalContent.swift): OpenCode's whole command first
// when there is one, then one pattern per command, then the patterns joined as the command, or the first file.
function permissionHook(tool, patterns, command) {
  const input = {};
  if (typeof command === "string" && command.trim()) input.metadata = { command };
  input.patterns = patterns;
  const lowered = tool.toLowerCase();
  if ((lowered === "bash" || lowered === "shell") && patterns.length > 0) input.command = patterns.join(" && ");
  if ((lowered === "edit" || lowered === "write") && patterns.length > 0) input.file_path = patterns[0];
  let text;
  try {
    text = JSON.stringify(input).slice(0, 4000);
  } catch {
    text = undefined;
  }
  return {
    tool_name: tool,
    tool_input: text,
    permission_title: `Allow ${tool}`,
    permission_description:
      patterns.length > 0 ? `OpenCode wants to run ${tool}: ${patterns[0]}` : `OpenCode wants to run ${tool}`,
  };
}

function questionItem(question, index) {
  if (!question || typeof question !== "object") return null;
  const text = question.question || question.title || question.prompt;
  if (!text) return null;
  const options = Array.isArray(question.options)
    ? question.options
        .map((option) => {
          if (typeof option === "string") return { label: option };
          if (!option || typeof option !== "object") return null;
          const label = option.label || option.text || option.value || option.name;
          if (!label) return null;
          return { label: String(label), description: option.description || option.hint || option.detail || "" };
        })
        .filter(Boolean)
    : [];
  if (options.length === 0) return null;
  return {
    question: String(text),
    header: question.header || question.label || `Question ${index + 1}`,
    options,
    multi_select: Boolean(question.multiple || question.multiSelect || question.multi_select),
  };
}

// OpenCode 1 ------------------------------------------------------------------------------------------------------

function terminalFields() {
  const env = process.env;
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
  try {
    const { execSync } = require("child_process");
    let pid = process.pid;
    for (let step = 0; step < 8; step++) {
      const [tty, parent] = execSync(`ps -o tty=,ppid= -p ${pid}`, { timeout: 1000 }).toString().trim().split(/\s+/);
      if (tty && tty !== "??" && tty !== "?") {
        result.terminal_tty = `/dev/${tty}`;
        break;
      }
      const next = parseInt(parent);
      if (!next || next <= 1) break;
      pid = next;
    }
  } catch {}
  return result;
}

// OpenCode 1 runs the plugin in the process of the terminal it was started in, so the terminal is the session's.
async function server({ client, serverUrl } = {}) {
  const port = serverUrl ? parseInt(serverUrl.port) || 4096 : 4096;
  const internalFetch = client?._client?.getConfig?.()?.fetch || null;
  const terminal = terminalFields();
  const roles = bounded();
  const tools = bounded();
  const cwds = new Map();
  const replies = new Map();
  const open = holds();
  const id = (sessionID) => `opencode-${sessionID}`;
  const make = (event, sessionID, extra = {}) => hookCommand(event, id(sessionID), cwds.get(sessionID), { ...terminal, ...extra });

  async function post(path, body) {
    if (!internalFetch) return;
    try {
      await internalFetch(
        new Request(`http://localhost:${port}${path}`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        }),
      );
    } catch {}
  }

  async function onEvent(event) {
    const type = event?.type;
    const p = event?.properties || {};

    if (type === "session.created" && p.info) {
      if (p.info.directory) cwds.set(p.info.id, p.info.directory);
      return send(make("SessionStart", p.info.id));
    }
    if ((type === "session.deleted" && p.info) || (type === "session.updated" && p.info?.time?.archived)) {
      const command = make("SessionEnd", p.info.id);
      cwds.delete(p.info.id);
      replies.delete(p.info.id);
      return send(command);
    }
    if (type === "session.updated" && p.info?.directory) {
      cwds.set(p.info.id, p.info.directory);
      return;
    }
    if (type === "session.status" && p.sessionID && p.status?.type === "idle") {
      return send(make("Stop", p.sessionID, { last_assistant_message: replies.get(p.sessionID) }));
    }
    if (type === "message.updated" && p.info?.id && p.info?.sessionID) {
      roles.set(p.info.id, { role: p.info.role, sessionID: p.info.sessionID });
      return;
    }
    if (type === "message.part.updated" && p.part?.type === "text" && p.part?.messageID) {
      const owner = roles.get(p.part.messageID);
      const text = p.part.text || "";
      if (!owner || !text) return;
      if (owner.role === "assistant") {
        replies.set(owner.sessionID, text);
        return;
      }
      // A part OpenCode wrote itself (a read file, a compaction's "Continue…") is not the owner's prompt.
      if (owner.role === "user" && !p.part.synthetic) {
        return send(make("UserPromptSubmit", owner.sessionID, { prompt: text }));
      }
      return;
    }
    if (type === "message.part.updated" && p.part?.type === "tool" && p.part?.sessionID) {
      const status = p.part.state?.status;
      const key = p.part.id || p.part.callID;
      const tool = capitalized(p.part.tool);
      if (status === "running" || status === "pending") {
        if (key && tools.has(key)) return;
        if (key) tools.set(key, true);
        return send(make("PreToolUse", p.part.sessionID, { tool_name: tool, tool_input: preview(p.part.state?.input) }));
      }
      if (status === "completed" || status === "error") {
        if (key) tools.delete(key);
        return send(make("PostToolUse", p.part.sessionID, { tool_name: tool }));
      }
      return;
    }
    if (type === "permission.asked" && p.id && p.sessionID) {
      const tool = capitalized(p.permission);
      const patterns = Array.isArray(p.patterns) ? p.patterns.map(String) : [];
      const command = make("PermissionRequest", p.sessionID, {
        ...permissionHook(tool, patterns, p.metadata?.command),
        permission_id: p.id,
      });
      open.open(p.sessionID, p.id, command).then((reply) => {
        const directive = directiveOf(reply);
        if (!directive || (directive.type !== "allow" && directive.type !== "deny")) return;
        post(`/permission/${encodeURIComponent(p.id)}/reply`, {
          reply: directive.type === "allow" ? "once" : "reject",
          message: directive.type === "deny" ? directive.reason || undefined : undefined,
        });
      });
      return;
    }
    if (type === "permission.replied" && p.sessionID) {
      if (p.requestID) open.close(p.requestID);
      return send(make("PostToolUse", p.sessionID));
    }
    if (type === "question.asked" && p.id && p.sessionID) {
      const questions = Array.isArray(p.questions) ? p.questions.map(questionItem).filter(Boolean) : [];
      const command = make("QuestionAsked", p.sessionID, {
        question_id: p.id,
        question_text: (p.questions || []).map((question) => question?.question).filter(Boolean).join("; ") ||
          "OpenCode has a question",
        questions,
      });
      open.open(p.sessionID, p.id, command).then((reply) => {
        const directive = directiveOf(reply);
        if (directive?.type !== "answer") return;
        post(`/question/${encodeURIComponent(p.id)}/reply`, { answers: [[directive.text]] });
      });
      return;
    }
    if ((type === "question.replied" || type === "question.rejected") && p.sessionID) {
      if (p.requestID) open.close(p.requestID);
      return send(make("PostToolUse", p.sessionID));
    }
  }

  return {
    event: async ({ event }) => {
      try {
        await onEvent(event);
      } catch {}
    },
  };
}

// OpenCode 2 ------------------------------------------------------------------------------------------------------

// A turn that ends: not one a steered prompt took over, whose next turn starts at once.
const V2_TURN_ENDS = new Set(["session.execution.succeeded", "session.execution.failed"]);
const V2_INTERRUPTS_THAT_END = new Set(["user", "shutdown", "inactivity"]);

// OpenCode 2 runs every session in one background service, started from whichever terminal came first, so the
// plugin's own terminal is no session's: it sends none. Its sessions are named `opencode2-…`, so the island knows its
// questions can only be answered in OpenCode (a plugin cannot reply to OpenCode 2's forms).
async function setup(ctx) {
  const controller = typeof AbortController === "function" ? new AbortController() : null;
  const cwds = new Map();
  const replies = new Map();
  const toolNames = bounded();
  const toolInputs = bounded();
  const open = holds();
  const id = (sessionID) => `opencode2-${sessionID}`;
  const where = (event, sessionID) => event?.location?.directory || cwds.get(sessionID) || ctx?.location?.directory;
  const make = (hookEvent, event, sessionID, extra = {}) =>
    hookCommand(hookEvent, id(sessionID), where(event, sessionID), extra);

  async function onEvent(event) {
    const type = event?.type;
    const d = event?.data || {};

    if (type === "session.created" && d.sessionID) {
      if (d.location?.directory) cwds.set(d.sessionID, d.location.directory);
      return send(make("SessionStart", event, d.sessionID));
    }
    if (type === "session.deleted" && d.sessionID) {
      const command = make("SessionEnd", event, d.sessionID);
      cwds.delete(d.sessionID);
      replies.delete(d.sessionID);
      return send(command);
    }
    if (type === "session.inbox.enqueued" && d.sessionID) {
      const text = d.item?.type === "user" ? d.item?.payload?.text : undefined;
      if (typeof text === "string" && text.trim()) return send(make("UserPromptSubmit", event, d.sessionID, { prompt: text }));
      return;
    }
    if (type === "session.text.ended" && d.sessionID && typeof d.text === "string") {
      if (d.text.trim()) replies.set(d.sessionID, d.text);
      return;
    }
    if (type === "session.tool.input.started" && d.id) {
      toolNames.set(d.id, d.name);
      return;
    }
    if (type === "session.tool.called" && d.id && d.sessionID) {
      toolInputs.set(d.id, d.input);
      return send(make("PreToolUse", event, d.sessionID, {
        tool_name: capitalized(toolNames.get(d.id)),
        tool_input: preview(d.input),
      }));
    }
    if ((type === "session.tool.success" || type === "session.tool.failed") && d.id && d.sessionID) {
      const tool = capitalized(toolNames.get(d.id));
      toolNames.delete(d.id);
      toolInputs.delete(d.id);
      return send(make("PostToolUse", event, d.sessionID, { tool_name: tool }));
    }
    if (d.sessionID && (V2_TURN_ENDS.has(type) ||
        (type === "session.execution.interrupted" && V2_INTERRUPTS_THAT_END.has(d.reason)))) {
      return send(make("Stop", event, d.sessionID, { last_assistant_message: replies.get(d.sessionID) }));
    }
    if (type === "permission.asked" && d.id && d.sessionID) {
      const tool = capitalized(d.action);
      const patterns = Array.isArray(d.resources) ? d.resources.map(String) : [];
      const input = d.source?.id ? toolInputs.get(d.source.id) : undefined;
      const whole = typeof d.metadata?.command === "string" ? d.metadata.command : input?.command;
      const command = make("PermissionRequest", event, d.sessionID, {
        ...permissionHook(tool, patterns, whole),
        permission_id: d.id,
      });
      open.open(d.sessionID, d.id, command).then(async (reply) => {
        const directive = directiveOf(reply);
        if (!directive || (directive.type !== "allow" && directive.type !== "deny")) return;
        const answer = { sessionID: d.sessionID, requestID: d.id, decision: directive.type === "allow" ? "once" : "reject" };
        if (directive.type === "deny" && directive.reason) answer.message = directive.reason;
        try {
          await ctx.permission.reply(answer);
        } catch {}
      });
      return;
    }
    if (type === "permission.replied" && d.sessionID) {
      if (d.requestID) open.close(d.requestID);
      return send(make("PostToolUse", event, d.sessionID));
    }
    if (type === "form.created" && d.form?.id && d.form?.sessionID && d.form?.metadata?.kind === "question") {
      const form = d.form;
      const fields = Array.isArray(form.fields) ? form.fields : [];
      const questions = fields
        .map((field, index) =>
          questionItem(
            { question: field.description || field.title, header: field.title, options: field.options,
              multiple: field.type === "multiselect" },
            index,
          ),
        )
        .filter(Boolean);
      const command = make("QuestionAsked", event, form.sessionID, {
        question_id: form.id,
        question_text: questions.map((question) => question.question).join("; ") || form.title || "OpenCode has a question",
        questions,
      });
      // Read-only on the island: the connection only keeps the card up until OpenCode is answered.
      open.open(form.sessionID, form.id, command);
      return;
    }
    if ((type === "form.replied" || type === "form.cancelled") && d.id && d.sessionID) {
      open.close(d.id);
      return send(make("PostToolUse", event, d.sessionID));
    }
  }

  (async () => {
    try {
      const options = controller ? { signal: controller.signal } : {};
      for await (const event of ctx.event.subscribe(options)) {
        try {
          await onEvent(event);
        } catch {}
      }
    } catch {}
  })();

  return () => {
    if (controller) controller.abort();
    open.closeAll();
  };
}

export default { id: "juice-island", revision: REVISION, server, setup };

"""#
}
