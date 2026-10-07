import Darwin
import Foundation

/// The agents that run a conversation by its id (P1420): this user's processes whose arguments name the session's id as
/// a word of its own (`claude --resume <id>`, `codex resume <id>`, `--resume=<id>`), found through `sysctl` with no
/// process spawned. A path that holds the id (a transcript's) is not a match. Read only, off the main thread, just before
/// a resumed run starts or Open in terminal opens a new window; nothing is kept, logged or shown of what it reads.
enum AgentProcessScan {
    static let live: @Sendable (String) -> [Int32] = { sessionID in pids(naming: sessionID) }

    /// The pids, this process's own aside.
    static func pids(naming sessionID: String) -> [Int32] {
        let id = sessionID.lowercased()
        guard !id.isEmpty else { return [] }
        var buffer = [UInt8](repeating: 0, count: argumentLimit())
        let own = getpid()
        return userPIDs().filter { pid in
            pid != own && (arguments(of: pid, buffer: &buffer)?.contains { names($0, id) } ?? false)
        }
    }

    /// An argument that is the id, or a flag's value given with `=`.
    static func names(_ argument: String, _ id: String) -> Bool {
        let word = argument.lowercased()
        return word == id || word.hasSuffix("=" + id)
    }

    /// Every pid of this user's (`KERN_PROC_UID`).
    static func userPIDs() -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for processes started between the two calls.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).map(\.kp_proc.p_pid).filter { $0 > 0 }
    }

    /// The system's limit on a process's arguments and environment (`KERN_ARGMAX`).
    static func argumentLimit() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var limit: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, u_int(mib.count), &limit, &size, nil, 0) == 0, limit > 0 else { return 1 << 20 }
        return Int(limit)
    }

    /// A process's arguments (`KERN_PROCARGS2`: argc, the executable's path, padding, then argv); nil when it is gone or
    /// not ours to read. The environment after argv is never read.
    static func arguments(of pid: Int32, buffer: inout [UInt8]) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(size)))
    }

    /// argv out of a `KERN_PROCARGS2` answer.
    static func parse(_ bytes: [UInt8]) -> [String]? {
        let head = MemoryLayout<Int32>.size
        guard bytes.count > head else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return [] }
        var index = head
        // The executable's path, then the NULs that pad it.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(argc), index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
