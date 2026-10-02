// The remote hook helper the app carries to an SSH host (P740, P742): `jr.py`, Python 3.6 or later, no packages. Set up
// pipes it to the host; nothing else ever writes it there. Its source is here, not in a resource, so the app and its tests
// read one copy. Keep `version` equal to the script's VERSION (RemoteScriptTests checks): a host whose helper is older
// shows Set up again.
public enum RemoteHelperScript {
    public static let version = 2

    public static let source = #"""
#!/usr/bin/env python3
# Juice Island's remote hook helper. The app's Set up puts it in ~/.juice-island and adds its hook entries; Remove
# takes exactly those out and deletes the folder. It holds no policy: the Mac decides, this prints what it is given.
#   jr.py hook --source claude|codex   a hook: one line to the Mac through the tunnel, then what to print (fail open)
#   jr.py serve                        the tunnel's far end: hook connections carried over stdin and stdout in frames
#   jr.py install | remove             the merge into ~/.claude/settings.json (and Codex's files when ~/.codex exists)
import hashlib
import json
import os
import re
import selectors
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import time

VERSION = 2
MARK = "/.juice-island/jr.py"
INPUT_LIMIT = 1 << 20
FRAME_LIMIT = 2 << 20
PREAMBLE = b"\x00JRMUX1\n"
# The Mac answers each hook connection the moment it opens. A hook that hears nothing this long ends, printing nothing;
# serve, whose channel heard nothing this long, takes its socket away and ends, so later hooks end at once (P757).
ACK_WAIT = 8
FIRST_REPLY_WAIT = ACK_WAIT + 2
CLAUDE_EVENTS = [
    ("UserPromptSubmit", None, None), ("SessionStart", None, None), ("SessionEnd", None, None), ("Stop", None, None),
    ("StopFailure", None, None), ("SubagentStart", None, None), ("SubagentStop", None, None),
    ("Notification", "*", None), ("PreToolUse", "*", None), ("PermissionRequest", "*", 86400),
    ("PostToolUse", "*", None), ("PostToolUseFailure", "*", None), ("PermissionDenied", "*", None),
    ("PreCompact", None, None),
]
CODEX_EVENTS = [
    ("SessionStart", "startup|resume", 45), ("UserPromptSubmit", None, 45), ("PermissionRequest", None, 3600),
    ("Stop", None, 45),
]


def home():
    return os.path.expanduser("~")


def base():
    return os.path.join(home(), ".juice-island")


def run_dir():
    """This machine's own sockets, in a folder named for it: hosts that share one home folder (NFS) never reach or
    sweep each other's (P752). Short, so a socket's path fits in an AF_UNIX address."""
    name = socket.gethostname().encode("utf-8", "replace")
    return os.path.join(base(), "run", hashlib.sha256(name).hexdigest()[:8])


# ---- hook ----

def skipped():
    for key in ("OPEN_ISLAND_SKIP_HOOKS", "VIBE_ISLAND_SKIP"):
        if (os.environ.get(key) or "").strip().lower() in ("1", "true", "yes", "on"):
            return True
    return False


def has_terminal():
    try:
        fd = os.open("/dev/tty", os.O_RDONLY | os.O_NOCTTY)
    except OSError:
        return False
    os.close(fd)
    return True


def sockets_newest_first():
    try:
        names = [n for n in os.listdir(run_dir()) if re.match(r"^s-[0-9a-f]{8}\.sock$", n)]
    except OSError:
        return []
    paths = []
    for name in names:
        path = os.path.join(run_dir(), name)
        try:
            paths.append((os.lstat(path).st_mtime, path))
        except OSError:
            pass
    return [p for _, p in sorted(paths, reverse=True)]


def connect_newest():
    for path in sockets_newest_first():
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(1)
        try:
            sock.connect(path)
            return sock
        except (ConnectionRefusedError, FileNotFoundError):
            sock.close()
            try:
                os.unlink(path)
            except OSError:
                pass
        except OSError:
            sock.close()
    return None


def hook(args):
    if skipped():
        return
    raw = sys.stdin.buffer.read(INPUT_LIMIT + 1)
    if not raw or len(raw) > INPUT_LIMIT:
        return
    try:
        payload = json.loads(raw.decode("utf-8"))
    except ValueError:
        return
    if not isinstance(payload, dict):
        return
    source = args[args.index("--source") + 1] if "--source" in args[:-1] else "codex"
    entrypoint = os.environ.get("CLAUDE_CODE_ENTRYPOINT") or None
    ctx = {}
    for key, name in (("tmux", "TMUX"), ("pane", "TMUX_PANE"), ("ssh", "SSH_CONNECTION")):
        if os.environ.get(name):
            ctx[key] = os.environ[name][:512]
    line = {"jr": 1, "v": VERSION, "source": source, "input": payload, "tty": has_terminal(), "ctx": ctx}
    if entrypoint and len(entrypoint) <= 32:
        line["entrypoint"] = entrypoint
    if payload.get("hook_event_name") == "PermissionRequest":
        limit = 55 * 60 if source == "codex" else 23 * 3600
    else:
        limit = 40
    sock = connect_newest()
    if sock is None:
        return
    started = time.time()
    deadline = started + limit
    answered = False
    try:
        sock.sendall(json.dumps(line, separators=(",", ":")).encode("utf-8") + b"\n")
        buffer = b""
        while True:
            # Until the Mac says a word, a few seconds only: a Mac asleep or gone must not hold the agent (P757).
            left = (deadline if answered else min(deadline, started + FIRST_REPLY_WAIT)) - time.time()
            if left <= 0:
                return
            sock.settimeout(min(left, 3600))
            chunk = sock.recv(65536)
            if not chunk:
                return
            buffer += chunk
            if len(buffer) > FRAME_LIMIT:
                return
            while b"\n" in buffer:
                answered = True
                text, buffer = buffer.split(b"\n", 1)
                reply = json.loads(text.decode("utf-8"))
                if not isinstance(reply, dict) or reply.get("hold") is False:
                    return
                if isinstance(reply.get("stdout"), str):
                    sys.stdout.write(reply["stdout"])
                    sys.stdout.flush()
                    return
    except (OSError, ValueError):
        return
    finally:
        sock.close()


# ---- serve ----

class Serve(object):
    def __init__(self):
        self.selector = selectors.DefaultSelector()
        self.channels = {}
        self.next_id = 1
        self.inbox = b""
        self.path = None
        # Each channel the Mac has not answered yet: when it opened.
        self.waiting = {}

    def frame(self, kind, channel, body=b""):
        data = struct.pack(">cII", kind, channel, len(body)) + body
        while data:
            written = os.write(1, data)
            data = data[written:]

    def run(self):
        # A stop (the tunnel's ssh ended, the session hung up) still removes the socket on the way out.
        for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(number, lambda *_: sys.exit(0))
        os.umask(0o077)
        for folder in (base(), os.path.dirname(run_dir()), run_dir()):
            if not os.path.isdir(folder):
                os.mkdir(folder, 0o700)
            os.chmod(folder, 0o700)
        for stale in sockets_newest_first():
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                probe.connect(stale)
            except (ConnectionRefusedError, FileNotFoundError):
                try:
                    os.unlink(stale)
                except OSError:
                    pass
            except OSError:
                pass
            finally:
                probe.close()
        self.path = os.path.join(run_dir(), "s-%s.sock" % os.urandom(4).hex())
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.path)
        os.chmod(self.path, 0o600)
        listener.listen(16)
        listener.setblocking(False)
        os.write(1, PREAMBLE)
        self.frame(b"H", 0, json.dumps({"v": VERSION}).encode("utf-8"))
        os.set_blocking(0, False)
        self.selector.register(listener, selectors.EVENT_READ, "listen")
        self.selector.register(0, selectors.EVENT_READ, "mac")
        try:
            while True:
                # A timeout only while a channel waits on the Mac: nothing ticks at rest.
                timeout = None
                if self.waiting:
                    timeout = max(0, min(self.waiting.values()) + ACK_WAIT - time.monotonic())
                for key, _ in self.selector.select(timeout):
                    if key.data == "listen":
                        self.accept(listener)
                    elif key.data == "mac":
                        if not self.from_mac():
                            return
                    else:
                        self.from_hook(key.data)
                if self.waiting and time.monotonic() - min(self.waiting.values()) >= ACK_WAIT:
                    # The Mac slept or left the network, and sshd has not noticed: this tunnel is gone.
                    return
        finally:
            try:
                os.unlink(self.path)
            except OSError:
                pass

    def accept(self, listener):
        while True:
            try:
                conn, _ = listener.accept()
            except (BlockingIOError, InterruptedError):
                return
            channel = self.next_id
            self.next_id += 1
            conn.setblocking(False)
            self.channels[channel] = conn
            self.selector.register(conn, selectors.EVENT_READ, channel)
            self.waiting[channel] = time.monotonic()
            self.frame(b"O", channel)

    def from_hook(self, channel):
        conn = self.channels.get(channel)
        if conn is None:
            return
        try:
            data = conn.recv(65536)
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            data = b""
        if data:
            self.frame(b"D", channel, data)
        else:
            self.close(channel)
            self.frame(b"C", channel)

    def close(self, channel):
        self.waiting.pop(channel, None)
        conn = self.channels.pop(channel, None)
        if conn is not None:
            self.selector.unregister(conn)
            conn.close()

    def from_mac(self):
        try:
            data = os.read(0, 65536)
        except (BlockingIOError, InterruptedError):
            return True
        if not data:
            return False
        self.inbox += data
        while len(self.inbox) >= 9:
            kind, channel, length = struct.unpack(">cII", self.inbox[:9])
            if length > FRAME_LIMIT:
                return False
            if len(self.inbox) < 9 + length:
                break
            body = self.inbox[9:9 + length]
            self.inbox = self.inbox[9 + length:]
            self.waiting.pop(channel, None)
            if kind == b"D" and channel in self.channels:
                conn = self.channels[channel]
                try:
                    conn.setblocking(True)
                    conn.settimeout(5)
                    conn.sendall(body)
                    conn.setblocking(False)
                except OSError:
                    self.close(channel)
                    self.frame(b"C", channel)
            elif kind == b"C":
                self.close(channel)
            elif kind == b"T":
                select_tmux_pane(body)
        return True


def select_tmux_pane(body):
    try:
        request = json.loads(body.decode("utf-8"))
        socket_path, pane = request["socket"], request["pane"]
    except (ValueError, KeyError, TypeError):
        return
    tmux = shutil.which("tmux")
    if not tmux or not re.match(r"^%[0-9]+$", pane or "") or not isinstance(socket_path, str):
        return
    try:
        if not socket_path.startswith("/") or not stat.S_ISSOCK(os.stat(socket_path).st_mode):
            return
    except OSError:
        return
    for verb in ("switch-client", "select-window", "select-pane"):
        try:
            subprocess.run([tmux, "-S", socket_path, verb, "-t", pane], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
        except (OSError, subprocess.SubprocessError):
            pass


# ---- install and remove ----

class Refused(Exception):
    pass


def quote(text):
    if re.match(r"^[A-Za-z0-9_./+-]+$", text):
        return text
    if "'" in text:
        raise Refused("path has a quote")
    return "'" + text + "'"


def command(source):
    """A hook entry ends quietly when the helper is not there (a Set up cut short, a folder deleted by hand): Python
    would exit 2 on a missing script, which Claude Code and Codex read as a block (P756). Both run hook commands
    through a shell."""
    script = quote(os.path.join(base(), "jr.py"))
    return "[ -f %s ] || exit 0; exec %s %s hook --source %s" % (script, quote(sys.executable), script, source)


def is_ours(hook_entry):
    return isinstance(hook_entry, dict) and MARK in str(hook_entry.get("command", ""))


def strip_ours(groups):
    kept, removed = [], 0
    for group in groups:
        if isinstance(group, dict) and isinstance(group.get("hooks"), list):
            hooks = [h for h in group["hooks"] if not is_ours(h)]
            removed += len(group["hooks"]) - len(hooks)
            if not hooks and len(group["hooks"]) > 0:
                continue
            if len(hooks) != len(group["hooks"]):
                group = dict(group)
                group["hooks"] = hooks
        kept.append(group)
    return kept, removed


def read_json(path):
    if os.path.islink(path):
        raise Refused("%s is a link" % os.path.basename(path))
    if not os.path.exists(path):
        return None
    with open(path, "rb") as handle:
        text = handle.read().decode("utf-8")
    try:
        value = json.loads(text) if text.strip() else {}
    except ValueError:
        raise Refused("%s is not valid JSON" % os.path.basename(path))
    if not isinstance(value, dict):
        raise Refused("%s is not a JSON object" % os.path.basename(path))
    return value


def write_atomic(path, text):
    mode = stat.S_IMODE(os.stat(path).st_mode) if os.path.exists(path) else 0o600
    folder = os.path.dirname(path)
    if not os.path.isdir(folder):
        os.makedirs(folder, 0o700)
    temp = os.path.join(folder, ".%s.juice-island-new" % os.path.basename(path))
    with open(temp, "wb") as handle:
        handle.write(text.encode("utf-8"))
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temp, mode)
    os.replace(temp, path)


def dump(value):
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def merge_hooks(path, events, source, owned):
    """What the file would be with our entries in it, and what we made there; nothing is written here."""
    existing = read_json(path)
    value = existing if existing is not None else {}
    owned = dict(owned or {})
    owned["file"] = bool(owned.get("file")) or existing is None
    hooks = value.get("hooks")
    if hooks is None:
        hooks = {}
        owned["key"] = True
    elif not isinstance(hooks, dict):
        raise Refused("%s has hooks that are not an object" % os.path.basename(path))
    created = set(owned.get("events") or [])
    for name, matcher, timeout in events:
        groups = hooks.get(name)
        if groups is None:
            groups = []
            created.add(name)
        elif not isinstance(groups, list):
            raise Refused("%s has %s hooks that are not a list" % (os.path.basename(path), name))
        groups, _ = strip_ours(groups)
        entry = {"type": "command", "command": command(source)}
        if timeout:
            entry["timeout"] = timeout
        group = {"matcher": matcher, "hooks": [entry]} if matcher else {"hooks": [entry]}
        hooks[name] = groups + [group]
    value["hooks"] = hooks
    owned["events"] = sorted(created)
    return owned, dump(value)


def unmerge_hooks(path, owned):
    value = read_json(path)
    if value is None:
        return
    owned = owned or {"key": True, "events": None}
    hooks = value.get("hooks")
    if isinstance(hooks, dict):
        for name in list(hooks.keys()):
            groups = hooks[name]
            if not isinstance(groups, list):
                continue
            kept, removed = strip_ours(groups)
            if removed == 0:
                continue
            if not kept and (owned.get("events") is None or name in owned["events"]):
                del hooks[name]
            else:
                hooks[name] = kept
        if not hooks and owned.get("key"):
            del value["hooks"]
    if not value and owned.get("file"):
        os.unlink(path)
    else:
        write_atomic(path, dump(value))


FEATURE_LINE = "hooks = true"
HEADER = re.compile(r"^\s*\[\s*features\s*\]\s*(#.*)?$")


def features_range(lines):
    start = None
    for index, line in enumerate(lines):
        if line.strip().startswith("["):
            if start is not None:
                return start, index
            if HEADER.match(line):
                start = index
    return (start, len(lines)) if start is not None else None


def feature_value(lines, span):
    for line in lines[span[0] + 1:span[1]]:
        match = re.match(r"^\s*(hooks|codex_hooks)\s*=\s*(true|false)\s*(#.*)?$", line)
        if match:
            return match.group(2) == "true"
    return None


def enable_codex_feature(path, owned):
    """Codex runs hooks only with `[features] hooks = true`. A file that sets features some other way (a dotted key, an
    inline table) is left alone: a second `[features]` would make it invalid. Returns what we made, the word for the
    app, and the new text (None: nothing to write); nothing is written here."""
    owned = dict(owned or {})
    if os.path.islink(path):
        raise Refused("config.toml is a link")
    exists = os.path.exists(path)
    if exists:
        with open(path, "rb") as handle:
            text = handle.read().decode("utf-8")
    else:
        text = ""
    lines = text.split("\n")
    span = features_range(lines)
    if span:
        current = feature_value(lines, span)
        if current is not None:
            return owned, "on" if current else "off", None
        lines.insert(span[0] + 1, FEATURE_LINE)
        text = "\n".join(lines)
    elif any(re.match(r"^\s*features\s*[.=]", line) for line in lines):
        return owned, "unknown", None
    else:
        body = text.rstrip("\n")
        text = (body + "\n\n" if body else "") + "[features]\n" + FEATURE_LINE + "\n"
        owned["section"] = True
        owned["file"] = bool(owned.get("file")) or not exists
    owned["line"] = True
    return owned, "added", text


def disable_codex_feature(path, owned):
    if not owned or not owned.get("line") or not os.path.exists(path) or os.path.islink(path):
        return
    with open(path, "rb") as handle:
        lines = handle.read().decode("utf-8").split("\n")
    span = features_range(lines)
    if not span:
        return
    for index in range(span[0] + 1, span[1]):
        if lines[index].strip() == FEATURE_LINE:
            del lines[index]
            break
    else:
        return
    span = features_range(lines)
    if owned.get("section") and span and all(not line.strip() for line in lines[span[0] + 1:span[1]]):
        del lines[span[0]:span[1]]
        while len(lines) > 1 and lines[-1] == "" and lines[-2] == "":
            lines.pop()
    text = "\n".join(lines)
    if owned.get("file") and not text.strip():
        os.unlink(path)
    else:
        write_atomic(path, text)


def say(text):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def complain(text):
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def manifest_path():
    return os.path.join(base(), "installed.json")


def install():
    if sys.version_info < (3, 6):
        complain("JR-ERROR python 3.6 or later is needed")
        return 97
    try:
        previous = read_json(manifest_path()) or {}
    except Refused:
        previous = {}
    result = {"v": VERSION, "python": sys.executable, "home": home(), "script": os.path.join(base(), "jr.py"),
              "claude": True, "codex": False}
    # Every file is read and checked first: one refused leaves all of them as they were (P756).
    writes = []
    try:
        command("claude")
        claude_dir = os.path.join(home(), ".claude")
        claude = os.path.join(claude_dir, "settings.json")
        writes.append(("claude", claude) + merge_hooks(claude, CLAUDE_EVENTS, "claude", previous.get("claude")))
        codex_dir = os.path.join(home(), ".codex")
        if os.path.isdir(codex_dir):
            hooks = os.path.join(codex_dir, "hooks.json")
            writes.append(("codex", hooks) + merge_hooks(hooks, CODEX_EVENTS, "codex", previous.get("codex")))
            config = os.path.join(codex_dir, "config.toml")
            owned, result["codexFeature"], text = enable_codex_feature(config, previous.get("codexFeature"))
            writes.append(("codexFeature", config, owned, text))
            result["codex"] = True
    except (Refused, OSError, UnicodeDecodeError) as error:
        complain("JR-ERROR %s" % error)
        return 98
    # The helper goes in place before any entry names it.
    manifest = {"v": VERSION}
    try:
        here = os.path.abspath(sys.argv[0])
        target = os.path.join(base(), "jr.py")
        if here != target:
            os.replace(here, target)
        os.chmod(target, 0o700)
        for key, path, owned, text in writes:
            if text is not None and not same_text(path, text):
                write_atomic(path, text)
            manifest[key] = owned
            # What we made so far is noted as we go, so a write that fails later still lets Remove take it out.
            write_atomic(manifest_path(), dump(dict(previous, **manifest)))
        write_atomic(manifest_path(), dump(manifest))
    except OSError as error:
        complain("JR-ERROR %s" % error)
        return 98
    say("JR-RESULT " + json.dumps(result, separators=(",", ":")))
    return 0


def same_text(path, text):
    try:
        with open(path, "rb") as handle:
            return handle.read() == text.encode("utf-8")
    except OSError:
        return False


def remove():
    try:
        manifest = read_json(manifest_path()) or {}
        unmerge_hooks(os.path.join(home(), ".claude", "settings.json"), manifest.get("claude"))
        codex_dir = os.path.join(home(), ".codex")
        if os.path.isdir(codex_dir):
            unmerge_hooks(os.path.join(codex_dir, "hooks.json"), manifest.get("codex"))
            disable_codex_feature(os.path.join(codex_dir, "config.toml"), manifest.get("codexFeature"))
    except (Refused, OSError, UnicodeDecodeError) as error:
        complain("JR-ERROR %s" % error)
        return 98
    shutil.rmtree(base(), ignore_errors=True)
    say("JR-RESULT " + json.dumps({"v": VERSION, "removed": True}, separators=(",", ":")))
    return 0


def main(args):
    mode = args[0] if args else "hook"
    if mode == "serve":
        try:
            Serve().run()
        except (OSError, KeyboardInterrupt):
            pass
        return 0
    if mode == "install":
        return install()
    if mode == "remove":
        return remove()
    try:
        hook(args[1:] if mode == "hook" else args)
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
"""#
}
