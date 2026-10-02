import Foundation

public struct TimeoutError: Error, Sendable, Equatable {}

/// Runs `operation` and throws `TimeoutError` if it has not finished within `timeout`. The operation is cancelled.
public func withTimeout<T: Sendable>(_ timeout: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError()
        }
        guard let first = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return first
    }
}
