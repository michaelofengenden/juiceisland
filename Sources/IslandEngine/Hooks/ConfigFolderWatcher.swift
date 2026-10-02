import Darwin
import Foundation

/// Watches one profile folder and the config files the installers write there (settings.json; hooks.json and
/// config.toml), with kqueue vnode sources opened `O_EVTONLY`: nothing is read, and no other file in the folder is
/// opened. A folder event (a file created, renamed over or deleted, as an atomic save does) re-arms the file watches;
/// a file event (a write in place) fires too. Every event calls `onChange` on the main actor; `HookDriftMonitor`
/// waits 2 s after the last one before it checks (P51). Not an event monitor: it sees files, never input.
public final class ConfigFolderWatcher: HookWatchToken, @unchecked Sendable {
    private let folder: String
    private let files: [String]
    private let onChange: @MainActor @Sendable () -> Void
    private let queue = DispatchQueue(label: "juice-island.config-folder-watcher", qos: .utility)
    private let lock = NSLock()
    private var folderSource: (any DispatchSourceFileSystemObject)?
    private var fileSources: [String: any DispatchSourceFileSystemObject] = [:]
    private var cancelled = false

    /// nil when the folder is missing or cannot be watched.
    public init?(folder: String, files: [String], onChange: @escaping @MainActor @Sendable () -> Void) {
        self.folder = folder
        self.files = files
        self.onChange = onChange
        guard let source = Self.source(path: folder, mask: [.write, .delete, .rename, .link, .revoke], queue: queue) else { return nil }
        folderSource = source
        source.setEventHandler { [weak self] in
            self?.rearmFiles()
            self?.fire()
        }
        source.resume()
        queue.sync { rearmFiles() }
    }

    /// For `HookDriftMonitor`: a watch of the target's folder and config files.
    @MainActor
    public static func watch(_ target: ProfileHookTarget, onChange: @escaping @MainActor @Sendable () -> Void) -> (any HookWatchToken)? {
        ConfigFolderWatcher(folder: target.folder, files: ProfileHookInspector.configFileNames(for: target.provider), onChange: onChange)
    }

    deinit { cancel() }

    public func cancel() {
        let sources: [any DispatchSourceFileSystemObject] = lock.withLock {
            guard !cancelled else { return [] }
            cancelled = true
            defer { folderSource = nil; fileSources = [:] }
            return [folderSource].compactMap { $0 } + Array(fileSources.values)
        }
        for source in sources { source.cancel() }
    }

    private func fire() {
        guard !lock.withLock({ cancelled }) else { return }
        let onChange = self.onChange
        Task { @MainActor in onChange() }
    }

    /// Runs on `queue`. Replaces each file's source, since an atomic save puts a new file (a new vnode) in its place.
    /// Every source is resumed before it can be cancelled or released, as libdispatch requires.
    private func rearmFiles() {
        var fresh: [String: any DispatchSourceFileSystemObject] = [:]
        for name in files {
            guard let source = Self.source(path: folder + "/" + name, mask: [.write, .extend, .delete, .rename, .attrib, .revoke],
                                           queue: queue) else { continue }
            source.setEventHandler { [weak self] in self?.fire() }
            source.resume()
            fresh[name] = source
        }
        let stale: [any DispatchSourceFileSystemObject] = lock.withLock {
            if cancelled { return Array(fresh.values) }
            let previous = Array(fileSources.values)
            fileSources = fresh
            return previous
        }
        for source in stale { source.cancel() }
    }

    /// An `O_EVTONLY` descriptor (no read access) closed by the source's cancel handler; nil when the path is missing.
    private static func source(path: String, mask: DispatchSource.FileSystemEvent,
                               queue: DispatchQueue) -> (any DispatchSourceFileSystemObject)? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setCancelHandler { close(fd) }
        return source
    }
}
