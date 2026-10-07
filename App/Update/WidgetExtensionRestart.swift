import Darwin
import Foundation
import WidgetKit

/// The widget after an update (P1400). WidgetKit keeps a widget extension's process alive for hours and goes on asking
/// it for timelines, so after the app is replaced (the private Update and its restart, Install automatically, Sparkle's
/// relaunch, a Homebrew upgrade) a widget on the desktop runs the old build's code until that process ends by itself:
/// on the owner's Mac the extension had run since 09:54 when 0.7.0 went in at 15:35, and the new widget showed only
/// after a `killall`. So at launch the app ends its own extension's processes that run older code than its bundle
/// holds now (SIGTERM; WidgetKit starts the new one at its next draw) and then asks WidgetKit once to reload every
/// timeline.
///
/// Only its own: a process of this user whose name is the extension's executable's and that was started from that
/// executable's path in this bundle (the path as the kernel keeps it from the launch, so one whose file was moved aside
/// or deleted by the update still names it). A process started from any other copy (a dev build, another install) is
/// never touched, and nothing is touched in a bundle that holds no widget extension. Stale: the file it runs is not the
/// bundle's file (another inode: the update moved it aside or deleted it), or, where that cannot be read, it started
/// before the bundle's file was made. One that runs the bundle's own file is left alone, however old.
enum WidgetExtensionRestart {
    /// One widget extension in the bundle: its executable and that file's identity.
    struct Extension: Equatable, Sendable {
        var executable: URL
        var file: FileIdentity
        /// When the file was made (its inode's change time): a process started before it runs older code. Read only where
        /// a process's image cannot be.
        var made: Date

        var name: String { executable.lastPathComponent }
    }

    /// A file on a device, as the kernel names it.
    struct FileIdentity: Equatable, Sendable {
        var device: UInt64
        var inode: UInt64
    }

    /// One running process that may be an extension's, as the lister saw it.
    struct Running: Equatable, Sendable {
        var pid: pid_t
        /// The path it was started from, as the kernel keeps it (it outlives a move or a deletion of the file).
        var launchedFrom: String
        /// The file its executable image is mapped from now; nil when it cannot be read.
        var image: FileIdentity?
        var started: Date
    }

    /// This user's processes named `name`, with where each was started from and what it runs.
    typealias Lister = @Sendable (_ name: String) -> [Running]
    /// Ends a process; true when the signal went.
    typealias Ender = @Sendable (pid_t) -> Bool
    typealias Reloader = @Sendable () -> Void

    /// At launch, off the main thread: ends the stale processes of the bundle's widget extensions and, when it ended any,
    /// asks WidgetKit once to reload every timeline. Returns the ended processes' ids (tests).
    @discardableResult
    static func run(bundle: URL = Bundle.main.bundleURL, list: Lister = Self.live, end: Ender = { Darwin.kill($0, SIGTERM) == 0 },
                    reload: Reloader = { WidgetCenter.shared.reloadAllTimelines() }) -> [pid_t] {
        var ended: [pid_t] = []
        for widget in extensions(in: bundle) {
            for process in stale(list(widget.name), of: widget) where end(process.pid) {
                ended.append(process.pid)
            }
        }
        if !ended.isEmpty { reload() }
        return ended
    }

    /// The processes of `widget` that run older code than the bundle's file.
    static func stale(_ processes: [Running], of widget: Extension) -> [Running] {
        let path = canonical(widget.executable.path)
        return processes.filter { process in
            guard canonical(process.launchedFrom) == path else { return false }
            if let image = process.image { return image != widget.file }
            return process.started < widget.made
        }
    }

    /// The widget extensions in the bundle's PlugIns (WidgetKit's extension point), each with its executable.
    static func extensions(in bundle: URL) -> [Extension] {
        let plugIns = bundle.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        let found = (try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)) ?? []
        return found.filter { $0.pathExtension == "appex" }.sorted { $0.path < $1.path }.compactMap { appex in
            guard let info = NSDictionary(contentsOf: appex.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                  point == "com.apple.widgetkit-extension",
                  let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/") else { return nil }
            let executable = appex.appendingPathComponent("Contents/MacOS/\(name)")
            var status = stat()
            guard stat(executable.path, &status) == 0 else { return nil }
            let file = FileIdentity(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: status.st_ino)
            let made = TimeInterval(status.st_ctimespec.tv_sec) + TimeInterval(status.st_ctimespec.tv_nsec) / 1e9
            return Extension(executable: executable, file: file, made: Date(timeIntervalSince1970: made))
        }
    }

    /// A path with its symbolic links resolved where they still exist (`/var` and `/private/var` are one place).
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: The live lister

    /// This user's processes named `name` (the kernel's 32-character name), each with the path it was started from and
    /// the file its image is mapped from. It only reads: names and start times for every process (what `ps` shows),
    /// the rest only for those with the name.
    static let live: Lister = { name in
        let uid = getuid()
        var pids = [pid_t](repeating: 0, count: 8_192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        return pids.prefix(min(count, pids.count)).compactMap { pid -> Running? in
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid,
                  processName(info) == name, let launchedFrom = launchPath(pid) else { return nil }
            let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
            return Running(pid: pid, launchedFrom: launchedFrom, image: image(pid, name: name), started: started)
        }
    }

    private static func processName(_ info: proc_bsdinfo) -> String {
        var info = info
        return withUnsafeBytes(of: &info.pbi_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The path the process was started from: the first string of its arguments area (`KERN_PROCARGS2`), which the
    /// kernel keeps as it was at the launch.
    static func launchPath(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let start = MemoryLayout<Int32>.size
        guard size > start, let end = buffer[start..<size].firstIndex(of: 0), end > start else { return nil }
        return String(decoding: buffer[start..<end], as: UTF8.self)
    }

    /// The file the process's executable image is mapped from: the first of its mapped regions backed by a file named
    /// `name` (the kernel keeps the file's identity after a move or a deletion).
    static func image(_ pid: pid_t, name: String) -> FileIdentity? {
        var address: UInt64 = 0
        for _ in 0..<256 {
            var region = proc_regionwithpathinfo()
            let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &region, size) == size else { return nil }
            var path = region.prp_vip.vip_path
            let file = withUnsafeBytes(of: &path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            let stat = region.prp_vip.vip_vi.vi_stat
            if stat.vst_ino != 0, (file as NSString).lastPathComponent == name {
                return FileIdentity(device: UInt64(stat.vst_dev), inode: stat.vst_ino)
            }
            let next = region.prp_prinfo.pri_address + region.prp_prinfo.pri_size
            guard next > address else { return nil }
            address = next
        }
        return nil
    }
}
