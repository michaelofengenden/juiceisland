import AppKit
import Darwin
import Foundation
import OpenIslandCore

/// The jump back for a remote session (P748): the local terminal tab that runs `ssh` to the session's host. Its tty
/// and its app make an ordinary jump target, which the existing jumps take (iTerm and Terminal by tty; Ghostty brought
/// forward). Several tabs on one host: the one whose TCP client port is the session's `SSH_CONNECTION` port (a direct
/// connection; not through `ProxyJump` or a master), else the newest.
enum RemoteJump {
    struct SSHProcess: Equatable, Sendable {
        var pid: Int32
        var tty: String
        /// Seconds since it started (`ps`'s `etime`).
        var elapsed: Int
        var arguments: [String]
    }

    /// `ps -Ao pid=,tty=,etime=,command=`: ssh clients with a terminal. Arguments are split on spaces, as `ps` joins them.
    static func sshProcesses(psOutput: String) -> [SSHProcess] {
        psOutput.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, let pid = Int32(fields[0]), let elapsed = elapsedSeconds(String(fields[2])) else { return nil }
            let tty = String(fields[1])
            let arguments = fields[3...].map(String.init)
            guard tty != "??", tty != "-", let program = arguments.first,
                  program == "ssh" || program.hasSuffix("/ssh") else { return nil }
            return SSHProcess(pid: pid, tty: tty.hasPrefix("/dev/") ? tty : "/dev/" + tty, elapsed: elapsed, arguments: arguments)
        }
    }

    /// `[[dd-]hh:]mm:ss`.
    static func elapsedSeconds(_ text: String) -> Int? {
        let dayParts = text.split(separator: "-")
        guard dayParts.count <= 2 else { return nil }
        let days = dayParts.count == 2 ? Int(dayParts[0]) : 0
        let clock = (dayParts.last ?? "").split(separator: ":").map { Int($0) }
        guard let days, !clock.isEmpty, clock.count <= 3, clock.allSatisfy({ $0 != nil }) else { return nil }
        return clock.compactMap { $0 }.reduce(0) { $0 * 60 + $1 } + days * 86_400
    }

    /// ssh's options that take a value (ssh(1)).
    static let valueOptions = Set("BbcDEeFIiJLlmOoPpQRSWw")
    /// A control command (`-O`), a `ProxyJump` hop (`-W`), a forward-only tab (`-N`) or a background one (`-f`) is never
    /// where an agent runs.
    static let excludedOptions = Set("OWNf")

    /// The destination ssh connects to, and its `-l` user; nil for a run that is not an interactive login.
    static func destination(of arguments: [String]) -> String? {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return index + 1 < arguments.count ? arguments[index + 1] : nil }
            guard argument.hasPrefix("-"), argument.count > 1 else { return argument }
            var letters = argument.dropFirst()
            while let letter = letters.first {
                letters = letters.dropFirst()
                if excludedOptions.contains(letter) { return nil }
                if valueOptions.contains(letter) {
                    if letters.isEmpty { index += 1 }
                    break
                }
            }
            index += 1
        }
        return nil
    }

    /// The host part of each, compared without case: `gpu1` matches `ssh gpu1`, `ssh me@gpu1` and `ssh -l me gpu1`.
    static func matches(_ destination: String, host: String) -> Bool {
        RemoteDestination.hostName(destination).caseInsensitiveCompare(RemoteDestination.hostName(host)) == .orderedSame
    }

    static func pick(_ processes: [SSHProcess], destination: String, clientPort: Int?,
                     localPorts: (Int32) -> [Int]) -> SSHProcess? {
        let candidates = processes.filter { process in
            self.destination(of: process.arguments).map { matches($0, host: destination) } ?? false
        }
        if let clientPort, candidates.count > 1, let exact = candidates.first(where: { localPorts($0.pid).contains(clientPort) }) {
            return exact
        }
        return candidates.min { $0.elapsed < $1.elapsed }
    }

    /// The jump target and its context for the tab, as a local session's would be.
    static func target(for process: SSHProcess, workspace: String, appForPID: (Int32) -> String?) -> (JumpTarget, JumpContext) {
        let bundleID = appForPID(process.pid)
        let target = JumpTarget(terminalApp: bundleID.map(JumpHosts.name(forBundleID:)) ?? "Unknown", workspaceName: workspace,
                                paneTitle: workspace, terminalTTY: process.tty)
        return (target, JumpContext(hostBundleID: bundleID, agentPID: process.pid))
    }

    /// The local TCP ports a process has open (libproc; its own processes need no privilege).
    static func localPorts(of pid: Int32) -> [Int] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, size) }
        guard filled > 0 else { return [] }
        var ports: [Int] = []
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let read = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard read == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let port = Int(UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport).byteSwapped)
            if port > 0 { ports.append(port) }
        }
        return ports
    }

    /// The live process list, read at the jump (the owner's click) only.
    static func readProcesses() -> String? {
        try? JumpRunner.captureCommand("/bin/ps", ["-Ao", "pid=,tty=,etime=,command="], 2)
    }
}
