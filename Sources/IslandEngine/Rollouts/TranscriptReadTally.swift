import Synchronization

/// What every transcript reader in this process has considered and read since the last `reset()`: the Codex rollout
/// scanners and the Claude transcript scanners, whoever holds them. Only `RolloutScanMeasure coldstart` reads it, to
/// report a whole cold start's reads, including the ones the discovery coordinator makes with scanners of its own.
public enum TranscriptReadTally {
    public struct Totals: Equatable, Sendable {
        /// Files each pass took after its cap (the newest 40 of those modified in the last day).
        public var filesConsidered = 0
        /// Files opened and read, fully or in windows (a cache hit is not read).
        public var filesRead = 0
        public var bytesRead = 0
    }

    private static let totals = Mutex(Totals())

    public static var current: Totals { totals.withLock { $0 } }

    public static func reset() {
        totals.withLock { $0 = Totals() }
    }

    static func add(considered: Int, read: Int, bytes: Int) {
        totals.withLock {
            $0.filesConsidered += considered
            $0.filesRead += read
            $0.bytesRead += bytes
        }
    }
}
