import CoreServices
import Foundation

/// The files and folders that changed under one folder since the last `drain()`, from an FSEvents stream (P85). A
/// file watcher, not an event monitor: it sees paths, never keys or clicks. `CodexRolloutScanner` follows its sessions
/// folder with one, so the Codex app rescan every 10 s looks only at the rollouts that changed instead of walking
/// every rollout ever written (2,500 files and 17 GB on the owner's Mac, and growing).
final class FolderChangeFeed: @unchecked Sendable {
    struct Changes: Equatable {
        /// Files that changed: created, written, renamed, removed or re-stamped.
        var files: Set<String> = []
        /// Folders created, renamed or removed: what is under one is looked at again whole.
        var folders: Set<String> = []
        /// FSEvents lost track (dropped events, a changed root): nothing short of a walk is known to be complete.
        var needsWalk = false
    }

    /// Collects what the stream reports. The stream holds it, so a report still on its way when the feed goes away
    /// never lands in freed memory.
    private final class Sink: @unchecked Sendable {
        let lock = NSLock()
        var changes = Changes()
    }

    private let sink: Sink
    private let stream: FSEventStreamRef
    private let queue = DispatchQueue(label: "com.ofengenden.juice.folder-change-feed")
    /// The folder with its symbolic links resolved (/var is /private/var), as the stream reports paths and as
    /// `FileManager`'s enumerator lists them, so a path from either names a file the same way.
    let root: String
    private var isStarted = false

    /// nil when the folder does not exist or the stream cannot start.
    init?(folder: URL, latency: TimeInterval = 0.5) {
        guard let resolved = realpath(folder.path, nil) else { return nil }
        let root = String(cString: resolved)
        free(resolved)
        let sink = Sink()
        self.root = root
        self.sink = sink

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Sink>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Sink>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, FolderChangeFeed.callback, &context, [root] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        // A stream that did not start is still invalidated and released, by deinit.
        guard FSEventStreamStart(stream) else { return nil }
        isStarted = true
    }

    deinit {
        if isStarted { FSEventStreamStop(stream) }
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Everything reported since the last call.
    func drain() -> Changes {
        sink.lock.withLock {
            defer { sink.changes = Changes() }
            return sink.changes
        }
    }

    /// What is waiting, left in place (tests).
    func peek() -> Changes {
        sink.lock.withLock { sink.changes }
    }

    /// As when FSEvents drops events (tests).
    func loseTrack() {
        sink.lock.withLock { sink.changes.needsWalk = true }
    }

    /// Waits until the stream has handed over what it saw up to now (tests).
    func flush() {
        FSEventStreamFlushSync(stream)
        queue.sync {}
    }

    private static let lostTrack = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
        let reported = unsafeBitCast(paths, to: NSArray.self)
        sink.lock.withLock {
            for index in 0..<count {
                let flag = flags[index]
                guard let path = reported[index] as? String else { continue }
                if flag & lostTrack != 0 {
                    sink.changes.needsWalk = true
                } else if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                    sink.changes.folders.insert(path)
                } else {
                    sink.changes.files.insert(path)
                }
            }
            // Nobody drained for a long while (the Codex app quit): a walk is cheaper than an ever longer list.
            if sink.changes.files.count + sink.changes.folders.count > pathLimit {
                sink.changes = Changes(needsWalk: true)
            }
        }
    }

    /// More paths than this waiting, and the feed asks for a walk instead.
    static let pathLimit = 4_096
}
