import Foundation

/// Finds `claude` and `codex`. GUI apps inherit `/usr/bin:/bin`, so the user's login-shell PATH is asked once and cached.
///
/// The path found is the PATH entry itself (`~/.local/bin/codex`), never the file it links to: an installer that keeps
/// each version in its own folder (`…/releases/0.151.0-…/bin/codex`) points that entry at the current one, so a CLI
/// launched through it runs whatever version is current at each launch, and a version the installer prunes later is never
/// held on to (P107). The entry found is kept for the next call only while it is still an executable file; once it is not,
/// the CLI is looked for again.
public enum ToolLocator {
    private static let cache = LockedBox<[String: URL]>([:])
    private static let shellPATH = LockedBox<String?>(nil)

    public static func locate(_ name: String) -> URL? {
        locate(name, cache: cache) { search(name) }
    }

    /// `locate` with its cache and search handed in (tests).
    static func locate(_ name: String, cache: LockedBox<[String: URL]>, search: () -> URL?) -> URL? {
        if let cached = cache.withValue({ $0[name] }), FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
        let found = search()
        cache.withValue { $0[name] = found }
        return found
    }

    public static func loginShellPATH() -> String {
        if let path = shellPATH.withValue({ $0 }) { return path }
        let path = runLoginShell("echo $PATH") ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        shellPATH.withValue { $0 = path }
        return path
    }

    private static func search(_ name: String) -> URL? {
        let home = NSHomeDirectory()
        var dirs = loginShellPATH().split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/miniforge3/bin", "/usr/bin", "/bin"]
        if let found = find(name, in: dirs) { return found }
        if let path = runLoginShell("command -v \(name)"), path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return nil
    }

    /// The first `<dir>/<name>` that is an executable file, as the PATH entry: a symlink is followed to check it, but the
    /// path handed back is the link's own.
    static func find(_ name: String, in dirs: [String]) -> URL? {
        for dir in dirs where !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private static func runLoginShell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let line = text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return (line?.isEmpty == false) ? line : nil
    }
}

/// A tiny lock-protected box so static caches satisfy strict concurrency.
public final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    public init(_ value: Value) { self.value = value }
    public func withValue<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}
