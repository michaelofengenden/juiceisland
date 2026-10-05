import Darwin
import Foundation

/// One process as `sysctl(KERN_PROC_PID)` describes it: no process is spawned to find out.
public struct ProcessEntry: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    /// The short command name (`p_comm`, at most 16 bytes).
    public var name: String
    /// The controlling terminal (`/dev/ttys012`), or nil when the process has none (`??`).
    public var tty: String?
    /// Its process group (`e_pgid`).
    public var group: Int32
    /// Its terminal's foreground process group (`e_tpgid`), 0 without a terminal.
    public var foregroundGroup: Int32
    /// False while it is stopped (Ctrl-Z, SIGSTOP) or has exited and not been reaped (`p_stat`).
    public var runs: Bool

    public init(pid: Int32, parentPID: Int32, name: String, tty: String?, group: Int32 = 0, foregroundGroup: Int32 = 0,
                runs: Bool = true) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.tty = tty
        self.group = group
        self.foregroundGroup = foregroundGroup
        self.runs = runs
    }
}

/// A process's executable, from the kernel (`proc_pidpath`); nil when it is gone or not ours to ask.
public enum ProcessPath {
    public static func of(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Looks up a process by pid. `SystemProcessTable` asks the kernel; tests use a fixed table.
public protocol ProcessTable: Sendable {
    func entry(pid: Int32) -> ProcessEntry?
}

public struct SystemProcessTable: ProcessTable {
    public init() {}

    public func entry(pid: Int32) -> ProcessEntry? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        let device = info.kp_eproc.e_tdev
        var tty: String?
        if device != -1, let deviceName = devname(device, S_IFCHR) {
            let base = String(cString: deviceName)
            if !base.isEmpty, base != "??" { tty = "/dev/" + base }
        }
        let state = Int32(info.kp_proc.p_stat)
        return ProcessEntry(pid: pid, parentPID: info.kp_eproc.e_ppid, name: name, tty: tty, group: info.kp_eproc.e_pgid,
                            foregroundGroup: info.kp_eproc.e_tpgid, runs: state != SSTOP && state != SZOMB)
    }
}

public enum ProcessTree {
    /// What a hook command runs under before it reaches the helper: Claude Code runs hooks through `/bin/sh -c`, and a
    /// hook command may add `env` or a login shell.
    public static let intermediaries: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "env", "login"]

    /// The agent a hook ran for: starting at the helper's parent, the first process that is not a shell. nil when
    /// the walk reaches launchd or finds no such process within `maxHops`.
    public static func agentPID(startingAt pid: Int32, table: any ProcessTable, maxHops: Int = 4) -> Int32? {
        var current = pid
        for _ in 0..<maxHops {
            guard current > 1, let entry = table.entry(pid: current) else { return nil }
            if !intermediaries.contains(entry.name) { return current }
            current = entry.parentPID
        }
        return nil
    }

    /// Whether the agent at `pid` holds its terminal: it runs (not stopped by Ctrl-Z or a signal, not exited), and the
    /// terminal's foreground job is its own process group or that of a process between it and the first ancestor with
    /// the terminal (P18: Claude Code may run without one, under the shell or a launcher that has it); a shell's own
    /// group never counts. A shell back at its prompt, or the agent in the background: false, so a reply is never typed
    /// into a shell (P139).
    public static func holdsItsTerminal(pid: Int32, table: any ProcessTable, maxHops: Int = 6) -> Bool {
        guard pid > 1, let agent = table.entry(pid: pid), agent.runs else { return false }
        var groups: Set<Int32> = []
        var entry = agent
        for _ in 0..<maxHops {
            if entry.pid == pid || !intermediaries.contains(entry.name) { groups.insert(entry.group) }
            if entry.tty != nil { return entry.foregroundGroup > 0 && groups.contains(entry.foregroundGroup) }
            guard entry.parentPID > 1, let parent = table.entry(pid: entry.parentPID) else { return false }
            entry = parent
        }
        return false
    }

    /// The terminal an agent runs in: its own controlling terminal, or else the first ancestor's (P18: Claude Code
    /// 2.1.139+ may run without one, while the shell that started it still has it).
    public static func tty(forPID pid: Int32, table: any ProcessTable, maxHops: Int = 6) -> String? {
        var current = pid
        for _ in 0..<maxHops {
            guard current > 1, let entry = table.entry(pid: current) else { return nil }
            if let tty = entry.tty { return tty }
            current = entry.parentPID
        }
        return nil
    }
}
