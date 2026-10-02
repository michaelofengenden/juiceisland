import Foundation

/// P113: writes the app's JSON files off the main thread. A store hands over its file's next contents as a value to
/// encode; the writes of one file within `delay` are one write (the last wins), and every write runs on one serial
/// queue through `StoreFile.write`: encoded there, compact, atomic, in order, and a file this build cannot read whole
/// kept first. Nothing runs while nothing is written. `flush()` writes what waits at once (a quit, a test).
public final class StoreWriter: @unchecked Sendable {
    public typealias Encode = @Sendable () throws -> Data
    public typealias Check = @Sendable (Data) -> Bool

    private struct Job {
        var encode: Encode
        var isReadable: Check
    }

    public let delay: TimeInterval
    private let queue = DispatchQueue(label: "com.ofengenden.juice.store-writer", qos: .utility)
    private let lock = NSLock()
    private var waiting: [URL: Job] = [:]
    private var order: [URL] = []
    /// Files written, for tests: the count of writes that reached the disk.
    private var written = 0

    public init(delay: TimeInterval = 1) {
        self.delay = delay
    }

    /// Queues `url`'s next contents. A write already waiting for that file takes these contents instead.
    public func write(_ url: URL, isReadable: @escaping Check, encode: @escaping Encode) {
        let first: Bool = lock.withLock {
            let first = waiting[url] == nil
            waiting[url] = Job(encode: encode, isReadable: isReadable)
            if first { order.append(url) }
            return first
        }
        guard first else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.drain(url) }
    }

    /// Writes everything that waits, now, and returns when it is on disk.
    public func flush() {
        queue.sync {
            for url in lock.withLock({ order }) { drain(url) }
        }
    }

    /// Writes that reached the disk since this writer was made.
    public var writeCount: Int { lock.withLock { written } }

    /// Runs on `queue`.
    private func drain(_ url: URL) {
        guard let job: Job = lock.withLock({
            order.removeAll { $0 == url }
            return waiting.removeValue(forKey: url)
        }) else { return }
        let data: Data
        do {
            data = try job.encode()
        } catch {
            JuiceLog.stores.error("\(JuiceLog.file(url), privacy: .public) could not be encoded (\(JuiceLog.code(error), privacy: .public))")
            return
        }
        // A failed write is logged by `StoreFile.write`; the file's next change writes it whole again.
        guard (try? StoreFile.write(data, to: url, isReadable: job.isReadable)) != nil else { return }
        lock.withLock { written += 1 }
    }
}
